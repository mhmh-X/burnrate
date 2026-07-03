import Foundation

/// 从 Claude Code 的 OAuth 凭据获取 Claude 订阅额度。
/// 凭据来源：macOS 钥匙串 "Claude Code-credentials"（备选 ~/.claude/.credentials.json）。
/// 额度接口：GET https://api.anthropic.com/api/oauth/usage
struct ClaudeProvider: UsageProvider {
    let name = "Claude"

    private static let keychainService = "Claude Code-credentials"
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e" // Claude Code 公开 client_id
    private static let tokenURL = "https://claude.ai/v1/oauth/token"
    private static let usageURL = "https://api.anthropic.com/api/oauth/usage"

    static func hasLocalCredentials() -> Bool {
        if Keychain.exists(service: keychainService) { return true }
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        guard let data = try? Data(contentsOf: path) else { return false }
        let root = HTTP.json(data)
        return root["claudeAiOauth"] is [String: Any]
    }

    func fetch() async -> ProviderState {
        // ByteRate 自己登录过 Claude 时优先走自有凭据（独立 token 链，零钥匙串弹框）
        if ClaudeAuth.hasOwnCredentials {
            return await Self.fetchWithOwnCredentials()
        }
        return await Self.fetchWithSharedCredentials()
    }

    // MARK: - 自有凭据路径（独立登录）

    private static func fetchWithOwnCredentials() async -> ProviderState {
        do {
            guard var creds = ClaudeAuth.load() else {
                throw UsageError.message("ByteRate 的 Claude 登录已失效，请在菜单里重新登录",
                                         "ByteRate's Claude sign-in is broken — sign in again from the menu")
            }
            if creds.expiresAt / 1000 < Date().timeIntervalSince1970 + 60 {
                creds = try await ClaudeAuth.refreshedCredentials(creds)
            }
            var (status, data) = try await callUsage(token: creds.accessToken)
            if status == 401 {
                creds = try await ClaudeAuth.refreshedCredentials(creds)
                (status, data) = try await callUsage(token: creds.accessToken)
            }
            if status == 403 {
                throw UsageError.message("此登录没有额度查询权限，请在菜单里重新登录 Claude",
                                         "This sign-in lacks usage permission — sign in again from the menu")
            }
            if status == 429 {
                throw UsageError.message("请求过于频繁被临时限流（429）", "Temporarily rate-limited (429)")
            }
            guard status == 200 else {
                throw UsageError.message("额度接口返回 \(status)", "Usage API returned \(status)")
            }
            let usage = parseUsage(HTTP.json(data), plan: creds.subscriptionType)
            guard usage.hourly != nil || usage.weekly != nil else {
                throw UsageError.message("接口返回结构无法识别，可能已变更",
                                         "Unrecognized usage API response — schema may have changed")
            }
            return .ok(usage)
        } catch let e as UsageError {
            return .error(e.bi)
        } catch {
            let raw = error.localizedDescription
            return .error(BiText(zh: raw, en: raw))
        }
    }

    // MARK: - 共用 CLI 凭据路径（默认）

    private static func fetchWithSharedCredentials() async -> ProviderState {
        do {
            // token 过期时由 ByteRate 自己刷新并写回（写回让 Claude Code 也同步到新 token，不会登出）。
            var creds = try Self.loadCredentials()

            if let exp = creds.oauth["expiresAt"] as? Double,
               exp / 1000 < Date().timeIntervalSince1970 + 60 {
                creds = try await Self.refresh(creds)
            }
            guard let token = creds.oauth["accessToken"] as? String else {
                throw UsageError.message("凭据里没有 accessToken", "No accessToken in credentials")
            }
            var (status, data) = try await Self.callUsage(token: token)
            if status == 401 {
                creds = try await Self.refresh(creds)
                guard let newToken = creds.oauth["accessToken"] as? String else {
                    throw UsageError.message("刷新后仍无 accessToken", "Still no accessToken after refresh")
                }
                (status, data) = try await Self.callUsage(token: newToken)
            }
            if status == 429 {
                throw UsageError.message("请求过于频繁被临时限流（429）", "Temporarily rate-limited (429)")
            }
            guard status == 200 else {
                throw UsageError.message("额度接口返回 \(status)", "Usage API returned \(status)")
            }
            let plan = creds.oauth["subscriptionType"] as? String
            let usage = Self.parseUsage(HTTP.json(data), plan: plan)
            guard usage.hourly != nil || usage.weekly != nil else {
                throw UsageError.message("接口返回结构无法识别，可能已变更",
                                         "Unrecognized usage API response — schema may have changed")
            }
            return .ok(usage)
        } catch let e as UsageError {
            return .error(e.bi)
        } catch {
            let raw = error.localizedDescription
            return .error(BiText(zh: raw, en: raw))
        }
    }

    // MARK: - 凭据

    private struct Credentials {
        var root: [String: Any]      // 完整 JSON（写回时保留其他字段）
        var oauth: [String: Any]     // root["claudeAiOauth"]
        var fromKeychain: Bool
        var account: String?         // 钥匙串条目的账户名，写回时精确匹配
    }

    /// 读取 Claude Code 的 OAuth 凭据。钥匙串优先，回退 ~/.claude/.credentials.json。
    private static func loadCredentials() throws -> Credentials {
        let data: Data
        var fromKeychain = true
        var account: String?
        if let (d, a) = try? Keychain.read(service: keychainService) {
            data = d
            account = a
        } else {
            let path = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/.credentials.json")
            guard let d = try? Data(contentsOf: path) else {
                throw UsageError.message("找不到 Claude Code 凭据，请先在 Claude Code 里登录", "Claude Code credentials not found — sign in to Claude Code first")
            }
            data = d
            fromKeychain = false
        }
        let root = HTTP.json(data)
        guard let oauth = root["claudeAiOauth"] as? [String: Any] else {
            throw UsageError.message("凭据格式不正确", "Malformed credentials")
        }
        return Credentials(root: root, oauth: oauth, fromKeychain: fromKeychain, account: account)
    }

    /// 仅在「Claude 自动刷新」开启时调用：刷新 token 并写回原处（保持 CLI 同步，避免登出）。
    private static func refresh(_ creds: Credentials) async throws -> Credentials {
        // 刷新前重读一次：若 Claude Code 刚刷新过（refresh token 已轮换），用最新的
        let creds = (try? loadCredentials()) ?? creds
        guard let rt = creds.oauth["refreshToken"] as? String else {
            throw UsageError.message("没有 refreshToken，请重新登录 Claude Code", "No refreshToken — sign in to Claude Code again")
        }
        let (status, data) = try await HTTP.request(
            tokenURL, method: "POST",
            jsonBody: ["grant_type": "refresh_token", "refresh_token": rt, "client_id": clientID]
        )
        if status == 429 { throw UsageError.message("token 刷新被限流，稍后自动重试", "Token refresh rate-limited, will retry") }
        guard status == 200 else { throw UsageError.message("token 刷新失败（\(status)），请重新登录 Claude Code", "Token refresh failed (\(status)) — sign in to Claude Code again") }
        let body = HTTP.json(data)
        guard let access = body["access_token"] as? String else {
            throw UsageError.message("刷新响应缺少 access_token", "Refresh response missing access_token")
        }
        var oauth = creds.oauth
        oauth["accessToken"] = access
        if let newRT = body["refresh_token"] as? String { oauth["refreshToken"] = newRT }
        let expiresIn = body["expires_in"] as? Double ?? 28800
        oauth["expiresAt"] = Int((Date().timeIntervalSince1970 + expiresIn) * 1000)
        var root = creds.root
        root["claudeAiOauth"] = oauth
        // 写回新 token，让 Claude Code 也能用（refresh token 已轮换，不写回会把 CLI 登出）。
        // 用 in-place 更新，尽量不破坏现有 ACL；失败不中断，本次先用内存里的新 token。
        do {
            let out = try JSONSerialization.data(withJSONObject: root)
            if creds.fromKeychain {
                try Keychain.upsert(service: keychainService, account: creds.account, data: out)
            } else {
                let path = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".claude/.credentials.json")
                try out.write(to: path, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            }
        } catch {
            NSLog("ByteRate: 凭据写回失败，本次使用内存中的新 token")
        }
        return Credentials(root: root, oauth: oauth, fromKeychain: creds.fromKeychain, account: creds.account)
    }

    private static func callUsage(token: String) async throws -> (Int, Data) {
        try await HTTP.request(usageURL, headers: [
            "Authorization": "Bearer \(token)",
            "anthropic-beta": "oauth-2025-04-20",
        ])
    }

    // MARK: - 解析

    private static func parseUsage(_ json: [String: Any], plan: String?) -> ProviderUsage {
        ProviderUsage(
            hourly: parseWindow(json["five_hour"]),
            weekly: parseWindow(json["seven_day"]),
            plan: plan
        )
    }

    private static func parseWindow(_ value: Any?) -> WindowUsage? {
        guard let dict = value as? [String: Any] else { return nil }
        // 百分比缺失/非法时宁可不显示该窗口，也不能默认 0 已用谎报"剩 100%"
        guard let raw = (dict["utilization"] as? Double) ?? (dict["used_percent"] as? Double),
              raw.isFinite else { return nil }
        let used = min(max(raw, 0), 100)
        var resets: Date?
        if let s = dict["resets_at"] as? String {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            resets = iso.date(from: s)
            if resets == nil {
                iso.formatOptions = [.withInternetDateTime]
                resets = iso.date(from: s)
            }
        } else if let t = dict["resets_at"] as? Double {
            resets = Date(timeIntervalSince1970: t)
        }
        return WindowUsage(usedPercent: used, resetsAt: resets)
    }
}

import Foundation

/// 从 Codex CLI 的凭据获取 Codex（ChatGPT 订阅）额度。
/// 凭据来源：~/.codex/auth.json
/// 额度接口：GET https://chatgpt.com/backend-api/wham/usage
struct CodexProvider: UsageProvider {
    let name = "Codex"

    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann" // Codex CLI 公开 client_id
    private static let tokenURL = "https://auth.openai.com/oauth/token"
    private static let usageURL = "https://chatgpt.com/backend-api/wham/usage"

    private static var authPath: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
    }

    static func hasLocalCredentials() -> Bool {
        guard let data = try? Data(contentsOf: authPath),
              let tokens = HTTP.json(data)["tokens"] as? [String: Any] else {
            return false
        }
        // 与 loadAuth 的要求保持一致：fetch 必须有 access_token 才能工作
        return tokens["access_token"] is String
    }

    func fetch() async -> ProviderState {
        do {
            var auth = try Self.loadAuth()
            if Self.isExpired(jwt: auth.accessToken) {
                auth = try await Self.refresh(auth)
            }
            var (status, data) = try await Self.callUsage(auth)
            if status == 401 {
                auth = try await Self.refresh(auth)
                (status, data) = try await Self.callUsage(auth)
            }
            if status == 429 {
                throw UsageError.message("请求过于频繁被临时限流（429）", "Temporarily rate-limited (429)")
            }
            guard status == 200 else {
                throw UsageError.message("额度接口返回 \(status)", "Usage API returned \(status)")
            }
            let usage = Self.parseUsage(HTTP.json(data), idToken: auth.idToken)
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

    private struct Auth {
        var root: [String: Any]
        var accessToken: String
        var accountID: String?
        var idToken: String?
    }

    private static func loadAuth() throws -> Auth {
        guard let data = try? Data(contentsOf: authPath) else {
            throw UsageError.message("找不到 ~/.codex/auth.json，请先 codex login", "~/.codex/auth.json not found — run codex login first")
        }
        let root = HTTP.json(data)
        guard let tokens = root["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String else {
            throw UsageError.message("auth.json 里没有 access_token，请重新 codex login", "No access_token in auth.json — run codex login again")
        }
        return Auth(root: root, accessToken: access, accountID: tokens["account_id"] as? String,
                    idToken: tokens["id_token"] as? String)
    }

    private static func refresh(_ auth: Auth) async throws -> Auth {
        // 刷新前重读，避免与 Codex CLI 的轮换互相覆盖；重读失败直接中止，不用旧快照写回
        _ = auth
        let auth = try loadAuth()
        guard let tokens = auth.root["tokens"] as? [String: Any],
              let rt = tokens["refresh_token"] as? String else {
            throw UsageError.message("没有 refresh_token，请重新 codex login", "No refresh_token — run codex login again")
        }
        let (status, data) = try await HTTP.request(
            tokenURL, method: "POST",
            jsonBody: [
                "client_id": clientID,
                "grant_type": "refresh_token",
                "refresh_token": rt,
                "scope": "openid profile email",
            ]
        )
        if status == 429 { throw UsageError.message("token 刷新被临时限流，稍后自动重试", "Token refresh rate-limited, will retry") }
        guard status == 200 else { throw UsageError.message("Codex token 刷新失败（\(status)），请重新 codex login", "Codex token refresh failed (\(status)) — run codex login again") }
        let body = HTTP.json(data)
        guard let access = body["access_token"] as? String else {
            throw UsageError.message("刷新响应缺少 access_token", "Refresh response missing access_token")
        }
        var newTokens = tokens
        newTokens["access_token"] = access
        if let idToken = body["id_token"] as? String { newTokens["id_token"] = idToken }
        if let newRT = body["refresh_token"] as? String { newTokens["refresh_token"] = newRT }
        var root = auth.root
        root["tokens"] = newTokens
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        root["last_refresh"] = iso.string(from: Date())
        // 写回失败不中断：先保住内存里的新 token；原子写入后恢复 0600 权限
        do {
            let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted])
            try out.write(to: authPath, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authPath.path)
        } catch {
            NSLog("ByteRate: auth.json 写回失败，本次使用内存中的新 token")
        }
        return Auth(root: root, accessToken: access, accountID: newTokens["account_id"] as? String,
                    idToken: newTokens["id_token"] as? String)
    }

    /// 解码 JWT 的 payload。
    private static func jwtPayload(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload) else { return nil }
        return HTTP.json(data)
    }

    /// 解码 JWT 的 exp 判断是否过期。
    private static func isExpired(jwt: String) -> Bool {
        guard let exp = jwtPayload(jwt)?["exp"] as? Double else { return false }
        return exp < Date().timeIntervalSince1970 + 60
    }

    private static func callUsage(_ auth: Auth) async throws -> (Int, Data) {
        var headers = ["Authorization": "Bearer \(auth.accessToken)"]
        if let acct = auth.accountID { headers["chatgpt-account-id"] = acct }
        return try await HTTP.request(usageURL, headers: headers)
    }

    // MARK: - 解析

    private static func parseUsage(_ json: [String: Any], idToken: String?) -> ProviderUsage {
        let rl = json["rate_limit"] as? [String: Any] ?? json["rate_limits"] as? [String: Any] ?? [:]
        let primary = rl["primary_window"] ?? rl["primary"]
        let secondary = rl["secondary_window"] ?? rl["secondary"]
        let parsedPrimary = parseWindow(primary)
        let parsedSecondary = parseWindow(secondary)
        let hourly: WindowUsage?
        let weekly: WindowUsage?

        // API 通常用 primary/secondary 表示 5 小时/周，但窗口数量变化后
        // primary 可能代表唯一剩余的周窗，因此优先依据窗口周期归类。
        if parsedSecondary != nil {
            hourly = parsedPrimary
            weekly = parsedSecondary
        } else if let primaryDict = primary as? [String: Any], let parsedPrimary {
            if isWeeklyWindow(primaryDict) {
                hourly = nil
                weekly = parsedPrimary
            } else {
                hourly = parsedPrimary
                weekly = nil
            }
        } else {
            hourly = parsedPrimary
            weekly = nil
        }
        return ProviderUsage(
            hourly: hourly,
            weekly: weekly,
            plan: json["plan_type"] as? String,
            planExpiresAt: idToken.flatMap(subscriptionExpiry)
        )
    }

    /// 从 id_token 的 claims 里取订阅到期时间（chatgpt_subscription_active_until）。
    private static func subscriptionExpiry(idToken: String) -> Date? {
        guard let claims = jwtPayload(idToken),
              let auth = claims["https://api.openai.com/auth"] as? [String: Any],
              let until = auth["chatgpt_subscription_active_until"] as? String else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: until) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: until)
    }

    private static func parseWindow(_ value: Any?) -> WindowUsage? {
        guard let dict = value as? [String: Any] else { return nil }
        // 百分比缺失/非法时宁可不显示该窗口，也不能默认 0 已用谎报"剩 100%"
        guard let raw = dict["used_percent"] as? Double, raw.isFinite else { return nil }
        let used = min(max(raw, 0), 100)
        var resets: Date?
        if let t = dict["reset_at"] as? Double {
            resets = Date(timeIntervalSince1970: t)
        } else if let s = dict["resets_in_seconds"] as? Double {
            resets = Date(timeIntervalSinceNow: s)
        } else if let s = dict["reset_after_seconds"] as? Double {
            resets = Date(timeIntervalSinceNow: s)
        }
        return WindowUsage(usedPercent: used, resetsAt: resets)
    }

    private static func isWeeklyWindow(_ dict: [String: Any]) -> Bool {
        let durationKeys = ["window_seconds", "limit_window_seconds", "window_duration_seconds"]
        if let duration = durationKeys.compactMap({ dict[$0] as? Double }).first {
            return duration > 24 * 60 * 60
        }
        for key in ["window_type", "window_name", "duration"] {
            if let value = dict[key] as? String {
                let normalized = value.lowercased()
                if normalized.contains("week") || normalized.contains("7_day") || normalized.contains("seven") {
                    return true
                }
                if normalized.contains("hour") || normalized.contains("5_hour") || normalized.contains("five") {
                    return false
                }
            }
        }
        if let resetAt = dict["reset_at"] as? Double {
            return resetAt - Date().timeIntervalSince1970 > 24 * 60 * 60
        }
        return false
    }
}

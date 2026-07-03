import Foundation
import CryptoKit

/// ByteRate 自己的 Claude OAuth 登录（PKCE）。
/// 目的：拥有一条独立于 Claude Code CLI 的 token 链，存放在 ByteRate 自己的文件里——
/// 读写不碰 CLI 的钥匙串条目，从根上消除 "security 想要访问" 弹框，也不会把 CLI 登出。
/// 凭据存文件而非钥匙串：ad-hoc 签名每次升级都会让钥匙串重新授权，文件则永远安静；
/// 安全等级与 ~/.codex/auth.json 相同（0600，仅本用户可读）。
enum ClaudeAuth {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e" // Claude Code 公开 client_id
    private static let redirectURI = "https://console.anthropic.com/oauth/code/callback"
    private static let scopes = "org:create_api_key user:profile user:inference"

    private static var filePath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ByteRate/claude.json")
    }

    // MARK: - 存储

    struct Credentials: Codable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Double        // 毫秒
        var subscriptionType: String?
    }

    static var hasOwnCredentials: Bool {
        FileManager.default.fileExists(atPath: filePath.path)
    }

    static func load() -> Credentials? {
        guard let data = try? Data(contentsOf: filePath) else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }

    static func save(_ creds: Credentials) throws {
        let dir = filePath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(creds)
        try data.write(to: filePath, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: filePath.path)
    }

    static func logout() {
        try? FileManager.default.removeItem(at: filePath)
    }

    // MARK: - PKCE 流程

    /// 一次登录会话：生成 verifier/challenge，返回要打开的授权页 URL。
    struct Session {
        let verifier: String
        let authorizeURL: URL
    }

    static func beginLogin() -> Session {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = Data(bytes).base64URLEncoded
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded

        var comps = URLComponents(string: "https://claude.ai/oauth/authorize")!
        comps.queryItems = [
            .init(name: "code", value: "true"),
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: scopes),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: verifier),
        ]
        return Session(verifier: verifier, authorizeURL: comps.url!)
    }

    /// 用浏览器给出的授权码（形如 "code#state"）换取 token 并保存。
    static func completeLogin(pastedCode: String, session: Session) async throws {
        let parts = pastedCode.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "#")
        guard let code = parts.first, !code.isEmpty else {
            throw UsageError.message("授权码为空", "Empty authorization code")
        }
        let state = parts.count > 1 ? String(parts[1]) : session.verifier

        let body: [String: Any] = [
            "grant_type": "authorization_code",
            "code": String(code),
            "state": state,
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "code_verifier": session.verifier,
        ]
        // console.anthropic.com 是标准换码端点；被限流时回退 claude.ai
        var (status, data) = try await HTTP.request("https://console.anthropic.com/v1/oauth/token",
                                                    method: "POST", jsonBody: body)
        if status == 429 || status >= 500 {
            (status, data) = try await HTTP.request("https://claude.ai/v1/oauth/token",
                                                    method: "POST", jsonBody: body)
        }
        guard status == 200 else {
            throw UsageError.message("换取 token 失败（\(status)），请重试登录",
                                     "Token exchange failed (\(status)) — please retry sign-in")
        }
        let json = HTTP.json(data)
        guard let access = json["access_token"] as? String,
              let refresh = json["refresh_token"] as? String else {
            throw UsageError.message("授权响应缺少 token", "Auth response missing tokens")
        }
        let expiresIn = json["expires_in"] as? Double ?? 28800
        var creds = Credentials(accessToken: access, refreshToken: refresh,
                                expiresAt: (Date().timeIntervalSince1970 + expiresIn) * 1000,
                                subscriptionType: nil)
        // 顺手取一次套餐名做徽章，失败不影响登录
        if let (s, d) = try? await HTTP.request("https://api.anthropic.com/api/oauth/profile",
                                                headers: ["Authorization": "Bearer \(access)",
                                                          "anthropic-beta": "oauth-2025-04-20"]),
           s == 200,
           let account = HTTP.json(d)["account"] as? [String: Any] {
            if account["has_claude_max"] as? Bool == true { creds.subscriptionType = "max" }
            else if account["has_claude_pro"] as? Bool == true { creds.subscriptionType = "pro" }
        }
        try save(creds)
    }

    // MARK: - 刷新（自己的链，随便刷，不影响任何人）

    static func refreshedCredentials(_ creds: Credentials) async throws -> Credentials {
        let (status, data) = try await HTTP.request(
            "https://claude.ai/v1/oauth/token", method: "POST",
            jsonBody: ["grant_type": "refresh_token", "refresh_token": creds.refreshToken, "client_id": clientID]
        )
        if status == 429 { throw UsageError.message("token 刷新被限流，稍后自动重试", "Token refresh rate-limited, will retry") }
        guard status == 200 else {
            throw UsageError.message("token 刷新失败（\(status)），请在菜单里重新登录 Claude",
                                     "Token refresh failed (\(status)) — sign in to Claude again from the menu")
        }
        let json = HTTP.json(data)
        guard let access = json["access_token"] as? String else {
            throw UsageError.message("刷新响应缺少 access_token", "Refresh response missing access_token")
        }
        var out = creds
        out.accessToken = access
        if let rt = json["refresh_token"] as? String { out.refreshToken = rt }
        let expiresIn = json["expires_in"] as? Double ?? 28800
        out.expiresAt = (Date().timeIntervalSince1970 + expiresIn) * 1000
        try save(out)
        return out
    }
}

private extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

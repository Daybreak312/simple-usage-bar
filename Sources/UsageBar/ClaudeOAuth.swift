import CryptoKit
import Foundation
import Security

/// Claude Code's own OAuth PKCE flow, embedded. Needed because usage/profile
/// endpoints require the `user:profile` scope, which `claude setup-token`
/// long-lived tokens don't carry (403 확인: 2026-07-10).
///
/// Flow: open authorize URL in a browser (incognito for other accounts) →
/// user approves → console shows `code#state` → exchange for access+refresh.
enum ClaudeOAuth {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let authorizeBase = "https://claude.ai/oauth/authorize"
    static let tokenURL = "https://console.anthropic.com/v1/oauth/token"
    static let redirectURI = "https://console.anthropic.com/oauth/code/callback"
    static let scopes = "org:create_api_key user:profile user:inference"

    struct Session {
        let url: URL
        let verifier: String
        let state: String
    }

    static func begin() -> Session {
        let verifier = randomURLSafe(32)
        let state = randomURLSafe(32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
        var comps = URLComponents(string: authorizeBase)!
        comps.queryItems = [
            .init(name: "code", value: "true"),
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: scopes),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ]
        return Session(url: comps.url!, verifier: verifier, state: state)
    }

    /// Exchange the pasted authorization code (`code` or `code#state`) for tokens.
    /// Returns secrets plus the account email when the response carries it.
    static func exchange(pasted: String, session: Session) async throws -> (AccountSecrets, String?) {
        let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw UsageBarError.invalidCredentials("승인 코드가 비어 있음")
        }
        let parts = trimmed.split(separator: "#", maxSplits: 1)
        let code = String(parts[0])
        let state = parts.count > 1 ? String(parts[1]) : session.state

        let body = try JSONSerialization.data(withJSONObject: [
            "grant_type": "authorization_code",
            "code": code,
            "state": state,
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "code_verifier": session.verifier,
        ])
        let (status, data) = try await HTTP.request(
            tokenURL, method: "POST",
            headers: ["Content-Type": "application/json"], body: body)
        guard status == 200 else {
            throw UsageBarError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        let obj = try HTTP.json(data)
        guard let access = obj["access_token"] as? String else {
            throw UsageBarError.parse("access_token 없음")
        }
        let secrets = AccountSecrets(
            accessToken: access,
            refreshToken: obj["refresh_token"] as? String,
            idToken: nil,
            accountId: nil
        )
        var email: String?
        if let account = obj["account"] as? [String: Any] {
            email = (account["email_address"] as? String) ?? (account["email"] as? String)
        }
        return (secrets, email)
    }

    /// Refresh an expired access token. Persist the result immediately —
    /// assume the refresh token rotates (proven true for Codex; safe either way).
    static func refresh(_ secrets: AccountSecrets) async throws -> AccountSecrets {
        guard let refreshToken = secrets.refreshToken else {
            throw UsageBarError.tokenExpired
        }
        let body = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ])
        let (status, data) = try await HTTP.request(
            tokenURL, method: "POST",
            headers: ["Content-Type": "application/json"], body: body)
        guard status == 200 else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw UsageBarError.invalidCredentials(
                "토큰 갱신 실패 (HTTP \(status)) — 재로그인 필요할 수 있음: \(text.prefix(160))")
        }
        let obj = try HTTP.json(data)
        var updated = secrets
        updated.accessToken = obj["access_token"] as? String ?? updated.accessToken
        updated.refreshToken = obj["refresh_token"] as? String ?? updated.refreshToken
        return updated
    }

    private static func randomURLSafe(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes).base64URLEncoded()
    }
}

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

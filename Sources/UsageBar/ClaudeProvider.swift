import Foundation

/// Claude Code OAuth usage API.
///
/// Verified live 2026-07-10 on this machine:
///   GET https://api.anthropic.com/api/oauth/usage
///   GET https://api.anthropic.com/api/oauth/profile
///   Headers: Authorization: Bearer sk-ant-oat01-… + anthropic-beta: oauth-2025-04-20
/// Response: five_hour/seven_day {utilization: 0-100, resets_at: ISO8601},
///           limits[] {kind, percent, resets_at, scope.model.display_name}.
struct ClaudeProvider: UsageProvider {
    static let usageURL = "https://api.anthropic.com/api/oauth/usage"
    static let profileURL = "https://api.anthropic.com/api/oauth/profile"
    static let betaHeader = "oauth-2025-04-20"

    func fetchUsage(account: Account, store: AccountStore) async throws -> UsageSnapshot {
        switch account.kind {
        case .localClaudeCLI:
            let token = try Self.readLocalCLIToken()
            let (code, data) = try await HTTP.request(Self.usageURL, headers: headers(token))
            guard code == 200 else {
                if code == 401 {
                    throw UsageBarError.invalidCredentials(
                        "로컬 Claude Code 토큰 만료 — 그 계정으로 claude를 한 번 실행하면 갱신됨")
                }
                throw UsageBarError.http(code, String(data: data, encoding: .utf8) ?? "")
            }
            return try Self.parseUsage(data)

        case .storedToken:
            guard let secrets = store.secrets(for: account.id) else {
                throw UsageBarError.invalidCredentials("저장된 토큰 없음")
            }
            let (snapshot, updated) = try await probe(secrets: secrets)
            if updated.accessToken != secrets.accessToken
                || updated.refreshToken != secrets.refreshToken {
                try store.updateSecrets(for: account.id, updated)
            }
            return snapshot
        }
    }

    func probe(secrets: AccountSecrets) async throws -> (UsageSnapshot, AccountSecrets) {
        guard let token = secrets.accessToken else {
            throw UsageBarError.invalidCredentials("accessToken 없음")
        }
        let (code, data) = try await HTTP.request(Self.usageURL, headers: headers(token))
        if code == 200 {
            return (try Self.parseUsage(data), secrets)
        }
        // Expired access token + refresh token on hand → refresh, persist, retry once.
        if code == 401, secrets.refreshToken != nil {
            let updated = try await ClaudeOAuth.refresh(secrets)
            let (code2, data2) = try await HTTP.request(
                Self.usageURL, headers: headers(updated.accessToken ?? ""))
            guard code2 == 200 else {
                throw UsageBarError.http(code2, String(data: data2, encoding: .utf8) ?? "")
            }
            return (try Self.parseUsage(data2), updated)
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        if code == 401 { throw UsageBarError.tokenExpired }
        if code == 403 {
            throw UsageBarError.invalidCredentials(
                "usage 엔드포인트 거부 (403) — user:profile 스코프 없는 토큰 (setup-token은 불가, OAuth 로그인 사용). 응답: \(body.prefix(160))")
        }
        throw UsageBarError.http(code, body)
    }

    func resolveLabel(secrets: AccountSecrets) async throws -> String {
        guard let token = secrets.accessToken else {
            throw UsageBarError.invalidCredentials("accessToken 없음")
        }
        let (code, data) = try await HTTP.request(Self.profileURL, headers: headers(token))
        guard code == 200 else {
            throw UsageBarError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        let obj = try HTTP.json(data)
        guard let acct = obj["account"] as? [String: Any],
              let email = acct["email"] as? String else {
            throw UsageBarError.parse("account.email 없음")
        }
        return email
    }

    // MARK: - Parsing

    static func parseUsage(_ data: Data) throws -> UsageSnapshot {
        let obj = try HTTP.json(data)

        func window(_ key: String) -> WindowUsage? {
            guard let w = obj[key] as? [String: Any],
                  let pct = w["utilization"] as? Double else { return nil }
            return WindowUsage(percent: pct, resetsAt: Dates.fromISO(w["resets_at"] as? String))
        }

        var details: [String] = []
        if let limits = obj["limits"] as? [[String: Any]] {
            for limit in limits where limit["kind"] as? String == "weekly_scoped" {
                if let scope = limit["scope"] as? [String: Any],
                   let model = scope["model"] as? [String: Any],
                   let name = model["display_name"] as? String,
                   let pct = limit["percent"] as? Double {
                    details.append("\(name) \(Int(pct))%")
                }
            }
        }

        return UsageSnapshot(
            fiveHour: window("five_hour"),
            sevenDay: window("seven_day"),
            details: details,
            fetchedAt: Date()
        )
    }

    // MARK: - Credentials

    private func headers(_ token: String) -> [String: String] {
        [
            "Authorization": "Bearer \(token)",
            "anthropic-beta": Self.betaHeader,
        ]
    }

    /// Reads the local Claude Code credential via /usr/bin/security. The CLI
    /// keychain item is read-only for us on purpose: refreshing it ourselves
    /// would race Claude Code over the token lineage (see the Codex
    /// refresh_token_reused incident). The CLI
    /// tool is Apple-signed, so this avoids per-build keychain ACL prompts an
    /// unsigned dev binary would trigger with a direct SecItemCopyMatching.
    static func readLocalCLIToken() throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw UsageBarError.localCLIUnavailable("keychain 항목 'Claude Code-credentials' 조회 실패")
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else {
            throw UsageBarError.localCLIUnavailable("자격증명 JSON 구조가 예상과 다름")
        }
        return token
    }
}

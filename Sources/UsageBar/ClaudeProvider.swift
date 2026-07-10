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
        let token = try accessToken(for: account, store: store)
        let (code, data) = try await HTTP.request(Self.usageURL, headers: headers(token))
        guard code == 200 else {
            if code == 401 {
                throw account.kind == .localClaudeCLI
                    ? UsageBarError.invalidCredentials("로컬 Claude Code 토큰 만료 — 그 계정으로 claude를 한 번 실행하면 갱신됨")
                    : UsageBarError.tokenExpired
            }
            throw UsageBarError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        return try Self.parseUsage(data)
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
                    details.append("\(name) 주간 \(Int(pct))%")
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

    private func accessToken(for account: Account, store: AccountStore) throws -> String {
        switch account.kind {
        case .storedToken:
            guard let token = store.secrets(for: account.id)?.accessToken else {
                throw UsageBarError.invalidCredentials("저장된 토큰 없음")
            }
            return token
        case .localClaudeCLI:
            // Read the Claude Code CLI keychain item fresh on every poll.
            // Read-only on purpose: refreshing it ourselves would race the CLI
            // over the token lineage (see the Codex refresh_token_reused incident).
            return try Self.readLocalCLIToken()
        }
    }

    /// Reads the local Claude Code credential via /usr/bin/security. The CLI
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

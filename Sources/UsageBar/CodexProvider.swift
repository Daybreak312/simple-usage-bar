import Foundation

/// OpenAI Codex (ChatGPT subscription) usage API.
///
/// Endpoint/spec source: codex-rs source via CodexBar docs (MIT), 2026-07-10.
///   GET https://chatgpt.com/backend-api/wham/usage
///   Headers: Authorization: Bearer <access> + ChatGPT-Account-Id + User-Agent: codex-cli
///   Response: rate_limit.primary_window/secondary_window
///             {used_percent, reset_at: epoch sec, limit_window_seconds}, plan_type, credits.
///   Window positions are NOT fixed to durations — weekly-only plans send the
///   7d window as primary_window with secondary_window null.
///
/// Refresh: POST https://auth.openai.com/oauth/token — refresh tokens are
/// SINGLE-USE and rotate. The rotated token must be persisted immediately or
/// the lineage dies (`refresh_token_reused`, observed live on this machine).
struct CodexProvider: UsageProvider {
    static let usageURL = "https://chatgpt.com/backend-api/wham/usage"
    static let tokenURL = "https://auth.openai.com/oauth/token"
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    func fetchUsage(account: Account, store: AccountStore) async throws -> UsageSnapshot {
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

    func probe(secrets: AccountSecrets) async throws -> (UsageSnapshot, AccountSecrets) {
        do {
            return (try await fetchOnce(secrets), secrets)
        } catch UsageBarError.tokenExpired {
            let updated = try await Self.refresh(secrets: secrets)
            return (try await fetchOnce(updated), updated)
        }
    }

    func resolveLabel(secrets: AccountSecrets) async throws -> String {
        if let idToken = secrets.idToken, let email = JWT.email(idToken) { return email }
        if let access = secrets.accessToken, let email = JWT.email(access) { return email }
        return "codex-\(secrets.accountId?.prefix(8) ?? "unknown")"
    }

    // MARK: - Fetch

    private func fetchOnce(_ secrets: AccountSecrets) async throws -> UsageSnapshot {
        guard let token = secrets.accessToken else {
            throw UsageBarError.invalidCredentials("accessToken 없음")
        }
        var headers = [
            "Authorization": "Bearer \(token)",
            "User-Agent": "codex-cli",
        ]
        if let accountId = secrets.accountId {
            headers["ChatGPT-Account-Id"] = accountId
        }
        let (code, data) = try await HTTP.request(Self.usageURL, headers: headers)
        if code == 401 { throw UsageBarError.tokenExpired }
        guard code == 200 else {
            throw UsageBarError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        return try Self.parseUsage(data)
    }

    static func parseUsage(_ data: Data) throws -> UsageSnapshot {
        let obj = try HTTP.json(data)
        let rateLimit = obj["rate_limit"] as? [String: Any] ?? obj

        func window(_ key: String) -> (usage: WindowUsage, seconds: Double?)? {
            guard let w = rateLimit[key] as? [String: Any] else { return nil }
            let pct = (w["used_percent"] as? Double) ?? (w["used_percent"] as? Int).map(Double.init)
            guard let pct else { return nil }
            var resets = Dates.fromEpoch(w["reset_at"])
            if resets == nil, let inSec = w["resets_in_seconds"] as? Double {
                resets = Date().addingTimeInterval(inSec)
            }
            let seconds = (w["limit_window_seconds"] as? Double)
                ?? (w["limit_window_seconds"] as? Int).map(Double.init)
            return (WindowUsage(percent: pct, resetsAt: resets), seconds)
        }

        // Slot windows by duration, not by position: weekly-only plans deliver
        // the 7d window in primary_window with secondary_window null (verified
        // against CodexBar's fixtures). Positional fallback when
        // limit_window_seconds is absent; on slot collision, fill the vacant
        // slot so no window is dropped.
        var fiveHour: WindowUsage?
        var sevenDay: WindowUsage?
        for (key, weeklyByPosition) in [("primary_window", false), ("secondary_window", true)] {
            guard let w = window(key) else { continue }
            let weekly = w.seconds.map { $0 >= 86_400 } ?? weeklyByPosition
            if weekly, sevenDay == nil {
                sevenDay = w.usage
            } else if !weekly, fiveHour == nil {
                fiveHour = w.usage
            } else if sevenDay == nil {
                sevenDay = w.usage
            } else if fiveHour == nil {
                fiveHour = w.usage
            }
        }

        var details: [String] = []
        if let plan = obj["plan_type"] as? String { details.append("플랜 \(plan)") }
        if let credits = obj["credits"] as? [String: Any] {
            if credits["unlimited"] as? Bool == true {
                details.append("크레딧 무제한")
            } else if let balance = credits["balance"] as? Double, balance > 0 {
                details.append("크레딧 \(String(format: "%.0f", balance))")
            }
        }

        return UsageSnapshot(
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            details: details,
            fetchedAt: Date()
        )
    }

    // MARK: - Refresh (rotating!)

    static func refresh(secrets: AccountSecrets) async throws -> AccountSecrets {
        guard let refreshToken = secrets.refreshToken else {
            throw UsageBarError.invalidCredentials("refreshToken 없음 — auth.json 다시 등록 필요")
        }
        let body = try JSONSerialization.data(withJSONObject: [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": "openid profile email",
        ])
        let (code, data) = try await HTTP.request(
            tokenURL, method: "POST",
            headers: ["Content-Type": "application/json"],
            body: body
        )
        guard code == 200 else {
            let text = String(data: data, encoding: .utf8) ?? ""
            if text.contains("refresh_token_reused") {
                throw UsageBarError.invalidCredentials(
                    "리프레시 토큰 계보를 다른 곳이 가져감 — 이 계정을 다시 등록해야 함")
            }
            throw UsageBarError.http(code, text)
        }
        let obj = try HTTP.json(data)
        var updated = secrets
        updated.accessToken = obj["access_token"] as? String ?? updated.accessToken
        updated.refreshToken = obj["refresh_token"] as? String ?? updated.refreshToken
        updated.idToken = obj["id_token"] as? String ?? updated.idToken
        return updated
    }

    // MARK: - auth.json import

    /// Parse a pasted ~/.codex/auth.json payload into secrets.
    static func secretsFromAuthJSON(_ text: String) throws -> AccountSecrets {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any] else {
            throw UsageBarError.invalidCredentials("auth.json 형식이 아님 (tokens 키 없음)")
        }
        return AccountSecrets(
            accessToken: tokens["access_token"] as? String,
            refreshToken: tokens["refresh_token"] as? String,
            idToken: tokens["id_token"] as? String,
            accountId: tokens["account_id"] as? String
        )
    }
}

func provider(for p: Provider) -> UsageProvider {
    switch p {
    case .claude: return ClaudeProvider()
    case .codex: return CodexProvider()
    }
}

import Foundation

enum Provider: String, Codable, CaseIterable, Identifiable {
    case claude
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }
}

/// How credentials for an account are sourced.
enum CredentialKind: String, Codable {
    /// Long-lived token pasted by the user, stored in our secrets store.
    case storedToken
    /// Piggyback on the local Claude Code CLI keychain item (read-only, never refreshed by us).
    case localClaudeCLI
}

struct Account: Codable, Identifiable, Equatable {
    let id: UUID
    let provider: Provider
    let kind: CredentialKind
    /// User-facing identifier, normally the account email.
    var label: String
    var addedAt: Date

    init(provider: Provider, kind: CredentialKind, label: String) {
        self.id = UUID()
        self.provider = provider
        self.kind = kind
        self.label = label
        self.addedAt = Date()
    }
}

extension Account {
    /// Comparable identity: the label without the local-login marker.
    var email: String {
        label.hasSuffix(" (로컬)") ? String(label.dropLast(" (로컬)".count)) : label
    }
}

/// Secrets for one account. Fields used depend on the provider.
struct AccountSecrets: Codable {
    var accessToken: String?
    var refreshToken: String?
    var idToken: String?
    /// Codex: ChatGPT-Account-Id header value.
    var accountId: String?
    /// Claude: access token expiry (ms epoch), mirrored from the token response.
    var expiresAtMs: Int64?
    /// Claude: scopes granted to this token pair. nil = legacy registration
    /// (the old 3-scope set) — still usable for rolling, with degraded
    /// Claude Code features (no sessions/MCP/file-upload scopes).
    var scopes: [String]?
    /// Claude rolling: verbatim keychain item JSON harvested when this
    /// account was last active locally. Restoring it hands Claude Code back
    /// the exact lineage (subscriptionType/rateLimitTier included).
    var claudeKeychainItem: String?
}

struct WindowUsage: Equatable {
    /// 0...100
    var percent: Double
    var resetsAt: Date?
}

struct UsageSnapshot: Equatable {
    var fiveHour: WindowUsage?
    var sevenDay: WindowUsage?
    /// Short extra facts, e.g. model-scoped weekly limits or plan/credits.
    var details: [String] = []
    /// Claude: highest model-scoped weekly limit percent (e.g. Fable weekly).
    /// Feeds the rolling trip metric alongside 5h/7d.
    var modelWeeklyMax: Double?
    var fetchedAt: Date
    /// Identity the provider observed during this fetch, when it can know it
    /// (local-CLI accounts: the login can switch to another account between
    /// polls). nil = no identity info; keep the stored label.
    var resolvedLabel: String?
}

/// One row of state as shown in the UI.
struct AccountState: Identifiable, Equatable {
    var account: Account
    var snapshot: UsageSnapshot?
    var lastError: String?
    var isRefreshing: Bool = false

    var id: UUID { account.id }

    /// Highest utilization across windows, used for the menu bar summary.
    var maxPercent: Double? {
        let values = [snapshot?.fiveHour?.percent, snapshot?.sevenDay?.percent].compactMap { $0 }
        return values.max()
    }
}

enum UsageBarError: LocalizedError {
    case http(Int, String)
    case tokenExpired
    case invalidCredentials(String)
    case parse(String)
    case localCLIUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .http(let code, let body):
            return "HTTP \(code): \(body.prefix(160))"
        case .tokenExpired:
            return "토큰 만료 — 재발급 필요"
        case .invalidCredentials(let why):
            return "자격증명 오류: \(why)"
        case .parse(let why):
            return "응답 파싱 실패: \(why)"
        case .localCLIUnavailable(let why):
            return "로컬 Claude CLI 자격증명 없음: \(why)"
        }
    }
}

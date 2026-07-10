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

/// Secrets for one account. Fields used depend on the provider.
struct AccountSecrets: Codable {
    var accessToken: String?
    var refreshToken: String?
    var idToken: String?
    /// Codex: ChatGPT-Account-Id header value.
    var accountId: String?
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
    var fetchedAt: Date
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

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
    /// Codex accounts use this. Claude rows of this kind are legacy OAuth
    /// registrations — kept for decoding, no longer polled or rolled.
    case storedToken
    /// Legacy: piggybacked on the local Claude Code keychain login. Kept only
    /// so old accounts.json files still decode; never polled.
    case localClaudeCLI
    /// Claude: 1-year token from `claude setup-token` (`sk-ant-oat01-…`,
    /// scope `user:inference`). The only Claude kind the app polls and rolls.
    case setupToken
}

struct Account: Codable, Identifiable, Equatable {
    let id: UUID
    let provider: Provider
    let kind: CredentialKind
    /// User-facing identifier, normally the account email.
    var label: String
    var addedAt: Date
    /// Rolling candidate priority — lower wins. nil = default (1).
    var rollPriority: Int?
    /// Claude: `anthropic-organization-id` seen on the probe response. Used to
    /// warn when the same account is registered twice. nil = unknown/legacy.
    var organizationId: String?

    init(provider: Provider, kind: CredentialKind, label: String, organizationId: String? = nil) {
        self.id = UUID()
        self.provider = provider
        self.kind = kind
        self.label = label
        self.addedAt = Date()
        self.organizationId = organizationId
    }

    var priority: Int { rollPriority ?? 1 }

    /// Claude row from before the 1-year-token switch (OAuth / local CLI).
    /// Shown with a "재등록 필요" notice; never polled, never a roll target.
    /// Its secrets stay untouched until the user deletes the row.
    var needsReregistration: Bool { provider == .claude && kind != .setupToken }

    /// Claude account the app polls, rolls and hands to the wrapper.
    var isClaudeToken: Bool { provider == .claude && kind == .setupToken }
}

extension Account {
    /// Comparable identity: the label without the legacy local-login marker.
    var email: String {
        label.hasSuffix(" (로컬)") ? String(label.dropLast(" (로컬)".count)) : label
    }
}

/// Secrets for one account. Fields used depend on the provider.
///
/// Legacy Claude fields (refreshToken/expiresAtMs/scopes/claudeKeychainItem)
/// stay in the schema on purpose: secrets.json is rewritten whole on every
/// change, so dropping a field here would silently erase it from old rows
/// that the user hasn't deleted yet.
struct AccountSecrets: Codable {
    /// Claude: the 1-year token. Codex: OAuth access token.
    var accessToken: String?
    var refreshToken: String?
    var idToken: String?
    /// Codex: ChatGPT-Account-Id header value.
    var accountId: String?
    /// Legacy Claude OAuth: access token expiry (ms epoch).
    var expiresAtMs: Int64?
    /// Legacy Claude OAuth: granted scopes.
    var scopes: [String]?
    /// Legacy Claude rolling: harvested keychain item JSON.
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
    /// Short extra facts, e.g. limit status or plan/credits.
    var details: [String] = []
    var fetchedAt: Date
    /// Claude: raw `anthropic-ratelimit-unified-status`
    /// (`allowed` / `allowed_warning` / `rejected`). nil = unknown (Codex).
    var limitStatus: String?
    /// Claude: `anthropic-organization-id` of the token's account.
    var organizationId: String?

    /// The server refused requests for this account (limit reached).
    var isLimitRejected: Bool { limitStatus == "rejected" }
}

/// One row of state as shown in the UI.
struct AccountState: Identifiable, Equatable {
    var account: Account
    var snapshot: UsageSnapshot?
    var lastError: String?
    var isRefreshing: Bool = false
    /// 최신 조회가 일시 실패(429 레이트리밋 등)해 지금 보이는 스냅샷이
    /// 이전 값일 때의 안내 문구. 성공 조회가 오면 지워진다.
    var staleNote: String?

    var id: UUID { account.id }

    /// Highest utilization across windows, used for the menu bar summary.
    var maxPercent: Double? {
        let values = [snapshot?.fiveHour?.percent, snapshot?.sevenDay?.percent].compactMap { $0 }
        return values.max()
    }
}

enum UsageBarError: LocalizedError {
    case http(Int, String)
    case rateLimited(retryAfter: TimeInterval?)
    case tokenExpired
    case invalidCredentials(String)
    case parse(String)
    /// Claude 1-year token rejected by the server (401/403).
    case tokenInvalid(Int)
    /// Legacy Claude row (OAuth / local CLI) — must be re-registered.
    case reregistrationRequired

    var errorDescription: String? {
        switch self {
        case .http(let code, let body):
            return "HTTP \(code): \(body.prefix(160))"
        case .rateLimited(let after):
            let hint = after.map { " — \(Int($0))초 뒤 재시도 가능" } ?? ""
            return "레이트리밋 (HTTP 429)\(hint)"
        case .tokenExpired:
            return "토큰 만료 — 재발급 필요"
        case .invalidCredentials(let why):
            return "자격증명 오류: \(why)"
        case .parse(let why):
            return "응답 파싱 실패: \(why)"
        case .tokenInvalid(let code):
            return "토큰 무효 또는 폐기됨 (HTTP \(code)) — `claude setup-token`으로 재발급 필요"
        case .reregistrationRequired:
            return Account.reregistrationNotice
        }
    }
}

extension Account {
    static let reregistrationNotice = "1년 토큰으로 재등록 필요"
}

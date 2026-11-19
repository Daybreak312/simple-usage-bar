import Foundation

/// Claude 1-year token (`claude setup-token`) usage via a 1-token probe.
///
/// setup-token tokens carry only `user:inference`, so /api/oauth/usage and
/// /api/oauth/profile answer 403 (`oauth_scope_insufficient`). The limit state
/// rides on every inference response instead. Verified live 2026-11-19 on this
/// machine (claude 2.1.293):
///   POST https://api.anthropic.com/v1/messages  (haiku, max_tokens 1)
///   Authorization: Bearer sk-ant-oat01-… + anthropic-beta: oauth-2025-04-20
///   → 200 with anthropic-ratelimit-unified-7d-utilization (0~1),
///     -7d-reset (epoch s), -7d-status, -status, -reset,
///     -representative-claim, -overage-status, anthropic-organization-id.
///     Ultra plans send no 5h headers.
///   Non-haiku models 429 (no ratelimit headers) unless the system prompt is
///   the Claude Code one — the probe always sends it so there is one contract.
///   count_tokens returns no ratelimit headers, so it can't replace this.
struct ClaudeProvider: UsageProvider {
    static let messagesURL = "https://api.anthropic.com/v1/messages"
    static let betaHeader = "oauth-2025-04-20"
    static let apiVersion = "2023-06-01"
    static let probeModel = "claude-haiku-4-5"
    static let systemPrompt = "You are Claude Code, Anthropic's official CLI for Claude."

    /// Exact probe body. A literal (not JSONSerialization) so the bytes on the
    /// wire are fixed and testable.
    static let probeBody =
        #"{"model":"claude-haiku-4-5","max_tokens":1,"system":"You are Claude Code, Anthropic's official CLI for Claude.","messages":[{"role":"user","content":"."}]}"#

    /// Network seam — tests swap in recorded responses.
    var transport: (URLRequest) async throws -> HTTPResponse = HTTP.response

    func fetchUsage(account: Account, store: AccountStore) async throws -> UsageSnapshot {
        guard account.kind == .setupToken else {
            throw UsageBarError.reregistrationRequired
        }
        guard let secrets = store.secrets(for: account.id) else {
            throw UsageBarError.invalidCredentials("저장된 토큰 없음")
        }
        return try await probe(secrets: secrets).0
    }

    /// 1-year tokens never rotate, so the secrets come back unchanged.
    func probe(secrets: AccountSecrets) async throws -> (UsageSnapshot, AccountSecrets) {
        guard let token = secrets.accessToken, !token.isEmpty else {
            throw UsageBarError.invalidCredentials("토큰 없음")
        }
        let resp = try await transport(Self.probeRequest(token: token))
        return (try Self.interpret(resp), secrets)
    }

    /// setup-token tokens have no profile scope — the label is user input.
    func resolveLabel(secrets: AccountSecrets) async throws -> String {
        throw UsageBarError.invalidCredentials("1년 토큰은 이메일 조회 권한이 없음 — 라벨을 직접 입력해 주세요")
    }

    // MARK: - Request

    static func probeRequest(token: String) -> URLRequest {
        var req = URLRequest(url: URL(string: messagesURL)!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        req.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = Data(probeBody.utf8)
        return req
    }

    // MARK: - Response

    /// 200 → snapshot. 429 with unified status `rejected` → snapshot too (limit
    /// reached is a valid reading — rolling acts on it). Other 429s → the
    /// generic rate-limit path (keep previous value, honor Retry-After).
    /// 401/403 → token revoked/invalid.
    static func interpret(_ resp: HTTPResponse, now: Date = Date()) throws -> UsageSnapshot {
        let limits = RateLimitHeaders(resp)
        switch resp.status {
        case 200:
            guard limits.fiveHour != nil || limits.sevenDay != nil else {
                throw UsageBarError.parse("응답에 사용률 헤더(anthropic-ratelimit-unified-*-utilization)가 없음")
            }
            return limits.snapshot(fetchedAt: now)
        case 429:
            if limits.status == "rejected" {
                return limits.snapshot(fetchedAt: now)
            }
            throw UsageBarError.rateLimited(retryAfter: HTTP.retryAfter(resp))
        case 401, 403:
            throw UsageBarError.tokenInvalid(resp.status)
        default:
            throw UsageBarError.http(resp.status, resp.bodyText)
        }
    }

    /// `anthropic-ratelimit-unified-*` response headers.
    struct RateLimitHeaders: Equatable {
        static let prefix = "anthropic-ratelimit-unified-"

        var fiveHour: WindowUsage?
        var sevenDay: WindowUsage?
        var status: String?
        var fiveHourStatus: String?
        var sevenDayStatus: String?
        var representativeClaim: String?
        var overageStatus: String?
        var organizationId: String?

        init(_ resp: HTTPResponse) {
            func h(_ suffix: String) -> String? {
                resp.header(Self.prefix + suffix)?
                    .trimmingCharacters(in: .whitespaces)
                    .nilIfEmpty
            }
            func window(_ name: String) -> WindowUsage? {
                guard let raw = h("\(name)-utilization"), let ratio = Double(raw),
                      ratio.isFinite else { return nil }
                let reset = h("\(name)-reset").flatMap(Double.init)
                    .map { Date(timeIntervalSince1970: $0) }
                return WindowUsage(percent: ratio * 100, resetsAt: reset)
            }
            fiveHour = window("5h")
            sevenDay = window("7d")
            status = h("status")
            fiveHourStatus = h("5h-status")
            sevenDayStatus = h("7d-status")
            representativeClaim = h("representative-claim")
            overageStatus = h("overage-status")
            organizationId = resp.header("anthropic-organization-id")?
                .trimmingCharacters(in: .whitespaces).nilIfEmpty
        }

        func snapshot(fetchedAt: Date) -> UsageSnapshot {
            UsageSnapshot(
                fiveHour: fiveHour,
                sevenDay: sevenDay,
                details: details,
                fetchedAt: fetchedAt,
                limitStatus: status,
                organizationId: organizationId)
        }

        /// Short human-readable facts for the row's detail line.
        var details: [String] {
            var out: [String] = []
            if let status { out.append(Self.statusPhrase(status)) }
            for (name, s) in [("5h", fiveHourStatus), ("7d", sevenDayStatus)] {
                if let s, s != "allowed", s != status {
                    out.append("\(name) \(Self.statusPhrase(s))")
                }
            }
            if let claim = representativeClaim {
                out.append("기준 \(Self.claimName(claim))")
            }
            if let overage = overageStatus {
                out.append("초과 사용 \(Self.overagePhrase(overage))")
            }
            return out
        }

        static func statusPhrase(_ s: String) -> String {
            switch s {
            case "allowed": return "정상"
            case "allowed_warning": return "경고 구간"
            case "rejected": return "한도 거절"
            default: return s
            }
        }

        static func claimName(_ s: String) -> String {
            switch s {
            case "five_hour": return "5h"
            case "seven_day": return "7d"
            default: return s
            }
        }

        static func overagePhrase(_ s: String) -> String {
            switch s {
            case "allowed": return "가능"
            case "allowed_warning": return "경고"
            case "rejected": return "불가"
            default: return s
            }
        }
    }

    // MARK: - Token input

    /// Normalizes pasted token text. nil when it can't be a single token
    /// (empty, or whitespace/control characters inside — the active-account
    /// file is line-based, so a newline in a token would corrupt it).
    static func normalizeToken(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty,
              t.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F }) else {
            return nil
        }
        return t
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Registration checks shared by the add screen and `usagebar add-claude-token`.
enum ClaudeRegistration {
    /// Already-registered 1-year-token accounts of the same organization —
    /// i.e. the same Claude account registered twice (rolling between them
    /// would be pointless).
    static func sameOrganization(_ organizationId: String?, in accounts: [Account]) -> [Account] {
        guard let organizationId else { return [] }
        return accounts.filter { $0.isClaudeToken && $0.organizationId == organizationId }
    }

    /// The account already holding this exact token, if any.
    static func duplicateToken(_ token: String, in accounts: [Account], store: AccountStore) -> Account? {
        accounts.first { $0.isClaudeToken && store.secrets(for: $0.id)?.accessToken == token }
    }
}

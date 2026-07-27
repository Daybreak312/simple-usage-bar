import Foundation

/// A provider knows how to validate credentials (returning the account email)
/// and fetch a usage snapshot.
protocol UsageProvider {
    /// Fetch current usage. May mutate stored secrets (token refresh).
    func fetchUsage(account: Account, store: AccountStore) async throws -> UsageSnapshot
    /// Validate secrets and resolve the account's email/label.
    /// May fail on tokens without profile scope — callers should treat the
    /// label as optional and fall back to user input.
    func resolveLabel(secrets: AccountSecrets) async throws -> String
    /// Pre-save validation: hit the usage endpoint with the given secrets.
    /// Returns the snapshot plus possibly-rotated secrets (Codex refresh).
    func probe(secrets: AccountSecrets) async throws -> (UsageSnapshot, AccountSecrets)
}

enum HTTP {
    static func request(
        _ url: String,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval = 20
    ) async throws -> (Int, Data) {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = method
        req.timeoutInterval = timeout
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = body
        let (data, resp) = try await URLSession.shared.data(for: req)
        let http = resp as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        if code == 429 {
            // 모든 엔드포인트 공통: 429는 Retry-After(초 단위 숫자형)를 실어
            // 전용 에러로 던진다 — 폴러가 다음 조회를 그만큼 미룬다.
            // 날짜형 Retry-After는 드물어 nil 처리(기본 주기로 재시도).
            let after = http?.value(forHTTPHeaderField: "Retry-After")
                .flatMap(Double.init)
            throw UsageBarError.rateLimited(retryAfter: after)
        }
        return (code, data)
    }

    static func json(_ data: Data) throws -> [String: Any] {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageBarError.parse("최상위가 JSON 객체가 아님")
        }
        return obj
    }
}

enum Dates {
    /// Anthropic returns ISO8601 with fractional seconds; Codex returns epoch seconds.
    static func fromISO(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    static func fromEpoch(_ v: Any?) -> Date? {
        if let n = v as? Double { return Date(timeIntervalSince1970: n) }
        if let n = v as? Int { return Date(timeIntervalSince1970: Double(n)) }
        return nil
    }
}

/// Decode a JWT payload without verifying the signature — we only extract
/// non-security-relevant display fields (email) from tokens we already trust.
enum JWT {
    static func payload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func email(_ token: String) -> String? {
        guard let p = payload(token) else { return nil }
        if let e = p["email"] as? String { return e }
        if let profile = p["https://api.openai.com/profile"] as? [String: Any],
           let e = profile["email"] as? String { return e }
        return nil
    }
}

import XCTest
@testable import usagebar

/// 탐침 계약(F1·F2·F3) — 요청 생성과 응답 헤더 해석.
final class ClaudeProbeTests: XCTestCase {
    // MARK: - Request

    func testProbeRequestContract() throws {
        let req = ClaudeProvider.probeRequest(token: "sk-ant-oat01-abc")
        XCTAssertEqual(req.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-ant-oat01-abc")
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertEqual(req.value(forHTTPHeaderField: "content-type"), "application/json")
        XCTAssertEqual(req.allHTTPHeaderFields?.count, 4)

        let body = try XCTUnwrap(req.httpBody)
        XCTAssertEqual(
            String(data: body, encoding: .utf8),
            #"{"model":"claude-haiku-4-5","max_tokens":1,"system":"You are Claude Code, Anthropic's official CLI for Claude.","messages":[{"role":"user","content":"."}]}"#)
        // 구조로도 확인 (리터럴이 유효한 JSON인지).
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(obj["model"] as? String, "claude-haiku-4-5")
        XCTAssertEqual(obj["max_tokens"] as? Int, 1)
        XCTAssertEqual(obj["system"] as? String, "You are Claude Code, Anthropic's official CLI for Claude.")
        let messages = try XCTUnwrap(obj["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        XCTAssertEqual(messages[0]["content"] as? String, ".")
    }

    // MARK: - Header parsing

    func testSevenDayOnly() throws {
        let snap = try ClaudeProvider.interpret(probeResponse(200, ultraHeaders))
        XCTAssertNil(snap.fiveHour)
        XCTAssertEqual(try XCTUnwrap(snap.sevenDay?.percent), 62, accuracy: 1e-9)
        XCTAssertEqual(snap.sevenDay?.resetsAt, Date(timeIntervalSince1970: 1795143600))
        XCTAssertEqual(snap.limitStatus, "allowed")
        XCTAssertFalse(snap.isLimitRejected)
        XCTAssertEqual(snap.organizationId, "org-aaaa-1111")
        XCTAssertEqual(snap.details, ["정상", "기준 7d", "초과 사용 불가"])
    }

    func testFiveHourAndSevenDay() throws {
        var h = ultraHeaders
        h["anthropic-ratelimit-unified-5h-utilization"] = "0.9"
        h["anthropic-ratelimit-unified-5h-reset"] = "1795000000"
        h["anthropic-ratelimit-unified-5h-status"] = "allowed_warning"
        h["anthropic-ratelimit-unified-status"] = "allowed_warning"
        h["anthropic-ratelimit-unified-representative-claim"] = "five_hour"
        let snap = try ClaudeProvider.interpret(probeResponse(200, h))
        XCTAssertEqual(try XCTUnwrap(snap.fiveHour?.percent), 90, accuracy: 1e-9)
        XCTAssertEqual(snap.fiveHour?.resetsAt, Date(timeIntervalSince1970: 1795000000))
        XCTAssertEqual(try XCTUnwrap(snap.sevenDay?.percent), 62, accuracy: 1e-9)
        // 5h-status가 전체 status와 같으면 중복 표기하지 않는다.
        XCTAssertEqual(snap.details, ["경고 구간", "기준 5h", "초과 사용 불가"])
        XCTAssertEqual(try XCTUnwrap(RollingPolicy.trip(snap)), 90, accuracy: 1e-9)
    }

    func testHeaderNamesAreCaseInsensitive() throws {
        let shouted = Dictionary(uniqueKeysWithValues: ultraHeaders.map { ($0.key.uppercased(), $0.value) })
        let mixed = [
            "Anthropic-Ratelimit-Unified-7d-Utilization": "0.25",
            "Anthropic-Ratelimit-Unified-Status": "allowed",
            "Anthropic-Organization-Id": "org-b",
        ]
        let a = try ClaudeProvider.interpret(probeResponse(200, shouted))
        XCTAssertEqual(try XCTUnwrap(a.sevenDay?.percent), 62, accuracy: 1e-9)
        XCTAssertEqual(a.organizationId, "org-aaaa-1111")
        let b = try ClaudeProvider.interpret(probeResponse(200, mixed))
        XCTAssertEqual(try XCTUnwrap(b.sevenDay?.percent), 25, accuracy: 1e-9)
        XCTAssertNil(b.sevenDay?.resetsAt)
        XCTAssertEqual(b.organizationId, "org-b")
    }

    func testRejected429IsAValidSnapshot() throws {
        var h = ultraHeaders
        h["anthropic-ratelimit-unified-7d-utilization"] = "1.0"
        h["anthropic-ratelimit-unified-7d-status"] = "rejected"
        h["anthropic-ratelimit-unified-status"] = "rejected"
        let snap = try ClaudeProvider.interpret(probeResponse(429, h, body: #"{"type":"error"}"#))
        XCTAssertTrue(snap.isLimitRejected)
        XCTAssertEqual(try XCTUnwrap(snap.sevenDay?.percent), 100, accuracy: 1e-9)
        XCTAssertEqual(snap.details.first, "한도 거절")
        XCTAssertEqual(RollingPolicy.trip(snap), 100)
        XCTAssertEqual(RollingPolicy.tripName(snap), "한도 거절")
    }

    /// 헤더 수치가 낮아도 rejected면 롤링 지표는 100.
    func testRejectedWithLowUtilizationStillTrips() throws {
        var h = ultraHeaders
        h["anthropic-ratelimit-unified-7d-utilization"] = "0.40"
        h["anthropic-ratelimit-unified-status"] = "rejected"
        let snap = try ClaudeProvider.interpret(probeResponse(429, h))
        XCTAssertEqual(try XCTUnwrap(snap.sevenDay?.percent), 40, accuracy: 1e-9)  // 표시는 헤더 값 그대로
        XCTAssertEqual(RollingPolicy.trip(snap), 100)
    }

    func test429WithoutRateLimitHeadersIsRateLimited() {
        // F2: 비-haiku 429는 ratelimit 헤더 없이 온다 → 기존 지연 경로.
        let resp = probeResponse(429, ["Retry-After": "120"], body: #"{"type":"error","error":{"type":"rate_limit_error"}}"#)
        XCTAssertThrowsError(try ClaudeProvider.interpret(resp)) { error in
            guard case UsageBarError.rateLimited(let after) = error else {
                return XCTFail("rateLimited 기대, 실제 \(error)")
            }
            XCTAssertEqual(after, 120)
        }
        XCTAssertThrowsError(try ClaudeProvider.interpret(probeResponse(429, [:]))) { error in
            guard case UsageBarError.rateLimited(let after) = error else { return XCTFail("\(error)") }
            XCTAssertNil(after)
        }
    }

    func test401And403AreTokenInvalid() {
        for code in [401, 403] {
            XCTAssertThrowsError(try ClaudeProvider.interpret(probeResponse(code, [:]))) { error in
                guard case UsageBarError.tokenInvalid(let c) = error else { return XCTFail("\(error)") }
                XCTAssertEqual(c, code)
                XCTAssertTrue(error.localizedDescription.contains("토큰 무효 또는 폐기됨"))
            }
        }
    }

    func testOtherStatusIsHTTPError() {
        XCTAssertThrowsError(try ClaudeProvider.interpret(probeResponse(529, ultraHeaders, body: "overloaded"))) { error in
            guard case UsageBarError.http(let code, let body) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(code, 529)
            XCTAssertEqual(body, "overloaded")
        }
    }

    /// F3: 헤더 없는 200(count_tokens 같은 응답)은 사용률로 쓰지 않는다.
    func test200WithoutUtilizationHeadersIsParseError() {
        XCTAssertThrowsError(try ClaudeProvider.interpret(probeResponse(200, ["content-type": "application/json"]))) { error in
            guard case UsageBarError.parse = error else { return XCTFail("\(error)") }
        }
    }

    func testGarbageUtilizationIgnored() throws {
        var h = ultraHeaders
        h["anthropic-ratelimit-unified-5h-utilization"] = "abc"
        let snap = try ClaudeProvider.interpret(probeResponse(200, h))
        XCTAssertNil(snap.fiveHour)
    }

    // MARK: - Provider glue (recorded transport)

    func testFetchUsageSendsTokenAndParses() async throws {
        let dir = makeTempDir()
        let store = AccountStore(directory: dir)
        let account = Account(provider: .claude, kind: .setupToken, label: "a@example.com")
        try store.add(account, secrets: AccountSecrets(accessToken: "sk-ant-oat01-xyz"))

        var seen: URLRequest?
        var provider = ClaudeProvider()
        provider.transport = { req in
            seen = req
            return probeResponse(200, ultraHeaders)
        }
        let snap = try await provider.fetchUsage(account: account, store: store)
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-ant-oat01-xyz")
        XCTAssertEqual(try XCTUnwrap(snap.sevenDay?.percent), 62, accuracy: 1e-9)
    }

    func testLegacyRowsAreNotFetched() async throws {
        let dir = makeTempDir()
        let store = AccountStore(directory: dir)
        var provider = ClaudeProvider()
        provider.transport = { _ in XCTFail("레거시 행은 네트워크를 타면 안 됨"); return probeResponse(500, [:]) }
        for kind in [CredentialKind.storedToken, .localClaudeCLI] {
            let legacy = Account(provider: .claude, kind: kind, label: "old@example.com")
            do {
                _ = try await provider.fetchUsage(account: legacy, store: store)
                XCTFail("throw 기대")
            } catch UsageBarError.reregistrationRequired {
            } catch { XCTFail("\(error)") }
        }
    }

    // MARK: - Token input

    func testNormalizeToken() {
        XCTAssertEqual(ClaudeProvider.normalizeToken("  sk-ant-oat01-abc\n"), "sk-ant-oat01-abc")
        XCTAssertNil(ClaudeProvider.normalizeToken(""))
        XCTAssertNil(ClaudeProvider.normalizeToken(" \n "))
        XCTAssertNil(ClaudeProvider.normalizeToken("sk-ant abc"))
        XCTAssertNil(ClaudeProvider.normalizeToken("sk-ant-oat01-a\nsecond"))
        XCTAssertNil(ClaudeProvider.normalizeToken("sk-ant-oat01-ä"))
    }

    func testRegistrationDuplicateChecks() throws {
        let dir = makeTempDir()
        let store = AccountStore(directory: dir)
        let a = Account(provider: .claude, kind: .setupToken, label: "a@example.com", organizationId: "org-1")
        let legacy = Account(provider: .claude, kind: .storedToken, label: "a@example.com", organizationId: "org-1")
        try store.add(a, secrets: AccountSecrets(accessToken: "tok-a"))
        try store.add(legacy, secrets: AccountSecrets(accessToken: "tok-legacy"))
        let accounts = store.loadAccounts()
        XCTAssertEqual(ClaudeRegistration.sameOrganization("org-1", in: accounts).map(\.id), [a.id])
        XCTAssertTrue(ClaudeRegistration.sameOrganization("org-2", in: accounts).isEmpty)
        XCTAssertTrue(ClaudeRegistration.sameOrganization(nil, in: accounts).isEmpty)
        XCTAssertEqual(ClaudeRegistration.duplicateToken("tok-a", in: accounts, store: store)?.id, a.id)
        XCTAssertNil(ClaudeRegistration.duplicateToken("tok-legacy", in: accounts, store: store))
    }
}

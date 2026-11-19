import XCTest
@testable import usagebar

/// HTTP 계층: 탐침은 429 헤더를 받고, 다른 제공자의 429 동작은 그대로.
final class HTTPTests: XCTestCase {
    override func setUp() {
        URLProtocol.registerClass(MockURLProtocol.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(MockURLProtocol.self)
        MockURLProtocol.handler = nil
    }

    func testRequestStillThrowsRateLimitedOn429() async {
        MockURLProtocol.handler = { _ in (429, ["Retry-After": "90"], Data()) }
        do {
            _ = try await HTTP.request("https://example.invalid/usage")
            XCTFail("throw 기대")
        } catch UsageBarError.rateLimited(let after) {
            XCTAssertEqual(after, 90)
        } catch {
            XCTFail("\(error)")
        }
    }

    func testRequestReturnsNon429() async throws {
        MockURLProtocol.handler = { _ in (401, [:], Data("nope".utf8)) }
        let (code, data) = try await HTTP.request("https://example.invalid/usage")
        XCTAssertEqual(code, 401)
        XCTAssertEqual(String(data: data, encoding: .utf8), "nope")
    }

    func testResponseKeeps429HeadersCaseInsensitive() async throws {
        MockURLProtocol.handler = { _ in
            (429, ["Anthropic-Ratelimit-Unified-Status": "rejected",
                   "anthropic-ratelimit-unified-7d-utilization": "1.0"], Data())
        }
        let resp = try await HTTP.response(URLRequest(url: URL(string: "https://example.invalid/v1/messages")!))
        XCTAssertEqual(resp.status, 429)
        XCTAssertEqual(resp.header("anthropic-ratelimit-unified-status"), "rejected")
        XCTAssertEqual(resp.header("ANTHROPIC-RATELIMIT-UNIFIED-7D-UTILIZATION"), "1.0")
    }

    /// 실제 URLSession 경로로 탐침 전체: 한도 거절 429 → 스냅샷.
    func testProbeThroughURLSessionOnRejected429() async throws {
        MockURLProtocol.handler = { req in
            XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
            return (429, ["anthropic-ratelimit-unified-status": "rejected",
                          "anthropic-ratelimit-unified-7d-utilization": "1.0",
                          "anthropic-ratelimit-unified-7d-reset": "1795143600"], Data())
        }
        let (snap, _) = try await ClaudeProvider().probe(secrets: AccountSecrets(accessToken: "sk-ant-oat01-t"))
        XCTAssertTrue(snap.isLimitRejected)
        XCTAssertEqual(snap.sevenDay?.percent, 100)
    }

    func testRetryAfterParsing() {
        XCTAssertEqual(HTTP.retryAfter(probeResponse(429, ["retry-after": "30"])), 30)
        XCTAssertEqual(HTTP.retryAfter(probeResponse(429, ["Retry-After": " 15 "])), 15)
        XCTAssertNil(HTTP.retryAfter(probeResponse(429, ["Retry-After": "Wed, 21 Oct 2026 07:28:00 GMT"])))
        XCTAssertNil(HTTP.retryAfter(probeResponse(429, [:])))
    }
}

/// Codex 회귀: 공유 HTTP 계층을 고쳤으므로 파싱·429 경로를 고정한다.
final class CodexRegressionTests: XCTestCase {
    func testWeeklyOnlyPlanSlotsPrimaryAsSevenDay() throws {
        let json = #"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":33,"reset_at":1795143600,"limit_window_seconds":604800},"secondary_window":null}}"#
        let snap = try CodexProvider.parseUsage(Data(json.utf8))
        XCTAssertNil(snap.fiveHour)
        XCTAssertEqual(snap.sevenDay?.percent, 33)
        XCTAssertEqual(snap.details, ["플랜 plus"])
        XCTAssertNil(snap.limitStatus)
    }

    func testFiveHourAndWeekly() throws {
        let json = #"{"rate_limit":{"primary_window":{"used_percent":12,"reset_at":1795000000,"limit_window_seconds":18000},"secondary_window":{"used_percent":40.5,"reset_at":1795143600,"limit_window_seconds":604800}},"credits":{"unlimited":true}}"#
        let snap = try CodexProvider.parseUsage(Data(json.utf8))
        XCTAssertEqual(snap.fiveHour?.percent, 12)
        XCTAssertEqual(snap.sevenDay?.percent, 40.5)
        XCTAssertEqual(snap.details, ["크레딧 무제한"])
    }

    func testCodexFetch429KeepsRateLimitedPath() async {
        URLProtocol.registerClass(MockURLProtocol.self)
        defer { URLProtocol.unregisterClass(MockURLProtocol.self); MockURLProtocol.handler = nil }
        MockURLProtocol.handler = { _ in (429, ["Retry-After": "600"], Data()) }
        do {
            _ = try await CodexProvider().probe(secrets: AccountSecrets(accessToken: "a", accountId: "b"))
            XCTFail("throw 기대")
        } catch UsageBarError.rateLimited(let after) {
            XCTAssertEqual(after, 600)
        } catch {
            XCTFail("\(error)")
        }
    }
}

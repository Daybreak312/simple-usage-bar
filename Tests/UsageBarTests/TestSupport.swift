import Foundation
import XCTest
@testable import usagebar

/// Fresh temp directory per test, removed on teardown.
func makeTempDir(file: StaticString = #filePath, line: UInt = #line) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("usagebar-tests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func posixMode(_ url: URL) -> Int {
    let attrs = try! FileManager.default.attributesOfItem(atPath: url.path)
    return (attrs[.posixPermissions] as! NSNumber).intValue & 0o777
}

/// Recorded probe response (headers as the server sent them).
func probeResponse(_ status: Int, _ headers: [String: String], body: String = "{}") -> HTTPResponse {
    HTTPResponse(status: status, headers: headers, body: Data(body.utf8))
}

/// F1 실측 헤더 (Ultra — 5h 없음).
let ultraHeaders: [String: String] = [
    "anthropic-ratelimit-unified-7d-utilization": "0.62",
    "anthropic-ratelimit-unified-7d-reset": "1795143600",
    "anthropic-ratelimit-unified-7d-status": "allowed",
    "anthropic-ratelimit-unified-status": "allowed",
    "anthropic-ratelimit-unified-reset": "1795143600",
    "anthropic-ratelimit-unified-representative-claim": "seven_day",
    "anthropic-ratelimit-unified-overage-status": "rejected",
    "anthropic-organization-id": "org-aaaa-1111",
]

func claudeAccount(_ label: String, priority: Int? = nil, kind: CredentialKind = .setupToken) -> Account {
    var a = Account(provider: .claude, kind: kind, label: label)
    a.rollPriority = priority
    return a
}

func state(_ account: Account, seven: Double?, five: Double? = nil,
           status: String? = "allowed", error: String? = nil, stale: String? = nil) -> AccountState {
    var s = AccountState(account: account)
    if seven != nil || five != nil || status == "rejected" {
        s.snapshot = UsageSnapshot(
            fiveHour: five.map { WindowUsage(percent: $0, resetsAt: nil) },
            sevenDay: seven.map { WindowUsage(percent: $0, resetsAt: nil) },
            fetchedAt: Date(), limitStatus: status)
    }
    s.lastError = error
    s.staleNote = stale
    return s
}

/// Intercepts URLSession.shared for HTTP layer tests.
final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, [String: String], Data))?
    static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        let (code, headers, data) = Self.handler?(request) ?? (500, [:], Data())
        let resp = HTTPURLResponse(url: request.url!, statusCode: code,
                                   httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

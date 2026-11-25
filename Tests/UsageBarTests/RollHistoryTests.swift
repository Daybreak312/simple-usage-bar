import XCTest
@testable import usagebar

final class RollHistoryTests: XCTestCase {
    let base = Date(timeIntervalSince1970: 1_795_000_000)

    func testLineFormatAndNullFrom() throws {
        let dir = makeTempDir().appendingPathComponent("claude")
        let store = RollHistoryStore(directory: dir, now: { self.base })
        store.record(from: "Old@Example.com (로컬)", to: "New@Example.com", reason: "5h 96%")
        store.record(from: nil, to: "b@example.com", reason: "수동 전환")
        XCTAssertEqual(posixMode(dir), 0o700)
        XCTAssertEqual(posixMode(store.url), 0o600)

        let lines = try fileLines(store.url)
        XCTAssertEqual(lines.count, 2)
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        XCTAssertEqual(Set(first.keys), ["v", "ts", "from", "to", "reason"], "토큰 등 다른 필드 없음")
        XCTAssertEqual((first["v"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual((first["ts"] as? NSNumber)?.int64Value, 1_795_000_000_000)
        XCTAssertEqual(first["from"] as? String, "old@example.com")
        XCTAssertEqual(first["to"] as? String, "new@example.com")
        XCTAssertEqual(first["reason"] as? String, "5h 96%")
        let second = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])
        XCTAssertTrue(second["from"] is NSNull)

        XCTAssertEqual(store.records(), [
            RollRecord(ts: base, from: "old@example.com", to: "new@example.com", reason: "5h 96%"),
            RollRecord(ts: base, from: nil, to: "b@example.com", reason: "수동 전환"),
        ])
    }

    func testUnknownTargetIsNotRecorded() {
        let store = RollHistoryStore(directory: makeTempDir(), now: { self.base })
        store.record(from: "a@example.com", to: "claude", reason: "x")
        XCTAssertEqual(store.records(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
    }

    func testKeyAndRangeFilter() {
        let store = RollHistoryStore(directory: makeTempDir(), now: { self.base.addingTimeInterval(10_000) })
        store.record(from: "a@example.com", to: "b@example.com", reason: "1", at: base)
        store.record(from: "b@example.com", to: "c@example.com", reason: "2", at: base.addingTimeInterval(100))
        store.record(from: "c@example.com", to: "a@example.com", reason: "3", at: base.addingTimeInterval(200))
        XCTAssertEqual(store.records(key: "B@example.com").map(\.reason), ["1", "2"])
        XCTAssertEqual(store.records(key: "a@example.com").map(\.reason), ["1", "3"])
        XCTAssertEqual(store.records(from: base.addingTimeInterval(100)).map(\.reason), ["2", "3"])
        XCTAssertEqual(store.records(to: base.addingTimeInterval(100)).map(\.reason), ["1", "2"])
        XCTAssertEqual(store.records(key: "not-an-email"), [])
    }

    func testRetentionAndMalformedLines() throws {
        let dir = makeTempDir()
        var now = base
        let store = RollHistoryStore(directory: dir, now: { now })
        try Data("garbage\n{\"ts\":1}\n".utf8).write(to: store.url)
        store.record(from: nil, to: "a@example.com", reason: "old")
        XCTAssertEqual(store.records().map(\.reason), ["old"])

        // 400일 뒤: 조회에서 빠지고, 다음 추가 때 파일에서도 지워진다(손상 줄 포함).
        now = base.addingTimeInterval(400 * 86_400 + 1)
        XCTAssertEqual(store.records(), [])
        store.record(from: "a@example.com", to: "b@example.com", reason: "new")
        XCTAssertEqual(store.records().map(\.reason), ["new"])
        XCTAssertEqual(try fileLines(store.url).count, 1)
        XCTAssertEqual(posixMode(store.url), 0o600)
    }
}

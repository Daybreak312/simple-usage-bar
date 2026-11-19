import XCTest
@testable import usagebar

final class UsageHistoryTests: XCTestCase {
    let a = UUID()
    let b = UUID()
    /// 3분 버킷 경계에 맞춘 기준 시각.
    let base = Date(timeIntervalSince1970: 1_794_999_960)  // 180의 배수

    func sample(_ id: UUID, _ offset: TimeInterval, _ seven: Double, status: String = "allowed") -> UsageSample {
        UsageSample(accountId: id, ts: base.addingTimeInterval(offset), sevenDay: seven, fiveHour: nil, status: status)
    }

    func testSameBucketMergesLatestWins() {
        var series: [UsageSample] = []
        UsageHistoryStore.insert(sample(a, 0, 10), into: &series)
        UsageHistoryStore.insert(sample(a, 60, 11), into: &series)
        UsageHistoryStore.insert(sample(a, 179, 12), into: &series)
        XCTAssertEqual(series.map(\.sevenDay), [12])
        XCTAssertEqual(series.first?.ts, base.addingTimeInterval(179))
        UsageHistoryStore.insert(sample(a, 180, 13), into: &series)
        XCTAssertEqual(series.map(\.sevenDay), [12, 13])
    }

    /// 3분 폴링(≥180초 간격)은 절대 합쳐지지 않는다.
    func testPollCadenceKeepsEveryPoint() {
        var series: [UsageSample] = []
        for i in 0..<10 { UsageHistoryStore.insert(sample(a, Double(i) * 185 + 7, Double(i)), into: &series) }
        XCTAssertEqual(series.count, 10)
    }

    /// 연속 이벤트(10초 간격)도 3분당 최대 1점 — 흐르는 한 점으로 뭉개지지 않는다.
    func testEventStreamKeepsOnePointPerBucket() {
        var series: [UsageSample] = []
        for i in 0..<108 { UsageHistoryStore.insert(sample(a, Double(i) * 10, Double(i)), into: &series) }  // 18분
        XCTAssertEqual(series.count, 6)
        XCTAssertEqual(series.map(\.sevenDay), [17, 35, 53, 71, 89, 107])
    }

    func testOutOfOrderIsOrderIndependent() {
        let input = [sample(a, 400, 3), sample(a, 0, 1), sample(a, 200, 2), sample(a, 30, 0.5), sample(a, 190, 1.9)]
        var forward: [UsageSample] = []
        input.forEach { UsageHistoryStore.insert($0, into: &forward) }
        var backward: [UsageSample] = []
        input.reversed().forEach { UsageHistoryStore.insert($0, into: &backward) }
        XCTAssertEqual(forward, backward)
        XCTAssertEqual(forward.map(\.sevenDay), [0.5, 2, 3])
        XCTAssertEqual(forward.map(\.ts), forward.map(\.ts).sorted())
    }

    func testAccountsDoNotMerge() {
        let merged = UsageHistoryStore.merge([sample(a, 0, 1), sample(b, 10, 2)], cutoff: .distantPast)
        XCTAssertEqual(merged[a]?.count, 1)
        XCTAssertEqual(merged[b]?.count, 1)
    }

    func testPersistReloadAndRetention() throws {
        let dir = makeTempDir().appendingPathComponent("claude")
        var now = base.addingTimeInterval(1_000)
        let store = UsageHistoryStore(directory: dir, now: { now })
        store.record(sample(a, 0, 10))
        store.record(sample(a, 30, 11))       // 같은 버킷 → 병합
        store.record(sample(a, 500, 20, status: "rejected"))
        store.record(sample(b, 0, 5))
        XCTAssertEqual(store.samples(for: a).map(\.sevenDay), [11, 20])
        XCTAssertEqual(posixMode(dir), 0o700)
        XCTAssertEqual(posixMode(store.url), 0o600)

        // 새 프로세스가 읽어도 같은 결과 + 로드 시 압축(중복 줄 제거).
        let reloaded = UsageHistoryStore(directory: dir, now: { now })
        XCTAssertEqual(reloaded.samples(for: a).map(\.sevenDay), [11, 20])
        XCTAssertEqual(reloaded.samples(for: a).last?.status, "rejected")
        XCTAssertEqual(reloaded.samples(for: b).count, 1)
        let lines = try String(contentsOf: store.url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 3)

        // 90일 경과: 조회에서 빠지고, 다음 로드에서 파일에서도 지워진다.
        now = base.addingTimeInterval(90 * 86_400 + 100)
        let later = UsageHistoryStore(directory: dir, now: { now })
        XCTAssertEqual(later.samples(for: a).map(\.sevenDay), [20])
        XCTAssertEqual(later.samples(for: b).count, 0)
        let after = try String(contentsOf: store.url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(after.count, 1)
    }

    func testSinceFilterAndMalformedLines() throws {
        let dir = makeTempDir()
        let url = dir.appendingPathComponent("usage-history.jsonl")
        let good = sample(a, 0, 1).jsonLine() + sample(a, 400, 2).jsonLine()
        try (Data("garbage\n{\"ts\":\"x\"}\n".utf8) + good).write(to: url)
        let store = UsageHistoryStore(directory: dir, now: { self.base.addingTimeInterval(1_000) })
        XCTAssertEqual(store.samples(for: a).map(\.sevenDay), [1, 2])
        XCTAssertEqual(store.samples(for: a, since: base.addingTimeInterval(100)).map(\.sevenDay), [2])
        // 깨진 줄은 압축 때 정리된다.
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8).split(separator: "\n").count, 2)
    }

    func testJSONLineRoundTrip() throws {
        let s = UsageSample(accountId: a, ts: Date(timeIntervalSince1970: 1_795_000_000.123),
                            sevenDay: 62, fiveHour: nil, status: nil)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: s.jsonLine()) as? [String: Any])
        XCTAssertEqual((obj["ts"] as? NSNumber)?.int64Value, 1_795_000_000_123)
        XCTAssertTrue(obj["fiveHour"] is NSNull)
        let back = try XCTUnwrap(UsageSample(json: obj))
        XCTAssertEqual(back.accountId, a)
        XCTAssertEqual(back.sevenDay, 62)
        XCTAssertNil(back.fiveHour)
        XCTAssertNil(back.status)
        XCTAssertEqual(back.ts.timeIntervalSince1970, 1_795_000_000.123, accuracy: 0.001)
    }
}

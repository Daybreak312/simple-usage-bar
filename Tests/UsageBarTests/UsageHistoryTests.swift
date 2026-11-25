import XCTest
@testable import usagebar

final class UsageHistoryTests: XCTestCase {
    let a = "a@example.com"
    let b = "b@example.com"
    /// 3분 버킷 경계에 맞춘 기준 시각.
    let base = Date(timeIntervalSince1970: 1_794_999_960)  // 180의 배수

    func sample(_ key: String, _ offset: TimeInterval, _ seven: Double, five: Double? = nil) -> UsageSample {
        UsageSample(key: key, ts: base.addingTimeInterval(offset), fiveHour: five, sevenDay: seven)
    }

    // MARK: - 계정 키

    func testKeyNormalization() {
        XCTAssertEqual(AccountKey.normalize("Foo@Example.COM"), "foo@example.com")
        XCTAssertEqual(AccountKey.normalize("  Foo@Example.com (로컬) "), "foo@example.com")
        XCTAssertEqual(AccountKey.normalize("foo@example.com(로컬)"), "foo@example.com")
        XCTAssertNil(AccountKey.normalize(nil))
        XCTAssertNil(AccountKey.normalize(""))
        XCTAssertNil(AccountKey.normalize(" (로컬)"))
        XCTAssertNil(AccountKey.normalize("claude"), "이메일이 아닌 라벨은 키가 아님")
        XCTAssertNil(AccountKey.normalize("a b@example.com"))
    }

    // MARK: - 폴링 결과 → 표본

    func testStoredRowSuccessUsesRowEmail() throws {
        let account = Account(provider: .claude, kind: .storedToken, label: "Perry@Example.com")
        let s = try XCTUnwrap(UsageSample(
            account: account, result: .success(snapshot(five: 12, seven: 34, at: base))))
        XCTAssertEqual(s, UsageSample(key: "perry@example.com", ts: base, fiveHour: 12, sevenDay: 34))
    }

    /// 로컬 행은 저장 라벨(이전 로그인일 수 있음)이 아니라 그 조회에서 해석된 이메일.
    func testLocalRowUsesResolvedEmail() throws {
        let account = Account(provider: .claude, kind: .localClaudeCLI, label: "old@example.com (로컬)")
        let s = try XCTUnwrap(UsageSample(
            account: account,
            result: .success(snapshot(seven: 50, at: base, resolved: "New@Example.com (로컬)"))))
        XCTAssertEqual(s.key, "new@example.com")
        XCTAssertNil(s.fiveHour)
        XCTAssertEqual(s.sevenDay, 50)
    }

    func testLocalRowWithoutResolvedEmailIsSkipped() {
        let account = Account(provider: .claude, kind: .localClaudeCLI, label: "old@example.com (로컬)")
        XCTAssertNil(UsageSample(account: account, result: .success(snapshot(seven: 50, at: base))))
    }

    func testFailedFetchIsNotASample() {
        let account = Account(provider: .claude, kind: .storedToken, label: "a@example.com")
        XCTAssertNil(UsageSample(account: account,
                                 result: .failure(UsageBarError.rateLimited(retryAfter: 60))))
        XCTAssertNil(UsageSample(account: account, result: .failure(UsageBarError.tokenExpired)))
    }

    func testCodexIsNotRecorded() {
        let account = Account(provider: .codex, kind: .storedToken, label: "a@example.com")
        XCTAssertNil(UsageSample(account: account, result: .success(snapshot(five: 1, seven: 2, at: base))))
    }

    /// 같은 사람의 저장 행·로컬 행은 한 이력으로 합쳐진다.
    func testStoredAndLocalRowsShareOneSeries() throws {
        let dir = makeTempDir()
        let store = UsageHistoryStore(directory: dir, now: { self.base.addingTimeInterval(3_600) })
        let stored = Account(provider: .claude, kind: .storedToken, label: "A@example.com")
        let local = Account(provider: .claude, kind: .localClaudeCLI, label: "x@example.com (로컬)")
        store.record(try XCTUnwrap(UsageSample(account: stored, result: .success(snapshot(seven: 10, at: base)))))
        store.record(try XCTUnwrap(UsageSample(
            account: local,
            result: .success(snapshot(seven: 20, at: base.addingTimeInterval(400), resolved: "a@EXAMPLE.com (로컬)")))))
        XCTAssertEqual(store.samples(key: "A@Example.com").map(\.sevenDay), [10, 20])
        XCTAssertEqual(store.keys(), ["a@example.com"])
    }

    // MARK: - 3분 병합

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

    // MARK: - 저장

    func testPersistReloadAndRetention() throws {
        let dir = makeTempDir().appendingPathComponent("claude")
        var now = base.addingTimeInterval(1_000)
        let store = UsageHistoryStore(directory: dir, now: { now })
        store.record(sample(a, 0, 10, five: 1))
        store.record(sample(a, 30, 11, five: 2))       // 같은 버킷 → 병합
        store.record(sample(a, 500, 20))
        store.record(sample(b, 0, 5))
        XCTAssertEqual(store.samples(key: a).map(\.sevenDay), [11, 20])
        XCTAssertEqual(posixMode(dir), 0o700)
        XCTAssertEqual(posixMode(store.url), 0o600)

        // 새 프로세스가 읽어도 같은 결과 + 로드 시 정리(중복 줄 제거).
        let reloaded = UsageHistoryStore(directory: dir, now: { now })
        XCTAssertEqual(reloaded.samples(key: a).map(\.sevenDay), [11, 20])
        XCTAssertEqual(reloaded.samples(key: a).first?.fiveHour, 2)
        XCTAssertNil(reloaded.samples(key: a).last?.fiveHour)
        XCTAssertEqual(reloaded.samples(key: b).count, 1)
        XCTAssertEqual(try fileLines(store.url).count, 3)
        XCTAssertEqual(posixMode(store.url), 0o600)

        // 400일 경과: 조회에서 빠지고, 다음 로드에서 파일에서도 지워진다.
        now = base.addingTimeInterval(400 * 86_400 + 100)
        let later = UsageHistoryStore(directory: dir, now: { now })
        XCTAssertEqual(later.samples(key: a).map(\.sevenDay), [20])
        XCTAssertEqual(later.samples(key: b).count, 0)
        XCTAssertEqual(later.keys(), [a])
        XCTAssertEqual(try fileLines(store.url).count, 1)
    }

    /// 앱이 재시작 없이 오래 떠 있어도 하루 1회 점검에서 만료 표본이 지워진다.
    func testLongRunningProcessPrunesDaily() throws {
        let dir = makeTempDir()
        var now = base.addingTimeInterval(10)
        let store = UsageHistoryStore(directory: dir, now: { now })
        store.record(sample(a, 0, 1))
        XCTAssertEqual(store.samples(key: a).count, 1)
        now = base.addingTimeInterval(400 * 86_400 + 600)
        store.record(UsageSample(key: a, ts: now, fiveHour: nil, sevenDay: 2))
        XCTAssertEqual(store.samples(key: a).map(\.sevenDay), [2])
        XCTAssertEqual(try fileLines(store.url).count, 1)
    }

    /// 원시 줄이 병합 결과보다 충분히 많아지면 재작성한다.
    func testSlackCompaction() throws {
        let dir = makeTempDir()
        let store = UsageHistoryStore(directory: dir, now: { self.base.addingTimeInterval(170) })
        for i in 0...(UsageHistoryStore.compactionSlack + 1) {  // 1 + 2000을 넘는 2002줄
            store.record(sample(a, Double(i % 170), Double(i)))
        }
        XCTAssertEqual(store.samples(key: a).count, 1)
        XCTAssertEqual(try fileLines(store.url).count, 1)
    }

    func testRangeFilterAndMalformedLines() throws {
        let dir = makeTempDir()
        let url = dir.appendingPathComponent("usage-history.jsonl")
        let good = sample(a, 0, 1).jsonLine() + sample(a, 400, 2).jsonLine() + sample(a, 800, 3).jsonLine()
        let broken = "garbage\n{\"ts\":\"x\",\"key\":\"a@example.com\"}\n{\"ts\":1,\"key\":\"noemail\"}\n"
        try (Data(broken.utf8) + good + Data("{\"v\":1,".utf8)).write(to: url)
        let store = UsageHistoryStore(directory: dir, now: { self.base.addingTimeInterval(1_000) })
        XCTAssertEqual(store.samples(key: a).map(\.sevenDay), [1, 2, 3])
        XCTAssertEqual(store.samples(key: a, from: base.addingTimeInterval(100)).map(\.sevenDay), [2, 3])
        XCTAssertEqual(store.samples(key: a, to: base.addingTimeInterval(400)).map(\.sevenDay), [1, 2])
        XCTAssertEqual(store.samples(key: a, from: base.addingTimeInterval(400),
                                     to: base.addingTimeInterval(400)).map(\.sevenDay), [2])
        XCTAssertEqual(store.samples(key: "nobody@example.com"), [])
        XCTAssertEqual(store.samples(key: "not-an-email"), [])
        // 깨진 줄은 로드 시 정리된다.
        XCTAssertEqual(try fileLines(url).count, 3)
    }

    func testJSONLineFormat() throws {
        let s = UsageSample(key: a, ts: Date(timeIntervalSince1970: 1_795_000_000.123),
                            fiveHour: nil, sevenDay: 62)
        let line = s.jsonLine()
        XCTAssertEqual(line.last, 0x0A)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
        XCTAssertEqual(Set(obj.keys), ["v", "ts", "key", "fiveHour", "sevenDay"])
        XCTAssertEqual((obj["v"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual((obj["ts"] as? NSNumber)?.int64Value, 1_795_000_000_123)
        XCTAssertEqual(obj["key"] as? String, a)
        XCTAssertTrue(obj["fiveHour"] is NSNull)
        let back = try XCTUnwrap(UsageSample(json: obj))
        XCTAssertEqual(back.key, a)
        XCTAssertEqual(back.sevenDay, 62)
        XCTAssertNil(back.fiveHour)
        XCTAssertEqual(back.ts.timeIntervalSince1970, 1_795_000_000.123, accuracy: 0.001)
    }
}

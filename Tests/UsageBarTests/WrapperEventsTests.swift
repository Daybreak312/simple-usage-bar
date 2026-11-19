import XCTest
@testable import usagebar

private func eventLine(_ obj: [String: Any]) -> Data {
    var d = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    d.append(0x0A)
    return d
}

private func rateLimitObj(ts: Int64, account: UUID? = nil, hash: String? = nil,
                          status: String = "allowed", seven: Double? = 0.62) -> [String: Any] {
    var windows: [String: Any] = [:]
    if let seven { windows["seven_day"] = ["utilization": seven, "resetsAt": 1_795_143_600] }
    return [
        "v": 1, "ts": ts, "type": "rate_limit", "launchId": "L",
        "accountId": account?.uuidString ?? NSNull(), "tokenHash": hash ?? NSNull(),
        "status": status, "rateLimitType": "seven_day", "overageStatus": "rejected",
        "resetsAt": 1_795_143_600, "windows": windows,
    ]
}

final class WrapperEventRulesTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_795_000_000)

    func testDecodeObserverLines() throws {
        let id = UUID()
        let rl = try XCTUnwrap(WrapperEvent(json: rateLimitObj(ts: 1_795_000_000_500, account: id, hash: "abcd")))
        XCTAssertEqual(rl.ts, Date(timeIntervalSince1970: 1_795_000_000.5))
        XCTAssertEqual(rl.accountId, id)
        XCTAssertEqual(rl.tokenHash, "abcd")
        guard case .rateLimit(let status, let type, let overage, let five, let seven) = rl.kind else {
            return XCTFail("rate_limit 기대")
        }
        XCTAssertEqual(status, "allowed")
        XCTAssertEqual(type, "seven_day")
        XCTAssertEqual(overage, "rejected")
        XCTAssertNil(five)
        XCTAssertEqual(seven?.percent ?? 0, 62, accuracy: 1e-9)
        XCTAssertEqual(seven?.resetsAt, Date(timeIntervalSince1970: 1_795_143_600))
        XCTAssertFalse(rl.isLimitRefusal)

        let lt = try XCTUnwrap(WrapperEvent(json: ["ts": 1, "type": "limit_text", "match": "hit your limit", "accountId": NSNull()]))
        XCTAssertEqual(lt.kind, .limitText(match: "hit your limit"))
        XCTAssertTrue(lt.isLimitRefusal)

        // session/result는 앱이 소비하지 않는다. ts 없는 줄은 버린다.
        XCTAssertNil(WrapperEvent(json: ["ts": 1, "type": "session", "sessionId": "s"]))
        XCTAssertNil(WrapperEvent(json: ["ts": 1, "type": "result"]))
        XCTAssertNil(WrapperEvent(json: ["type": "rate_limit"]))
    }

    func testApplyRefreshesOnlyWhenNewer() {
        let old = UsageSnapshot(
            fiveHour: nil, sevenDay: WindowUsage(percent: 40, resetsAt: nil),
            details: ["정상"], fetchedAt: t0, limitStatus: "allowed", organizationId: "org-1")
        let newer = WrapperEvent(ts: t0.addingTimeInterval(30), accountId: nil, tokenHash: nil, kind: .rateLimit(
            status: "allowed_warning", rateLimitType: "seven_day", overageStatus: "rejected",
            fiveHour: nil, sevenDay: WindowUsage(percent: 81, resetsAt: nil)))
        let snap = WrapperEventRules.apply(newer, to: old)
        XCTAssertEqual(snap?.sevenDay?.percent, 81)
        XCTAssertEqual(snap?.limitStatus, "allowed_warning")
        XCTAssertEqual(snap?.fetchedAt, newer.ts)
        XCTAssertEqual(snap?.organizationId, "org-1", "탐침에서 얻은 조직 id 유지")
        XCTAssertEqual(snap?.details, ["경고 구간", "기준 7d", "초과 사용 불가"])

        var older = newer
        older.ts = t0.addingTimeInterval(-1)
        XCTAssertNil(WrapperEventRules.apply(older, to: old), "탐침보다 오래된 이벤트는 무시")
        older.ts = t0
        XCTAssertNil(WrapperEventRules.apply(older, to: old))
    }

    func testApplyKeepsMissingWindowsAndBuildsFromNothing() {
        let old = UsageSnapshot(fiveHour: WindowUsage(percent: 10, resetsAt: nil),
                                sevenDay: WindowUsage(percent: 40, resetsAt: nil), fetchedAt: t0)
        let statusOnly = WrapperEvent(ts: t0.addingTimeInterval(5), accountId: nil, tokenHash: nil,
                                      kind: .rateLimit(status: "rejected", rateLimitType: nil, overageStatus: nil,
                                                       fiveHour: nil, sevenDay: nil))
        let s = WrapperEventRules.apply(statusOnly, to: old)
        XCTAssertEqual(s?.fiveHour?.percent, 10)
        XCTAssertEqual(s?.sevenDay?.percent, 40)
        XCTAssertEqual(s?.isLimitRejected, true)

        // 스냅샷 없음: 창 값이 있으면 새로 만든다, 아무것도 없으면 nil.
        let fresh = WrapperEvent(ts: t0, accountId: nil, tokenHash: nil, kind: .rateLimit(
            status: "allowed", rateLimitType: nil, overageStatus: nil,
            fiveHour: nil, sevenDay: WindowUsage(percent: 5, resetsAt: nil)))
        XCTAssertEqual(WrapperEventRules.apply(fresh, to: nil)?.sevenDay?.percent, 5)
        let empty = WrapperEvent(ts: t0, accountId: nil, tokenHash: nil, kind: .rateLimit(
            status: "allowed", rateLimitType: nil, overageStatus: nil, fiveHour: nil, sevenDay: nil))
        XCTAssertNil(WrapperEventRules.apply(empty, to: nil))
    }

    func testLimitTextMarksRejected() {
        let old = UsageSnapshot(sevenDay: WindowUsage(percent: 70, resetsAt: nil), fetchedAt: t0, limitStatus: "allowed")
        let e = WrapperEvent(ts: t0.addingTimeInterval(1), accountId: nil, tokenHash: nil, kind: .limitText(match: "x"))
        let s = WrapperEventRules.apply(e, to: old)
        XCTAssertEqual(s?.isLimitRejected, true)
        XCTAssertEqual(s?.sevenDay?.percent, 70)
        XCTAssertEqual(RollingPolicy.trip(s), 100)
        XCTAssertNil(WrapperEventRules.apply(e, to: nil))
    }

    func testResolveByAccountIdThenTokenHash() {
        let a = claudeAccount("a"), b = claudeAccount("b")
        let legacy = claudeAccount("legacy", kind: .storedToken)
        let accounts = [a, b, legacy]
        let hashes = ["hash-b": b.id]
        func ev(_ id: UUID?, _ hash: String?) -> WrapperEvent {
            WrapperEvent(ts: t0, accountId: id, tokenHash: hash, kind: .limitText(match: ""))
        }
        XCTAssertEqual(WrapperEventRules.resolve(ev(a.id, "hash-b"), accounts: accounts, hashes: hashes), a.id)
        XCTAssertEqual(WrapperEventRules.resolve(ev(nil, "hash-b"), accounts: accounts, hashes: hashes), b.id)
        XCTAssertEqual(WrapperEventRules.resolve(ev(UUID(), "hash-b"), accounts: accounts, hashes: hashes), b.id,
                       "삭제된 계정 id → 해시로")
        XCTAssertNil(WrapperEventRules.resolve(ev(legacy.id, nil), accounts: accounts, hashes: hashes))
        XCTAssertNil(WrapperEventRules.resolve(ev(nil, "unknown"), accounts: accounts, hashes: hashes))
    }

    func testImmediateTriggerOnlyForFreshRefusalOfActive() {
        let active = UUID(), other = UUID()
        let now = t0.addingTimeInterval(60)
        let rejected = WrapperEvent(ts: t0, accountId: active, tokenHash: nil, kind: .rateLimit(
            status: "rejected", rateLimitType: nil, overageStatus: nil, fiveHour: nil, sevenDay: nil))
        XCTAssertTrue(WrapperEventRules.triggersImmediateRoll(rejected, accountId: active, activeId: active, now: now))
        XCTAssertFalse(WrapperEventRules.triggersImmediateRoll(rejected, accountId: other, activeId: active, now: now))
        XCTAssertFalse(WrapperEventRules.triggersImmediateRoll(
            rejected, accountId: active, activeId: active, now: t0.addingTimeInterval(11 * 60)), "오래된 이벤트")
        var allowed = rejected
        allowed.kind = .rateLimit(status: "allowed", rateLimitType: nil, overageStatus: nil, fiveHour: nil, sevenDay: nil)
        XCTAssertFalse(WrapperEventRules.triggersImmediateRoll(allowed, accountId: active, activeId: active, now: now))
        var text = rejected
        text.kind = .limitText(match: "usage limit reached")
        XCTAssertTrue(WrapperEventRules.triggersImmediateRoll(text, accountId: active, activeId: active, now: now))
    }

    func testTokenHashMatchesWrapper() {
        // `printf %s tok | openssl dgst -sha256` = 1a7674eb4ee78df7…
        XCTAssertEqual(ClaudeProvider.tokenHash("tok"), "1a7674eb4ee78df7")
    }

    func testDecideImmediateIgnoresThresholdAndLongCooldown() {
        let a = claudeAccount("a"), b = claudeAccount("b", priority: 2), c = claudeAccount("c")
        let states = [state(a, seven: 30), state(b, seven: 10), state(c, seven: 96)]
        func decide(last: Date?, auto: Bool = true, activeId: UUID? = nil) -> RollingPolicy.Decision {
            RollingPolicy.decideImmediate(states: states, activeId: activeId ?? a.id, autoRoll: auto,
                                          lastRollAt: last, now: t0, reason: "한도 거절")
        }
        // 임계 미만(30%)이어도 교체, 10분 쿨다운 안(2분 전)이어도 교체.
        XCTAssertEqual(decide(last: nil), .roll(from: a.id, to: b.id, reason: "한도 거절"))
        XCTAssertEqual(decide(last: t0.addingTimeInterval(-120)), .roll(from: a.id, to: b.id, reason: "한도 거절"))
        // 60초 가드.
        XCTAssertEqual(decide(last: t0.addingTimeInterval(-59)), .cooldown)
        XCTAssertEqual(decide(last: nil, auto: false), .disabled)
        XCTAssertEqual(decide(last: nil, activeId: UUID()), .idle)
        // 후보 없음 (b·c 모두 부적격).
        let none = RollingPolicy.decideImmediate(
            states: [state(a, seven: 30), state(c, seven: 96)], activeId: a.id, autoRoll: true,
            lastRollAt: nil, now: t0, reason: "한도 거절")
        XCTAssertEqual(none, .exhausted(reason: "한도 거절"))
    }
}

@MainActor
final class ImmediateRollEngineTests: XCTestCase {
    var notifications: [String] = []
    var savedNotify: ((String, String) -> Void)!
    var savedBroadcast: ((String, [AccountState]) async -> Void)!

    override func setUp() async throws {
        RollingEngine.resetState()
        savedNotify = RollingEngine.notify
        savedBroadcast = RollingEngine.broadcast
        RollingEngine.notify = { [weak self] title, _ in self?.notifications.append(title) }
        RollingEngine.broadcast = { _, _ in }
    }

    override func tearDown() async throws {
        RollingEngine.notify = savedNotify
        RollingEngine.broadcast = savedBroadcast
        RollingEngine.resetState()
    }

    func testImmediateRollSwapsActiveFileWithGuard() async throws {
        let dir = makeTempDir()
        let store = AccountStore(directory: dir)
        let active = ActiveAccountStore(directory: dir.appendingPathComponent("claude"))
        let a = Account(provider: .claude, kind: .setupToken, label: "a@example.com")
        let b = Account(provider: .claude, kind: .setupToken, label: "b@example.com")
        try store.add(a, secrets: AccountSecrets(accessToken: "tok-a"))
        try store.add(b, secrets: AccountSecrets(accessToken: "tok-b"))
        try active.write(accountId: a.id, token: "tok-a")
        let now = Date()
        let states = [state(a, seven: 40, status: "rejected"), state(b, seven: 10)]
        let rolled = await RollingEngine.evaluateImmediate(
            states: states, store: store, reason: "한도 거절 — 실행 중 claude 관측",
            active: active, autoRoll: true, now: now)
        XCTAssertTrue(rolled)
        XCTAssertEqual(active.read(), .init(accountId: b.id, token: "tok-b"))
        XCTAssertEqual(active.loadHistory().last?.reason, "한도 거절 — 실행 중 claude 관측")
        XCTAssertEqual(notifications.count, 1)

        // 30초 뒤 새 계정도 거절 → 60초 가드로 보류.
        let again = await RollingEngine.evaluateImmediate(
            states: [state(a, seven: 40), state(b, seven: 10, status: "rejected")], store: store,
            reason: "한도 거절", active: active, autoRoll: true, now: now.addingTimeInterval(30))
        XCTAssertFalse(again)
        XCTAssertEqual(active.read()?.accountId, b.id)
        // 61초 뒤에는 교체 (10분 쿨다운 무시).
        let later = await RollingEngine.evaluateImmediate(
            states: [state(a, seven: 40), state(b, seven: 10, status: "rejected")], store: store,
            reason: "한도 거절", active: active, autoRoll: true, now: now.addingTimeInterval(61))
        XCTAssertTrue(later)
        XCTAssertEqual(active.read()?.accountId, a.id)
    }
}

final class ClaudeEventFeedTests: XCTestCase {
    func testIncrementalReadsCompleteLinesOnlyAndPersistsCursor() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let feed = ClaudeEventFeed(directory: dir)
        XCTAssertEqual(feed.readNew(), [], "파일 없음")

        let id = UUID()
        try JSONLines.append(eventLine(rateLimitObj(ts: 1000, account: id)), to: feed.url)
        try JSONLines.append(eventLine(["v": 1, "ts": 1001, "type": "session", "sessionId": "s"]), to: feed.url)
        // 쓰는 중인 줄(개행 없음)은 다음에.
        var partial = eventLine(["v": 1, "ts": 1002, "type": "limit_text", "match": "m"])
        let tail = partial.suffix(5)
        partial.removeLast(5)
        try JSONLines.append(partial, to: feed.url)

        let first = feed.readNew()
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.first?.accountId, id)
        XCTAssertEqual(feed.readNew(), [], "이미 읽은 줄은 다시 안 나옴")

        try JSONLines.append(Data(tail), to: feed.url)
        XCTAssertEqual(feed.readNew().map(\.kind), [.limitText(match: "m")])

        // 커서는 재시작(새 인스턴스) 뒤에도 유지.
        try JSONLines.append(eventLine(rateLimitObj(ts: 2000)), to: feed.url)
        let restarted = ClaudeEventFeed(directory: dir)
        XCTAssertEqual(restarted.readNew().map(\.ts), [Date(timeIntervalSince1970: 2)])

        // 다른 파일로 교체(inode 변경) → 처음부터.
        let replacement = dir.appendingPathComponent("new.jsonl")
        try eventLine(rateLimitObj(ts: 3000)).write(to: replacement)
        XCTAssertEqual(rename(replacement.path, restarted.url.path), 0)
        XCTAssertEqual(restarted.readNew().map(\.ts), [Date(timeIntervalSince1970: 3)])
    }

    func testMaintainDrainsRotatedFileThenReadsFreshOne() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let feed = ClaudeEventFeed(directory: dir)
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        let ms = { (d: Date) in Int64(d.timeIntervalSince1970 * 1000) }
        try JSONLines.append(eventLine(rateLimitObj(ts: ms(now.addingTimeInterval(-8 * 86_400)))), to: feed.url)
        XCTAssertEqual(feed.readNew().count, 1)
        // 마지막 읽기 뒤에 붙은 줄은 회전 중에 흘려 보낸다(drain).
        try JSONLines.append(eventLine(rateLimitObj(ts: ms(now.addingTimeInterval(-60)))), to: feed.url)
        let drained = feed.maintain(now: now, settle: 0)
        XCTAssertEqual(drained.map(\.ts), [Date(timeIntervalSince1970: TimeInterval(ms(now.addingTimeInterval(-60))) / 1000)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: feed.url.path), "다음 append가 새로 만든다")
        let archive = JSONLinesRotation.archiveURL(for: feed.url)
        XCTAssertEqual(JSONLines.objects(at: archive).count, 2)

        try JSONLines.append(eventLine(rateLimitObj(ts: ms(now))), to: feed.url)
        XCTAssertEqual(feed.readNew().count, 1, "새 파일은 0부터")
    }
}

final class JSONLinesRotationTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_795_000_000)
    func ms(_ daysAgo: Double) -> Int64 { Int64(now.addingTimeInterval(-daysAgo * 86_400).timeIntervalSince1970 * 1000) }

    func testNoRotationWhileYoung() throws {
        let dir = makeTempDir()
        let url = dir.appendingPathComponent("launches.jsonl")
        try JSONLines.append(eventLine(["ts": ms(6)]), to: url)
        JSONLinesRotation.maintain(url, now: now, settle: 0)
        XCTAssertEqual(JSONLines.objects(at: url).count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: JSONLinesRotation.archiveURL(for: url).path))
    }

    func testRotateMergeAndNinetyDayRetention() throws {
        let dir = makeTempDir()
        let url = dir.appendingPathComponent("launches.jsonl")
        let archive = JSONLinesRotation.archiveURL(for: url)
        XCTAssertEqual(archive.lastPathComponent, "launches.1.jsonl")
        // 보관본: 100일 전(지울 것) + 80일 전(남길 것).
        var old = eventLine(["ts": ms(100), "n": 1])
        old.append(eventLine(["ts": ms(80), "n": 2]))
        try old.write(to: archive)
        // 라이브: 8일 전(회전 대상) + 깨진 줄 + 1일 전.
        try JSONLines.append(eventLine(["ts": ms(8), "n": 3]), to: url)
        try JSONLines.append(Data("garbage\n".utf8), to: url)
        try JSONLines.append(eventLine(["ts": ms(1), "n": 4]), to: url)

        var drained: URL?
        JSONLinesRotation.maintain(url, now: now, settle: 0) { drained = $0 }
        XCTAssertEqual(drained?.lastPathComponent, "launches.rotating.jsonl")
        XCTAssertEqual(JSONLines.objects(at: archive).compactMap { $0["n"] as? Int }, [2, 3, 4])
        XCTAssertEqual(posixMode(archive), 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: JSONLinesRotation.rotatingURL(for: url).path))

        // 이후 보관본만 90일 기준으로 다듬는다 (10일 뒤: 80일 전 줄 → 90일 초과).
        try JSONLines.append(eventLine(["ts": ms(-10), "n": 5]), to: url)  // 10일 뒤 기록
        JSONLinesRotation.maintain(url, now: now.addingTimeInterval(10.5 * 86_400), settle: 0)
        XCTAssertEqual(JSONLines.objects(at: archive).compactMap { $0["n"] as? Int }, [3, 4])
        XCTAssertEqual(JSONLines.objects(at: url).count, 1, "라이브 파일은 아직 일주일 전 → 그대로")
    }

    func testLeftoverRotatingFileIsMergedFirst() throws {
        let dir = makeTempDir()
        let url = dir.appendingPathComponent("events.jsonl")
        let rotating = JSONLinesRotation.rotatingURL(for: url)
        try eventLine(["ts": ms(3), "n": 1]).write(to: rotating)  // 이전 실행이 회전 중 종료
        try JSONLines.append(eventLine(["ts": ms(0), "n": 2]), to: url)
        JSONLinesRotation.maintain(url, now: now, settle: 0)
        XCTAssertEqual(JSONLines.objects(at: JSONLinesRotation.archiveURL(for: url)).compactMap { $0["n"] as? Int }, [1])
        XCTAssertEqual(JSONLines.objects(at: url).compactMap { $0["n"] as? Int }, [2])
        XCTAssertFalse(FileManager.default.fileExists(atPath: rotating.path))
    }
}

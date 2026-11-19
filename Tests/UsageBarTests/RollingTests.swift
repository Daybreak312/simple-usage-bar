import XCTest
@testable import usagebar

final class RollingPolicyTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_795_000_000)

    func testTripIsMaxOfAvailableWindows() {
        XCTAssertNil(RollingPolicy.trip(nil))
        XCTAssertEqual(RollingPolicy.trip(state(claudeAccount("a"), seven: 62).snapshot), 62)
        XCTAssertEqual(RollingPolicy.trip(state(claudeAccount("a"), seven: 62, five: 97).snapshot), 97)
        XCTAssertEqual(RollingPolicy.tripName(state(claudeAccount("a"), seven: 96.4).snapshot), "7d 96%")
        XCTAssertEqual(RollingPolicy.tripName(state(claudeAccount("a"), seven: 10, five: 50).snapshot), "5h 50%")
        XCTAssertEqual(RollingPolicy.trip(state(claudeAccount("a"), seven: nil, status: "rejected").snapshot), 100)
    }

    func testCandidatesFilterAndOrder() {
        let active = claudeAccount("active")
        let p2 = claudeAccount("p2", priority: 2)
        let p1late = claudeAccount("p1-late")
        let high = claudeAccount("high")
        let errored = claudeAccount("errored")
        let stale = claudeAccount("stale")
        let noSnap = claudeAccount("nosnap")
        let rejected = claudeAccount("rejected")
        let legacy = claudeAccount("legacy", kind: .storedToken)
        let local = claudeAccount("local", kind: .localClaudeCLI)
        let codex = Account(provider: .codex, kind: .storedToken, label: "codex")
        let p1early = claudeAccount("p1-early")
        let states = [
            state(active, seven: 99),
            state(p2, seven: 10),
            state(p1late, seven: 50),
            state(high, seven: 95),           // 임계 = 후보 아님
            state(errored, seven: 1, error: "HTTP 500"),
            state(stale, seven: 1, stale: "429로 인해 지연됨"),
            AccountState(account: noSnap),
            state(rejected, seven: 10, status: "rejected"),
            state(legacy, seven: 1),
            state(local, seven: 1),
            state(codex, seven: 1),
            state(p1early, seven: 94.9),
        ]
        // 등록 순서상 p1late가 p1early보다 앞 → 같은 우선순위면 등록 순서.
        let names = RollingPolicy.candidates(states: states, activeId: active.id).map(\.account.label)
        XCTAssertEqual(names, ["p1-late", "p1-early", "p2"])
    }

    func testAssignWhenNoActive() {
        let a = claudeAccount("a", priority: 2)
        let b = claudeAccount("b")
        let states = [state(a, seven: 10), state(b, seven: 20)]
        XCTAssertEqual(RollingPolicy.decide(states: states, activeId: nil, autoRoll: false, lastRollAt: nil, now: now),
                       .assign(b.id))
        // 지정된 계정이 사라졌거나 레거시면 재지정.
        XCTAssertEqual(RollingPolicy.decide(states: states, activeId: UUID(), autoRoll: false, lastRollAt: nil, now: now),
                       .assign(b.id))
    }

    func testAssignPrefersHealthyBelowThresholdThenAnyHealthy() {
        let top = claudeAccount("top")
        let second = claudeAccount("second", priority: 2)
        XCTAssertEqual(
            RollingPolicy.decide(states: [state(top, seven: 99), state(second, seven: 10)],
                                 activeId: nil, autoRoll: true, lastRollAt: nil, now: now),
            .assign(second.id))
        XCTAssertEqual(
            RollingPolicy.decide(states: [state(top, seven: 99), state(second, seven: 98)],
                                 activeId: nil, autoRoll: true, lastRollAt: nil, now: now),
            .assign(top.id))
        // 아직 아무것도 조회되지 않았거나 전부 오류면 기다린다.
        XCTAssertEqual(
            RollingPolicy.decide(states: [AccountState(account: top), state(second, seven: 1, error: "401")],
                                 activeId: nil, autoRoll: true, lastRollAt: nil, now: now),
            .idle)
    }

    func testNoTokenAccountsIsIdle() {
        let legacy = claudeAccount("legacy", kind: .storedToken)
        XCTAssertEqual(RollingPolicy.decide(states: [state(legacy, seven: 99)], activeId: nil,
                                            autoRoll: true, lastRollAt: nil, now: now), .idle)
    }

    func testThresholdCooldownExhaustedRoll() {
        let a = claudeAccount("a")
        let b = claudeAccount("b")
        func decide(_ aPct: Double, _ bPct: Double, autoRoll: Bool = true, last: Date? = nil,
                    aError: String? = nil, aStale: String? = nil) -> RollingPolicy.Decision {
            RollingPolicy.decide(
                states: [state(a, seven: aPct, error: aError, stale: aStale), state(b, seven: bPct)],
                activeId: a.id, autoRoll: autoRoll, lastRollAt: last, now: now)
        }
        XCTAssertEqual(decide(94.9, 10), .idle)
        XCTAssertEqual(decide(95, 10), .roll(from: a.id, to: b.id, reason: "7d 95%"))
        XCTAssertEqual(decide(99, 10, autoRoll: false), .disabled)
        XCTAssertEqual(decide(99, 10, aError: "HTTP 500"), .idle)
        XCTAssertEqual(decide(99, 10, aStale: "429로 인해 지연됨"), .idle)
        XCTAssertEqual(decide(99, 10, last: now.addingTimeInterval(-599)), .cooldown)
        XCTAssertEqual(decide(99, 10, last: now.addingTimeInterval(-600)), .roll(from: a.id, to: b.id, reason: "7d 99%"))
        XCTAssertEqual(decide(99, 96), .exhausted(reason: "7d 99%"))
    }

    func testRejectedActiveRollsRegardlessOfNumbers() {
        let a = claudeAccount("a")
        let b = claudeAccount("b")
        let d = RollingPolicy.decide(
            states: [state(a, seven: 30, status: "rejected"), state(b, seven: 10)],
            activeId: a.id, autoRoll: true, lastRollAt: nil, now: now)
        XCTAssertEqual(d, .roll(from: a.id, to: b.id, reason: "한도 거절"))
    }
}

@MainActor
final class RollingEngineTests: XCTestCase {
    var notifications: [String] = []
    var broadcasts: [String] = []
    var savedNotify: ((String, String) -> Void)!
    var savedBroadcast: ((String, [AccountState]) async -> Void)!

    override func setUp() async throws {
        RollingEngine.resetState()
        savedNotify = RollingEngine.notify
        savedBroadcast = RollingEngine.broadcast
        RollingEngine.notify = { [weak self] title, _ in self?.notifications.append(title) }
        RollingEngine.broadcast = { [weak self] header, _ in self?.broadcasts.append(header) }
    }

    override func tearDown() async throws {
        RollingEngine.notify = savedNotify
        RollingEngine.broadcast = savedBroadcast
    }

    func fixture() throws -> (AccountStore, ActiveAccountStore, Account, Account) {
        let dir = makeTempDir()
        let store = AccountStore(directory: dir)
        let active = ActiveAccountStore(directory: dir.appendingPathComponent("claude"))
        let a = Account(provider: .claude, kind: .setupToken, label: "a@example.com")
        let b = Account(provider: .claude, kind: .setupToken, label: "b@example.com")
        try store.add(a, secrets: AccountSecrets(accessToken: "tok-a"))
        try store.add(b, secrets: AccountSecrets(accessToken: "tok-b"))
        return (store, active, a, b)
    }

    func testAutoAssignWritesActiveFileAndHistory() async throws {
        let (store, active, a, b) = try fixture()
        let rolled = await RollingEngine.evaluate(
            states: [state(a, seven: 10), state(b, seven: 5)], store: store,
            active: active, autoRoll: false)
        XCTAssertTrue(rolled)
        XCTAssertEqual(active.read(), .init(accountId: a.id, token: "tok-a"))
        let history = active.loadHistory()
        XCTAssertEqual(history.count, 1)
        XCTAssertNil(history[0].from)
        XCTAssertEqual(history[0].to, a.id)
        XCTAssertTrue(notifications.isEmpty, "초기 지정은 알림 없음")
    }

    func testRollSwapsFileRecordsHistoryAndNotifies() async throws {
        let (store, active, a, b) = try fixture()
        try active.write(accountId: a.id, token: "tok-a")
        let now = Date()
        let rolled = await RollingEngine.evaluate(
            states: [state(a, seven: 97), state(b, seven: 5)], store: store,
            active: active, autoRoll: true, now: now)
        XCTAssertTrue(rolled)
        XCTAssertEqual(active.read(), .init(accountId: b.id, token: "tok-b"))
        let last = try XCTUnwrap(active.loadHistory().last)
        XCTAssertEqual(last.from, a.id)
        XCTAssertEqual(last.to, b.id)
        XCTAssertEqual(last.reason, "7d 97%")
        XCTAssertEqual(notifications, ["[>] 계정 롤링: a@example.com → b@example.com (7d 97%)"])
        XCTAssertEqual(broadcasts, notifications)

        // 이력 파일 기준 쿨다운: 앱 재시작·CLI 교체 뒤에도 유지.
        let again = await RollingEngine.evaluate(
            states: [state(a, seven: 5), state(b, seven: 99)], store: store,
            active: active, autoRoll: true, now: now.addingTimeInterval(60))
        XCTAssertFalse(again)
        XCTAssertEqual(active.read()?.accountId, b.id)
        // 토큰은 이력에 없다.
        let historyText = try String(contentsOf: active.historyURL, encoding: .utf8)
        XCTAssertFalse(historyText.contains("tok-"))
    }

    func testExhaustedNotifiesOnceUntilRecovered() async throws {
        let (store, active, a, b) = try fixture()
        try active.write(accountId: a.id, token: "tok-a")
        let full = [state(a, seven: 99), state(b, seven: 98)]
        for _ in 0..<3 {
            let rolled = await RollingEngine.evaluate(states: full, store: store, active: active, autoRoll: true)
            XCTAssertFalse(rolled)
        }
        XCTAssertEqual(notifications.count, 1)
        XCTAssertTrue(notifications[0].hasPrefix("[!] 계정 롤링 불가"))
        // 회복(임계 미만) 후 다시 소진되면 다시 1회.
        _ = await RollingEngine.evaluate(states: [state(a, seven: 10), state(b, seven: 98)],
                                         store: store, active: active, autoRoll: true)
        _ = await RollingEngine.evaluate(states: full, store: store, active: active, autoRoll: true)
        XCTAssertEqual(notifications.count, 2)
        XCTAssertEqual(active.read()?.accountId, a.id)
    }

    func testManualRollRefusesLegacyAndMissingToken() async throws {
        let (store, active, a, _) = try fixture()
        let legacy = Account(provider: .claude, kind: .storedToken, label: "old@example.com")
        try store.add(legacy, secrets: AccountSecrets(accessToken: "old"))
        let empty = Account(provider: .claude, kind: .setupToken, label: "empty@example.com")
        try store.add(empty, secrets: AccountSecrets())
        for target in [legacy, empty] {
            do {
                try await RollingEngine.roll(to: target, from: a, states: [], store: store,
                                             active: active, reason: "수동 전환")
                XCTFail("throw 기대")
            } catch {}
        }
        XCTAssertNil(active.read())
        XCTAssertTrue(notifications.isEmpty)
    }
}

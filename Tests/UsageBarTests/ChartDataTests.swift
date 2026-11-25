import Foundation
import SwiftUI
import XCTest
@testable import usagebar

final class ChartDataTests: XCTestCase {
    let seoul = TimeZone(identifier: "Asia/Seoul")!
    let me = "me@example.com"
    let other = "other@example.com"
    /// 2026-11-19 15:00 KST.
    let now = Date(timeIntervalSince1970: 1_795_068_000)
    let table = ModelPriceTable(prices: [
        "claude-big": ModelPrice(input: 1e-5, output: 2e-5, cacheWrite5m: 0, cacheWrite1h: nil, cacheRead: 1e-7),
        "claude-small": ModelPrice(input: 1e-6, output: 0, cacheWrite5m: 0, cacheWrite1h: nil, cacheRead: 0),
    ])

    func row(_ day: String, _ model: String, input: Int64 = 0, output: Int64 = 0,
             w5: Int64 = 0, w1: Int64 = 0, read: Int64 = 0) -> LedgerRow {
        LedgerRow(day: day, model: model, fast: false, us: false,
                  tokens: TokenCounts(input: input, output: output, cacheWrite5m: w5, cacheWrite1h: w1,
                                      cacheRead: read, webSearches: 0, messages: 1))
    }

    func mac(_ rows: [LedgerRow] = [], _ period: ChartPeriod = .week, firstDay: String? = "2026-11-01",
             table: ModelPriceTable? = nil) -> MacUsageData {
        MacUsageData(rows: rows, period: period, now: now, timeZone: seoul,
                     trackingStartedAt: Date(timeIntervalSince1970: 1_793_000_000),
                     firstLedgerDay: firstDay, table: table ?? self.table)
    }

    func sample(_ secondsAgo: Double, seven: Double?, five: Double? = nil, key: String? = nil) -> UsageSample {
        UsageSample(key: key ?? me, ts: now.addingTimeInterval(-secondsAgo), fiveHour: five, sevenDay: seven)
    }

    func roll(_ secondsAgo: Double, from: String?, to: String, reason: String = "") -> RollRecord {
        RollRecord(ts: now.addingTimeInterval(-secondsAgo), from: from, to: to, reason: reason)
    }

    func account(samples: [UsageSample] = [], rolls: [RollRecord] = [], activeNow: Bool = false,
                 first: Date? = nil, started: Date? = nil, _ period: ChartPeriod = .week) -> AccountUsageData {
        AccountUsageData(
            input: AccountUsageInput(key: me, samples: samples, rolls: rolls, activeNow: activeNow,
                                     firstSampleAt: first ?? samples.map(\.ts).min(),
                                     historyStartedAt: started ?? first ?? samples.map(\.ts).min()),
            period: period, now: now, timeZone: seoul)
    }

    // MARK: - Days and period

    func testDaysAreLocalMidnightsEndingToday() {
        let days = ChartDay.period(count: 7, endingAt: now, timeZone: seoul)
        XCTAssertEqual(days.map(\.key), ["2026-11-13", "2026-11-14", "2026-11-15", "2026-11-16",
                                         "2026-11-17", "2026-11-18", "2026-11-19"])
        // 2026-11-19 00:00 KST = 2026-11-18 15:00 UTC.
        XCTAssertEqual(days.last!.start, Date(timeIntervalSince1970: 1_795_014_000))
        XCTAssertEqual(ChartDay.period(count: 90, endingAt: now, timeZone: seoul).count, 90)
        // 00:30 KST는 UTC 날짜가 아니라 KST 날짜에 속한다.
        let early = Date(timeIntervalSince1970: 1_795_015_800)
        XCTAssertEqual(ChartDay.period(count: 1, endingAt: early, timeZone: seoul).map(\.key), ["2026-11-19"])
    }

    func testDefaultPeriodIsThirtyDays() {
        XCTAssertEqual(ChartPeriod.default, .month)
        XCTAssertEqual(ChartPeriod.allCases.map(\.days), [7, 30, 90])
    }

    // MARK: - Mac: cut, zero fill, totals

    func testMacCutsToPeriodAndZeroFillsDays() {
        let d = mac([
            row("2026-11-19", "claude-big", input: 100_000),       // $1
            row("2026-11-17", "claude-small", input: 1_000_000),   // $1
            row("2026-11-12", "claude-big", input: 9_999_999),     // 7일 기간 이전
        ])
        XCTAssertEqual(d.dayTotals.count, 7)
        XCTAssertEqual(d.dayTotals.map(\.total.tokens.input), [0, 0, 0, 0, 1_000_000, 0, 100_000])
        XCTAssertEqual(d.periodTotal.tokens.input, 1_100_000)
        XCTAssertEqual(d.periodTotal.cost, 2, accuracy: 1e-9)
        XCTAssertEqual(d.today.tokens.input, 100_000)
        XCTAssertEqual(d.today.cost, 1, accuracy: 1e-9)
        XCTAssertEqual(d.rangeStart, d.days.first!.start)
        XCTAssertEqual(d.rangeEnd, d.days.last!.start.addingTimeInterval(86_400))
        XCTAssertTrue(d.hasLedgerHistory)
        XCTAssertFalse(d.isEmptyPeriod)

        let month = mac([row("2026-11-12", "claude-big", input: 100_000)], .month)
        XCTAssertEqual(month.dayTotals.count, 30)
        XCTAssertEqual(month.periodTotal.tokens.input, 100_000)
    }

    // MARK: - Mac: token stacking and cache-read toggle

    func testTokenBarsStackKindsAndToggleCacheRead() {
        let d = mac([
            row("2026-11-19", "claude-big", input: 10, output: 20, w5: 3, w1: 4, read: 5_000),
            row("2026-11-19", "claude-small", input: 1, read: 1_000),
        ])
        let without = d.tokenBars(includeCacheRead: false)
        XCTAssertEqual(without.count, 7 * 3)
        let today = without.filter { $0.day.key == "2026-11-19" }
        XCTAssertEqual(today.map(\.kind), [.input, .output, .cacheWrite])
        XCTAssertEqual(today.map(\.value), [11, 20, 7])  // 캐시 쓰기 = 5분 + 1시간
        XCTAssertTrue(without.filter { $0.day.key == "2026-11-13" }.allSatisfy { $0.value == 0 })

        let with = d.tokenBars(includeCacheRead: true)
        XCTAssertEqual(with.count, 7 * 4)
        XCTAssertEqual(with.filter { $0.day.key == "2026-11-19" }.map(\.value), [11, 20, 7, 6_000])
        XCTAssertEqual(Set(with.map(\.id)).count, with.count)

        let t = d.today.tokens
        XCTAssertEqual(TokenKind.sum(t, includeCacheRead: false), 38)
        XCTAssertEqual(TokenKind.sum(t, includeCacheRead: true), t.totalTokens)
    }

    // MARK: - Mac: cost bars, model order, shares, unpriced

    func testCostBarsPerModelZeroFilledAndUnpricedExcluded() {
        let d = mac([
            row("2026-11-19", "claude-big", input: 100_000),       // $1
            row("2026-11-18", "claude-small", input: 3_000_000),   // $3
            row("2026-11-18", "claude-mystery", input: 7_000),     // 단가 미상
        ])
        XCTAssertEqual(d.chartModels, ["claude-small", "claude-big"])
        XCTAssertEqual(d.costBars.count, 7 * 2)
        let day18 = d.costBars.filter { $0.day.key == "2026-11-18" }
        XCTAssertEqual(day18.map(\.model), ["claude-small", "claude-big"])
        XCTAssertEqual(day18.map(\.cost), [3, 0])
        let total18 = d.dayTotals.first { $0.day.key == "2026-11-18" }!
        XCTAssertEqual(total18.modelCosts, ["claude-small": 3])
        XCTAssertEqual(total18.total.unpricedModels, ["claude-mystery"])
        XCTAssertFalse(d.periodTotal.isFullyPriced)
        XCTAssertEqual(LedgerFormat.cost(d.periodTotal), "$4.00 + 단가 미상")
    }

    func testModelSharesSortedWithCostAndTokenShares() {
        let d = mac([
            row("2026-11-19", "claude-big", input: 100_000),       // $1
            row("2026-11-18", "claude-small", input: 300_000),     // $0.3
            row("2026-11-18", "claude-mystery", input: 600_000),   // 단가 미상
        ])
        XCTAssertEqual(d.models.map(\.model), ["claude-big", "claude-small", "claude-mystery"])
        XCTAssertEqual(d.models[0].costShare!, 1 / 1.3, accuracy: 1e-9)
        XCTAssertEqual(d.models[1].costShare!, 0.3 / 1.3, accuracy: 1e-9)
        XCTAssertNil(d.models[2].costShare)
        XCTAssertFalse(d.models[2].total.isFullyPriced)
        XCTAssertEqual(d.models.map { $0.tokenShare! }, [0.1, 0.3, 0.6])
    }

    func testManyModelsFoldIntoOther() {
        var prices: [String: ModelPrice] = [:]
        var rows: [LedgerRow] = []
        for i in 1...10 {
            prices["m\(i)"] = ModelPrice(input: 1e-6, output: 0, cacheWrite5m: 0, cacheWrite1h: nil, cacheRead: 0)
            rows.append(row("2026-11-19", "m\(i)", input: Int64(i) * 1_000_000))  // $i
        }
        let d = mac(rows, table: ModelPriceTable(prices: prices))
        XCTAssertEqual(d.chartModels, ["m10", "m9", "m8", "m7", "m6", "m5", "m4", MacUsageData.otherModels])
        let today = d.dayTotals.last!
        XCTAssertEqual(today.modelCosts[MacUsageData.otherModels]!, 1 + 2 + 3, accuracy: 1e-9)
        XCTAssertEqual(today.modelCosts["m10"]!, 10, accuracy: 1e-9)
        XCTAssertEqual(d.costBars.count, 7 * 8)
        XCTAssertEqual(d.models.count, 10)  // 목록은 접지 않는다
    }

    func testMacEmpty() {
        let d = mac(firstDay: nil)
        XCTAssertFalse(d.hasLedgerHistory)
        XCTAssertTrue(d.isEmptyPeriod)
        XCTAssertTrue(d.models.isEmpty)
        XCTAssertTrue(d.chartModels.isEmpty)
        XCTAssertTrue(d.costBars.isEmpty)
        XCTAssertEqual(d.dayTotals.count, 7)
        XCTAssertEqual(d.periodTotal, LedgerReport.Total())
        XCTAssertTrue(d.tokenBars(includeCacheRead: false).allSatisfy { $0.value == 0 })
    }

    func testDayTotalAtChartPosition() {
        let d = mac([row("2026-11-19", "claude-big", input: 42)])
        // 2026-11-19 23:59 KST → 오늘, 2026-11-20 00:01 KST → 기간 밖.
        XCTAssertEqual(d.dayTotal(at: Date(timeIntervalSince1970: 1_795_100_340))?.total.tokens.input, 42)
        XCTAssertNil(d.dayTotal(at: Date(timeIntervalSince1970: 1_795_100_460)))
    }

    // MARK: - Account: usage points, key filter, peak

    func testUsagePointsFilteredByKeyClippedSortedClamped() {
        let start = ChartDay.period(count: 7, endingAt: now, timeZone: seoul).first!.start
        let samples = [
            sample(600, seven: 62),
            sample(3600, seven: 60),
            UsageSample(key: me, ts: start.addingTimeInterval(-1), fiveHour: nil, sevenDay: 1),  // 기간 이전
            sample(30, seven: 99, key: other),                                                        // 다른 계정
            sample(60, seven: 140),                                                              // 100으로
        ]
        let d = account(samples: samples)
        XCTAssertEqual(d.usage.map(\.percent), [60, 62, 100])
        XCTAssertFalse(d.hasFiveHour)
        XCTAssertEqual(d.usageSample(near: now.addingTimeInterval(-900))?.percent, 62)
        XCTAssertEqual(d.peakSevenDay, .init(ts: now.addingTimeInterval(-60), percent: 100))
        XCTAssertNil(d.emptyNotice)

        let withFive = account(samples: [sample(0, seven: 50, five: 10), sample(300, seven: nil, five: 30)])
        XCTAssertTrue(withFive.hasFiveHour)
        XCTAssertEqual(withFive.usage.map(\.window), [.sevenDay, .fiveHour, .fiveHour])
        XCTAssertEqual(withFive.peakSevenDay?.percent, 50)
        XCTAssertEqual(withFive.usageSample(near: now, window: .fiveHour)?.percent, 10)
    }

    func testPeakIsHighestInPeriodLatestOnTie() {
        let d = account(samples: [sample(7200, seven: 80), sample(3600, seven: 80), sample(60, seven: 20),
                                  sample(8 * 86_400, seven: 99)])  // 기간 밖 99는 무시
        XCTAssertEqual(d.peakSevenDay, .init(ts: now.addingTimeInterval(-3600), percent: 80))
        XCTAssertNil(account().peakSevenDay)
    }

    // MARK: - Account: roll events and active spans

    func testRollEventsInAndOutOfThisAccount() {
        let rolls = [
            roll(10 * 86_400, from: other, to: me, reason: "기간 밖"),
            roll(3 * 86_400, from: other, to: me, reason: "7d 95%"),
            roll(2 * 86_400, from: me, to: other, reason: "수동 전환"),
            roll(86_400, from: nil, to: me),
            roll(7200, from: me, to: me),            // 변화 없음
            roll(3600, from: other, to: "third@example.com"),  // 무관
        ]
        let d = account(rolls: rolls.reversed())
        XCTAssertEqual(d.rollEvents.map(\.direction), [.rolledIn, .rolledOut, .rolledIn])
        XCTAssertEqual(d.rollEvents.map(\.counterpart), [other, other, nil])
        XCTAssertEqual(d.rollEvents.map(\.ts), [now.addingTimeInterval(-3 * 86_400),
                                                now.addingTimeInterval(-2 * 86_400),
                                                now.addingTimeInterval(-86_400)])
        XCTAssertEqual(Set(d.rollEvents.map(\.id)).count, 3)
    }

    func testActiveIntervalsOnlyWhereBothEndsAreKnown() {
        let from = now.addingTimeInterval(-7 * 86_400)
        let rolls = [
            roll(10 * 86_400, from: nil, to: me),                // 기간 이전 시작
            roll(3 * 86_400, from: me, to: other),               // 끝 확인
            roll(3600, from: other, to: me),                     // 열린 구간
        ]
        XCTAssertEqual(
            AccountUsageData.activeIntervals(rolls: rolls.reversed(), key: me, activeNow: true, from: from, to: now),
            [DateInterval(start: from, end: now.addingTimeInterval(-3 * 86_400)),
             DateInterval(start: now.addingTimeInterval(-3600), end: now)])
        // 지금 로그인이 이 계정이 아니면 열린 구간의 끝을 모른다 → 그리지 않는다.
        XCTAssertEqual(
            AccountUsageData.activeIntervals(rolls: rolls, key: me, activeNow: false, from: from, to: now),
            [DateInterval(start: from, end: now.addingTimeInterval(-3 * 86_400))])
        // 상대 계정: 3일 전 ~ 1시간 전.
        XCTAssertEqual(
            AccountUsageData.activeIntervals(rolls: rolls, key: other, activeNow: false, from: from, to: now),
            [DateInterval(start: now.addingTimeInterval(-3 * 86_400), end: now.addingTimeInterval(-3600))])

        // 다음 기록의 from이 다른 계정/미상 = 기록 없는 로그인 변경 → 그 구간은 버린다.
        let gap = [
            roll(5 * 86_400, from: nil, to: me),
            roll(4 * 86_400, from: other, to: "third@example.com"),
            roll(2 * 86_400, from: nil, to: me),
            roll(86_400, from: nil, to: me),   // 미상 → 이전 구간 버리고 새로 시작
            roll(3600, from: me, to: other),
        ]
        XCTAssertEqual(
            AccountUsageData.activeIntervals(rolls: gap, key: me, activeNow: false, from: from, to: now),
            [DateInterval(start: now.addingTimeInterval(-86_400), end: now.addingTimeInterval(-3600))])

        // 같은 계정 재지정(from == to == 이 계정)은 구간을 끊지 않는다.
        let repeated = [roll(7200, from: nil, to: me), roll(3600, from: me, to: me)]
        XCTAssertEqual(
            AccountUsageData.activeIntervals(rolls: repeated, key: me, activeNow: true, from: from, to: now),
            [DateInterval(start: now.addingTimeInterval(-7200), end: now)])
    }

    // MARK: - Account: empty notices

    func testEmptyNotices() {
        let started = now.addingTimeInterval(-3 * 86_400)  // 2026-11-16
        XCTAssertEqual(account(started: started).emptyNotice,
                       "2026-11-16 이후 이 계정의 사용률 기록이 없습니다")
        XCTAssertEqual(account(first: now.addingTimeInterval(-20 * 86_400)).emptyNotice,
                       "최근 7일 동안 이 계정의 사용률 기록이 없습니다 (기록 시작 2026-10-30)")
        XCTAssertTrue(account().emptyNotice!.hasPrefix("아직 사용률 기록이 없습니다"))
    }

    // MARK: - Text

    func testFormatting() {
        XCTAssertEqual(ChartFormat.percent(62.9), "62%")
        XCTAssertEqual(ChartFormat.share(0.1234), "12.3%")
        XCTAssertEqual(ChartFormat.share(0.0004), "<0.1%")
        XCTAssertEqual(ChartFormat.share(nil), "—")
        XCTAssertEqual(ChartFormat.axisDollars(0), "$0")
        XCTAssertEqual(ChartFormat.axisDollars(0.25), "$0.25")
        XCTAssertEqual(ChartFormat.axisDollars(1.5), "$1.5")
        XCTAssertEqual(ChartFormat.axisDollars(40), "$40")
        XCTAssertEqual(ChartFormat.axisDollars(1500), "$1.5K")
        XCTAssertEqual(
            ChartFormat.breakdown(TokenCounts(input: 1_234, output: 5, cacheWrite5m: 1, cacheWrite1h: 2,
                                              cacheRead: 1_000_000, webSearches: 0, messages: 0)),
            "입력 1,234 · 출력 5 · 캐시 쓰기 3 · 캐시 읽기 1,000,000")
        XCTAssertEqual(ChartFormat.noLedgerNotice(trackingStartedAt: now, timeZone: seoul),
                       "2026-11-19 이후 기록된 claude 사용량이 없습니다")
        XCTAssertTrue(ChartFormat.noLedgerNotice(trackingStartedAt: nil, timeZone: seoul)
            .hasPrefix("아직 사용량 집계가 시작되지 않았습니다"))
        XCTAssertEqual(ChartFormat.dayLabel(ChartDay.period(count: 1, endingAt: now, timeZone: seoul)[0],
                                            timeZone: seoul), "11월 19일 (목)")
        XCTAssertEqual(
            ChartFormat.rollEvent(.init(ts: now, direction: .rolledIn, counterpart: other, reason: "7d 95%"),
                                  timeZone: seoul),
            "11월 19일 15:00 이 계정으로 교체 (← other@example.com, 7d 95%)")
        XCTAssertEqual(
            ChartFormat.rollEvent(.init(ts: now, direction: .rolledOut, counterpart: nil, reason: ""),
                                  timeZone: seoul),
            "11월 19일 15:00 다른 계정으로 교체")
    }

    // MARK: - Row key

    func testUsageKeyOfRows() {
        var stored = AccountState(account: Account(provider: .claude, kind: .storedToken, label: "Me@Example.com"))
        XCTAssertEqual(stored.usageKey, me)
        stored.account.label = "work token"
        XCTAssertNil(stored.usageKey)  // 이메일 미상 → 버튼 비활성

        var local = AccountState(account: Account(provider: .claude, kind: .localClaudeCLI,
                                                  label: "old@example.com (로컬)"))
        XCTAssertEqual(local.usageKey, "old@example.com")
        local.snapshot = snapshot(seven: 10, resolved: "new@example.com (로컬)")
        XCTAssertEqual(local.usageKey, "new@example.com")  // 지금 해석된 이메일

        let codex = AccountState(account: Account(provider: .codex, kind: .storedToken, label: me))
        XCTAssertNil(codex.usageKey)
    }

    // MARK: - Loaders (real stores in a temp directory)

    func testAccountLoaderReadsHistoryAndRolls() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = UsageHistoryStore(directory: dir, now: { self.now })
        let rolls = RollHistoryStore(directory: dir, now: { self.now })

        // 기록이 하나도 없을 때.
        let empty = AccountUsageLoader.load(key: me, period: .week, now: now, activeNow: false,
                                            timeZone: seoul, history: history, rolls: rolls)
        XCTAssertTrue(empty.emptyNotice!.hasPrefix("아직"))

        history.record(sample(20 * 86_400, seven: 5, key: other))
        history.record(sample(600, seven: 40, five: 12))
        history.record(sample(300, seven: 70, key: other))
        rolls.record(from: other, to: "ME@example.com", reason: "7d 95%", at: now.addingTimeInterval(-7200))

        let d = AccountUsageLoader.load(key: me, period: .week, now: now, activeNow: true,
                                        timeZone: seoul, history: history, rolls: rolls)
        XCTAssertEqual(d.usage.map(\.percent), [40, 12])
        XCTAssertEqual(d.rollEvents.map(\.direction), [.rolledIn])
        XCTAssertEqual(d.activeIntervals, [DateInterval(start: now.addingTimeInterval(-7200), end: now)])
        XCTAssertEqual(d.firstSampleAt, now.addingTimeInterval(-600))
        XCTAssertEqual(d.historyStartedAt, now.addingTimeInterval(-20 * 86_400))
        XCTAssertEqual(history.firstSampleDate(key: "nobody@example.com"), nil)
        XCTAssertEqual(history.firstSampleDate(key: "not an email"), nil)
    }

    func testMacLoaderWithoutLedgerFile() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ledger = UsageLedger(directory: dir, projectsRoot: dir.appendingPathComponent("projects"),
                                 timeZone: seoul, now: { self.now }, prices: { ModelPriceSource.bundledTable })
        let loaded = MacUsageLoader.load(period: .week, now: now, ledger: ledger,
                                         prices: ModelPriceSource(directory: dir))
        XCTAssertNil(loaded.error)
        XCTAssertFalse(loaded.data.hasLedgerHistory)
        XCTAssertNil(loaded.data.trackingStartedAt)

        // 첫 집계 후: 집계 시작은 생기고, 기록은 아직 없다.
        try ledger.ingest()
        let after = MacUsageLoader.load(period: .week, now: now, ledger: ledger,
                                        prices: ModelPriceSource(directory: dir))
        XCTAssertNil(after.error)
        XCTAssertEqual(after.data.trackingStartedAt, now)
        XCTAssertFalse(after.data.hasLedgerHistory)
    }
}

// MARK: - Fixture screenshots (opt-in: USAGEBAR_CHART_SNAPSHOT_DIR=<디렉터리>)

@MainActor
final class ChartSnapshotTests: XCTestCase {
    let seoul = TimeZone(identifier: "Asia/Seoul")!
    let now = Date(timeIntervalSince1970: 1_795_068_000)

    private func outputDir() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["USAGEBAR_CHART_SNAPSHOT_DIR"] else {
            throw XCTSkip("USAGEBAR_CHART_SNAPSHOT_DIR 미지정 — 스크린샷 생략")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func render<V: View>(_ view: V, width: CGFloat, to url: URL) throws {
        let content = view
            .padding(16)
            .frame(width: width)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.timeZone, seoul)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: url)
    }

    func testRenderAccountUsageFixture() throws {
        let dir = try outputDir()
        let me = "me@example.com", other = "other@example.com"
        var samples: [UsageSample] = []
        var pct = 5.0
        for h in stride(from: 24 * 30, through: 0, by: -1) {
            let ts = now.addingTimeInterval(-Double(h) * 3600)
            pct += Double((h * 13) % 7) * 0.09
            if h == 24 * 22 || h == 24 * 15 || h == 24 * 8 || h == 24 + 5 { pct = 3 }  // 주간 리셋
            let five = Double((h * 7) % 60) + (h % 5 == 0 ? 30 : 0)
            samples.append(UsageSample(key: me, ts: ts, fiveHour: min(five, 100), sevenDay: min(pct, 99)))
        }
        let rolls = [
            RollRecord(ts: now.addingTimeInterval(-25 * 86_400), from: other, to: me, reason: "7d 95%"),
            RollRecord(ts: now.addingTimeInterval(-15 * 86_400 - 7200), from: me, to: other, reason: "7d 95%"),
            RollRecord(ts: now.addingTimeInterval(-8 * 86_400), from: other, to: me, reason: "수동 전환"),
            RollRecord(ts: now.addingTimeInterval(-2 * 86_400), from: me, to: other, reason: "5h 96%"),
            RollRecord(ts: now.addingTimeInterval(-86_400 + 3600), from: other, to: me, reason: "7d 95%"),
        ]
        let data = AccountUsageData(
            input: AccountUsageInput(key: me, samples: samples, rolls: rolls, activeNow: true,
                                     firstSampleAt: samples.first?.ts, historyStartedAt: samples.first?.ts),
            period: .month, now: now, timeZone: seoul)
        let snap = UsageSnapshot(
            fiveHour: WindowUsage(percent: 41, resetsAt: Date().addingTimeInterval(2 * 3600 + 600)),
            sevenDay: WindowUsage(percent: 62, resetsAt: Date().addingTimeInterval(2 * 86_400 + 3 * 3600)),
            fetchedAt: now)
        try render(AccountUsageContent(data: data, snapshot: snap, hasLiveRow: true),
                   width: 760, to: dir.appendingPathComponent("account-usage.png"))
    }

    func testRenderMacUsageFixture() throws {
        let dir = try outputDir()
        let days = ChartDay.period(count: 30, endingAt: now, timeZone: seoul)
        var rows: [LedgerRow] = []
        func row(_ day: String, _ model: String, input: Int64, output: Int64, w1: Int64, read: Int64) -> LedgerRow {
            LedgerRow(day: day, model: model, fast: false, us: false,
                      tokens: TokenCounts(input: input, output: output, cacheWrite5m: 0, cacheWrite1h: w1,
                                          cacheRead: read, webSearches: 0, messages: 10))
        }
        for (i, day) in days.enumerated() where i >= 6 && i % 7 != 3 {
            let s = Int64(1 + (i * 37) % 9)
            rows.append(row(day.key, "claude-opus-5-5", input: 2_000 * s, output: 40_000 * s,
                            w1: 120_000 * s, read: 4_000_000 * s))
            rows.append(row(day.key, "claude-haiku-4-5", input: 1_000 * s, output: 9_000 * s,
                            w1: 30_000 * s, read: 600_000 * s))
            if i % 3 == 0 {
                rows.append(row(day.key, "claude-fable-5-1", input: 500 * s, output: 20_000 * s,
                                w1: 50_000 * s, read: 1_500_000 * s))
            }
        }
        rows.append(row(days.last!.key, "claude-mystery-9", input: 1_000, output: 1_000, w1: 0, read: 0))
        let data = MacUsageData(rows: rows, period: .month, now: now, timeZone: seoul,
                                trackingStartedAt: days[6].start.addingTimeInterval(9 * 3600),
                                firstLedgerDay: days[6].key, table: ModelPriceSource.bundledTable)
        try render(MacUsageContent(data: data, includeCacheRead: .constant(false)),
                   width: 780, to: dir.appendingPathComponent("mac-usage.png"))
    }
}

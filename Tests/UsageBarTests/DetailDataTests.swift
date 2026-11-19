import Foundation
import SwiftUI
import XCTest
@testable import usagebar

final class DetailDataTests: XCTestCase {
    let seoul = TimeZone(identifier: "Asia/Seoul")!
    let me = UUID()
    let other = UUID()
    /// 2026-11-19 15:00 KST.
    let now = Date(timeIntervalSince1970: 1_795_068_000)
    let table = ModelPriceTable(prices: [
        "claude-big": ModelPrice(input: 1e-5, output: 2e-5, cacheWrite5m: 0, cacheWrite1h: nil, cacheRead: 1e-7),
        "claude-small": ModelPrice(input: 1e-6, output: 0, cacheWrite5m: 0, cacheWrite1h: nil, cacheRead: 0),
    ])

    func row(_ day: String, _ model: String, account: UUID? = nil, input: Int64 = 0, output: Int64 = 0,
             w5: Int64 = 0, w1: Int64 = 0, read: Int64 = 0) -> LedgerRow {
        LedgerRow(accountId: account ?? me, day: day, model: model, fast: false, us: false,
                  tokens: TokenCounts(input: input, output: output, cacheWrite5m: w5, cacheWrite1h: w1,
                                      cacheRead: read, webSearches: 0, messages: 1))
    }

    func input(rows: [LedgerRow] = [], samples: [UsageSample] = [],
               rolls: [ActiveAccountStore.RollRecord] = [], activeNow: Bool = false,
               firstDay: String? = "2026-11-01") -> DetailInput {
        DetailInput(accountId: me, rows: rows, samples: samples, rolls: rolls, activeNow: activeNow,
                    trackingStartedAt: Date(timeIntervalSince1970: 1_793_000_000),
                    firstLedgerDay: firstDay, table: table)
    }

    func data(_ i: DetailInput, _ period: DetailPeriod = .week) -> DetailData {
        DetailData(input: i, period: period, now: now, timeZone: seoul)
    }

    // MARK: - Days

    func testDaysAreLocalMidnightsEndingToday() {
        let days = DetailData.days(count: 7, endingAt: now, timeZone: seoul)
        XCTAssertEqual(days.map(\.key), ["2026-11-13", "2026-11-14", "2026-11-15", "2026-11-16",
                                         "2026-11-17", "2026-11-18", "2026-11-19"])
        // 2026-11-19 00:00 KST = 2026-11-18 15:00 UTC.
        XCTAssertEqual(days.last!.start, Date(timeIntervalSince1970: 1_795_014_000))
        XCTAssertEqual(DetailData.days(count: 90, endingAt: now, timeZone: seoul).count, 90)
        // 00:30 KST still belongs to the KST day, not the UTC one.
        let early = Date(timeIntervalSince1970: 1_795_015_800)  // 2026-11-19 00:30 KST
        XCTAssertEqual(DetailData.days(count: 1, endingAt: early, timeZone: seoul).map(\.key), ["2026-11-19"])
    }

    func testDefaultPeriodIsThirtyDays() {
        XCTAssertEqual(DetailPeriod.default, .month)
        XCTAssertEqual(DetailPeriod.allCases.map(\.days), [7, 30, 90])
    }

    // MARK: - Period cut, zero fill, totals

    func testCutsToPeriodAndAccountAndZeroFillsDays() {
        let d = data(input(rows: [
            row("2026-11-19", "claude-big", input: 100_000),          // $1
            row("2026-11-17", "claude-small", input: 1_000_000),      // $1
            row("2026-11-12", "claude-big", input: 9_999_999),        // before the 7-day period
            row("2026-11-19", "claude-big", account: other, input: 5), // other account
        ]))
        XCTAssertEqual(d.dayTotals.count, 7)
        XCTAssertEqual(d.dayTotals.map(\.total.tokens.input), [0, 0, 0, 0, 1_000_000, 0, 100_000])
        XCTAssertEqual(d.periodTotal.tokens.input, 1_100_000)
        XCTAssertEqual(d.periodTotal.cost, 2, accuracy: 1e-9)
        XCTAssertEqual(d.today.tokens.input, 100_000)
        XCTAssertEqual(d.today.cost, 1, accuracy: 1e-9)
        XCTAssertEqual(d.rangeStart, d.days.first!.start)
        XCTAssertTrue(d.hasLedgerHistory)
    }

    func testThirtyDayPeriodKeepsOlderRow() {
        let d = data(input(rows: [row("2026-11-12", "claude-big", input: 100_000)]), .month)
        XCTAssertEqual(d.dayTotals.count, 30)
        XCTAssertEqual(d.periodTotal.tokens.input, 100_000)
    }

    // MARK: - Token stacking and cache-read toggle

    func testTokenBarsStackKindsAndToggleCacheRead() {
        let d = data(input(rows: [
            row("2026-11-19", "claude-big", input: 10, output: 20, w5: 3, w1: 4, read: 5_000),
            row("2026-11-19", "claude-small", input: 1, read: 1_000),
        ]))
        let without = d.tokenBars(includeCacheRead: false)
        XCTAssertEqual(without.count, 7 * 3)  // every day × input/output/cacheWrite
        let today = without.filter { $0.day.key == "2026-11-19" }
        XCTAssertEqual(today.map(\.kind), [.input, .output, .cacheWrite])
        XCTAssertEqual(today.map(\.value), [11, 20, 7])  // cache write = 5m + 1h
        XCTAssertTrue(without.filter { $0.day.key == "2026-11-13" }.allSatisfy { $0.value == 0 })

        let with = d.tokenBars(includeCacheRead: true)
        XCTAssertEqual(with.count, 7 * 4)
        XCTAssertEqual(with.filter { $0.day.key == "2026-11-19" }.map(\.value), [11, 20, 7, 6_000])
        XCTAssertEqual(Set(with.map(\.id)).count, with.count)  // stable unique ids
    }

    // MARK: - Cost bars, model order, shares, unpriced

    func testCostBarsPerModelZeroFilledAndUnpricedExcluded() {
        let d = data(input(rows: [
            row("2026-11-19", "claude-big", input: 100_000),       // $1
            row("2026-11-18", "claude-small", input: 3_000_000),   // $3
            row("2026-11-18", "claude-mystery", input: 7_000),     // unpriced
        ]))
        XCTAssertEqual(d.chartModels, ["claude-small", "claude-big"])  // cost desc, unpriced not drawn
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
        let d = data(input(rows: [
            row("2026-11-19", "claude-big", input: 100_000),       // $1, 100,000 tok
            row("2026-11-18", "claude-small", input: 300_000),     // $0.3, 300,000 tok
            row("2026-11-18", "claude-mystery", input: 600_000),   // unpriced, 600,000 tok
        ]))
        XCTAssertEqual(d.models.map(\.model), ["claude-big", "claude-small", "claude-mystery"])
        XCTAssertEqual(d.models[0].costShare!, 1 / 1.3, accuracy: 1e-9)
        XCTAssertEqual(d.models[1].costShare!, 0.3 / 1.3, accuracy: 1e-9)
        XCTAssertNil(d.models[2].costShare)
        XCTAssertFalse(d.models[2].total.isFullyPriced)
        XCTAssertEqual(d.models.map { $0.tokenShare! }, [0.1, 0.3, 0.6])
    }

    func testEmptyPeriod() {
        let d = data(input(firstDay: nil))
        XCTAssertFalse(d.hasLedgerHistory)
        XCTAssertTrue(d.models.isEmpty)
        XCTAssertTrue(d.chartModels.isEmpty)
        XCTAssertTrue(d.costBars.isEmpty)
        XCTAssertEqual(d.dayTotals.count, 7)
        XCTAssertEqual(d.periodTotal, LedgerReport.Total())
        XCTAssertTrue(d.tokenBars(includeCacheRead: false).allSatisfy { $0.value == 0 })
    }

    // MARK: - Hover lookups

    func testDayTotalAtChartPosition() {
        let d = data(input(rows: [row("2026-11-19", "claude-big", input: 42)]))
        // 2026-11-19 23:59 KST → today; 2026-11-20 00:01 KST → outside.
        XCTAssertEqual(d.dayTotal(at: Date(timeIntervalSince1970: 1_795_100_340))?.total.tokens.input, 42)
        XCTAssertNil(d.dayTotal(at: Date(timeIntervalSince1970: 1_795_100_460)))
    }

    func testUsagePointsClippedSortedAndNearestLookup() {
        let start = DetailData.days(count: 7, endingAt: now, timeZone: seoul).first!.start
        let samples = [
            UsageSample(accountId: me, ts: now.addingTimeInterval(-600), sevenDay: 62, fiveHour: nil, status: nil),
            UsageSample(accountId: me, ts: now.addingTimeInterval(-3600), sevenDay: 60, fiveHour: nil, status: nil),
            UsageSample(accountId: me, ts: start.addingTimeInterval(-1), sevenDay: 1, fiveHour: nil, status: nil),
            UsageSample(accountId: other, ts: now, sevenDay: 99, fiveHour: nil, status: nil),
            UsageSample(accountId: me, ts: now.addingTimeInterval(-60), sevenDay: 140, fiveHour: nil, status: nil),
        ]
        let d = data(input(samples: samples))
        XCTAssertEqual(d.usage.map(\.percent), [60, 62, 100])  // sorted, clipped to period, clamped
        XCTAssertFalse(d.hasFiveHour)
        XCTAssertEqual(d.usageSample(near: now.addingTimeInterval(-900))?.percent, 62)

        let withFive = data(input(samples: [
            UsageSample(accountId: me, ts: now, sevenDay: 50, fiveHour: 10, status: nil),
        ]))
        XCTAssertTrue(withFive.hasFiveHour)
        XCTAssertEqual(withFive.usage.map(\.window), [.sevenDay, .fiveHour])
    }

    // MARK: - Active spans

    func testActiveIntervalsFromRollHistory() {
        let t0 = now.addingTimeInterval(-10 * 86_400)
        let rolls = [
            ActiveAccountStore.RollRecord(ts: t0, from: nil, to: me, reason: "활성 계정 자동 지정"),
            ActiveAccountStore.RollRecord(ts: now.addingTimeInterval(-3 * 86_400), from: me, to: other, reason: "7d 95%"),
            ActiveAccountStore.RollRecord(ts: now.addingTimeInterval(-3600), from: other, to: me, reason: "수동 전환"),
        ]
        let from = now.addingTimeInterval(-7 * 86_400)
        let spans = DetailData.activeIntervals(rolls: rolls.reversed(), account: me, activeNow: true, from: from, to: now)
        XCTAssertEqual(spans, [
            DateInterval(start: from, end: now.addingTimeInterval(-3 * 86_400)),  // clipped at the period start
            DateInterval(start: now.addingTimeInterval(-3600), end: now),          // open span runs to now
        ])
        XCTAssertEqual(
            DetailData.activeIntervals(rolls: rolls, account: other, activeNow: false, from: from, to: now),
            [DateInterval(start: now.addingTimeInterval(-3 * 86_400), end: now.addingTimeInterval(-3600))])
        // The file no longer names the account → the open span's end is unknown: not drawn.
        XCTAssertEqual(
            DetailData.activeIntervals(rolls: rolls, account: me, activeNow: false, from: from, to: now),
            [DateInterval(start: from, end: now.addingTimeInterval(-3 * 86_400))])
        // Repeated records for the already active account don't split the span.
        let repeated = [
            ActiveAccountStore.RollRecord(ts: now.addingTimeInterval(-7200), from: nil, to: me, reason: ""),
            ActiveAccountStore.RollRecord(ts: now.addingTimeInterval(-3600), from: other, to: me, reason: ""),
        ]
        XCTAssertEqual(DetailData.activeIntervals(rolls: repeated, account: me, activeNow: true, from: from, to: now),
                       [DateInterval(start: now.addingTimeInterval(-7200), end: now)])
    }

    // MARK: - Text

    func testFormatting() {
        XCTAssertEqual(DetailFormat.percent(62.9), "62%")
        XCTAssertEqual(DetailFormat.share(0.1234), "12.3%")
        XCTAssertEqual(DetailFormat.share(0.0004), "<0.1%")
        XCTAssertEqual(DetailFormat.share(nil), "—")
        XCTAssertEqual(DetailFormat.axisDollars(0), "$0")
        XCTAssertEqual(DetailFormat.axisDollars(0.25), "$0.25")
        XCTAssertEqual(DetailFormat.axisDollars(1.5), "$1.5")
        XCTAssertEqual(DetailFormat.axisDollars(40), "$40")
        XCTAssertEqual(DetailFormat.axisDollars(1500), "$1.5K")
        XCTAssertEqual(
            DetailFormat.breakdown(TokenCounts(input: 1_234, output: 5, cacheWrite5m: 1, cacheWrite1h: 2,
                                               cacheRead: 1_000_000, webSearches: 0, messages: 0)),
            "입력 1,234 · 출력 5 · 캐시 쓰기 3 · 캐시 읽기 1,000,000")
        XCTAssertEqual(
            DetailFormat.noLedgerNotice(trackingStartedAt: now, timeZone: seoul),
            "2026-11-19 이후 이 계정으로 실행된 claude 기록이 없습니다 — usagebar-claude를 거친 실행만 집계됩니다")
        XCTAssertTrue(DetailFormat.noLedgerNotice(trackingStartedAt: nil, timeZone: seoul)
            .hasSuffix("usagebar-claude를 거친 실행만 집계됩니다"))
    }

    // MARK: - Loader (real stores in a temp directory)

    func testLoaderReadsStoresForOneAccount() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ledger = UsageLedger(directory: dir, projectsRoot: dir.appendingPathComponent("projects"),
                                 timeZone: seoul, now: { self.now }, prices: { ModelPriceSource.bundledTable })
        let history = UsageHistoryStore(directory: dir, now: { self.now })
        let active = ActiveAccountStore(directory: dir)
        let prices = ModelPriceSource(directory: dir)
        history.record(UsageSample(accountId: me, ts: now.addingTimeInterval(-60), sevenDay: 40, fiveHour: nil, status: nil))
        try active.write(accountId: me, token: "sk-ant-oat01-test")
        try active.appendHistory(.init(ts: now.addingTimeInterval(-7200), from: nil, to: me, reason: "지정"))

        // No ledger file yet: empty but loadable, no error.
        let empty = DetailLoader.load(accountId: me, period: .week, now: now, ledger: ledger,
                                      history: history, active: active, prices: prices)
        XCTAssertNil(empty.error)
        XCTAssertFalse(empty.data.hasLedgerHistory)
        XCTAssertEqual(empty.data.usage.map(\.percent), [40])
        XCTAssertEqual(empty.data.activeIntervals, [DateInterval(start: now.addingTimeInterval(-7200), end: now)])
        XCTAssertNil(try ledger.firstDay(account: me))
    }

    // MARK: - Fixture screenshot (opt-in: USAGEBAR_DETAIL_SNAPSHOT=<png path>)

    @MainActor
    func testRenderFixtureSnapshot() throws {
        guard let path = ProcessInfo.processInfo.environment["USAGEBAR_DETAIL_SNAPSHOT"] else {
            throw XCTSkip("USAGEBAR_DETAIL_SNAPSHOT 미지정 — 스크린샷 생략")
        }
        let d = DetailData(input: fixtureInput(), period: .month, now: now, timeZone: seoul)
        let snap = UsageSnapshot(
            sevenDay: WindowUsage(percent: 62, resetsAt: Date().addingTimeInterval(2 * 86_400 + 3 * 3600)),
            fetchedAt: now, limitStatus: "allowed")
        let view = AccountDetailContent(data: d, snapshot: snap, includeCacheRead: .constant(false))
            .padding(16)
            .frame(width: 780)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.timeZone, seoul)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: path))
    }

    /// 30 days of plausible usage for the snapshot.
    func fixtureInput() -> DetailInput {
        let days = DetailData.days(count: 30, endingAt: now, timeZone: seoul)
        var rows: [LedgerRow] = []
        var samples: [UsageSample] = []
        let table = ModelPriceSource.bundledTable
        for (i, day) in days.enumerated() where i >= 6 && i % 7 != 3 {
            let scale = Int64(1 + (i * 37) % 9)
            rows.append(row(day.key, "claude-opus-5-5", input: 2_000 * scale, output: 40_000 * scale,
                            w5: 0, w1: 120_000 * scale, read: 4_000_000 * scale))
            rows.append(row(day.key, "claude-haiku-4-5", input: 1_000 * scale, output: 9_000 * scale,
                            w1: 30_000 * scale, read: 600_000 * scale))
            if i % 3 == 0 {
                rows.append(row(day.key, "claude-fable-5-1", input: 500 * scale, output: 20_000 * scale,
                                w1: 50_000 * scale, read: 1_500_000 * scale))
            }
        }
        rows.append(row(days.last!.key, "claude-mystery-9", input: 1_000, output: 1_000))
        var pct = 5.0
        for h in stride(from: 24 * 24, through: 0, by: -3) {
            let ts = now.addingTimeInterval(-Double(h) * 3600)
            pct += Double((h * 13) % 7) * 0.12
            if h == 24 * 17 || h == 24 * 10 || h == 24 * 3 { pct = 4 }  // weekly resets
            samples.append(UsageSample(accountId: me, ts: ts, sevenDay: min(pct, 99), fiveHour: nil, status: nil))
        }
        let rolls = [
            ActiveAccountStore.RollRecord(ts: now.addingTimeInterval(-25 * 86_400), from: nil, to: me, reason: ""),
            ActiveAccountStore.RollRecord(ts: now.addingTimeInterval(-12 * 86_400), from: me, to: other, reason: ""),
            ActiveAccountStore.RollRecord(ts: now.addingTimeInterval(-6 * 86_400), from: other, to: me, reason: ""),
        ]
        return DetailInput(accountId: me, rows: rows, samples: samples, rolls: rolls, activeNow: true,
                           trackingStartedAt: days[6].start.addingTimeInterval(9 * 3600),
                           firstLedgerDay: days[6].key, table: table)
    }
}

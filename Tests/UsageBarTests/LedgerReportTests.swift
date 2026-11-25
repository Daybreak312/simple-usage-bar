import Foundation
import XCTest
@testable import usagebar

final class LedgerReportTests: XCTestCase {
    let table = ModelPriceTable(prices: [
        "claude-big": ModelPrice(input: 1e-5, output: 0, cacheWrite5m: 0, cacheWrite1h: nil, cacheRead: 0),
        "claude-small": ModelPrice(input: 1e-6, output: 0, cacheWrite5m: 0, cacheWrite1h: nil, cacheRead: 0),
    ])

    func row(_ day: String, _ model: String, input: Int64) -> LedgerRow {
        var t = TokenCounts()
        t.input = input
        t.messages = 1
        return LedgerRow(day: day, model: model, fast: false, us: false, tokens: t)
    }

    func testGroupsByDaySortedAndPricesModels() {
        let rows = [
            row("2026-11-19", "claude-small", input: 1_000_000),  // $1
            row("2026-11-18", "claude-big", input: 1_000_000),    // $10
            row("2026-11-19", "claude-mystery", input: 5),        // unpriced
            row("2026-11-19", "claude-small", input: 100_000),    // $0.1
        ]
        let r = LedgerReport(rows: rows, table: table)
        XCTAssertEqual(r.days.map(\.day), ["2026-11-18", "2026-11-19"])
        XCTAssertEqual(r.days[0].total.cost, 10, accuracy: 1e-9)
        XCTAssertEqual(r.days[1].total.cost, 1.1, accuracy: 1e-9)
        XCTAssertEqual(r.days[1].total.unpricedModels, ["claude-mystery"])
        XCTAssertTrue(r.days[0].total.isFullyPriced)
        XCTAssertEqual(r.days[1].models.map(\.model), ["claude-small", "claude-mystery"])
        XCTAssertEqual(r.total.cost, 11.1, accuracy: 1e-9)
        XCTAssertEqual(r.total.unpricedModels, ["claude-mystery"])
        XCTAssertFalse(r.total.isFullyPriced)
        XCTAssertEqual(r.total.tokens.input, 2_100_005)  // unpriced tokens still counted
        XCTAssertEqual(r.models.map(\.model), ["claude-big", "claude-small", "claude-mystery"])
        XCTAssertEqual(r.models[0].costShare!, 10.0 / 11.1, accuracy: 1e-9)
        XCTAssertNil(r.models[2].costShare)
        XCTAssertEqual(LedgerFormat.cost(r.total), "$11.10 + 단가 미상")
        XCTAssertEqual(LedgerFormat.cost(r.models[2].total), "단가 미상")
    }

    func testEmptyReport() {
        let r = LedgerReport(rows: [], table: table)
        XCTAssertTrue(r.days.isEmpty)
        XCTAssertTrue(r.models.isEmpty)
        XCTAssertEqual(r.total, LedgerReport.Total())
        XCTAssertEqual(LedgerFormat.cost(r.total), "$0.00")
    }

    func testFormatting() {
        XCTAssertEqual(LedgerFormat.count(1_234_567), "1,234,567")
        XCTAssertEqual(LedgerFormat.dollars(1234.5), "$1,234.50")
        XCTAssertEqual(LedgerFormat.dollars(0.001), "<$0.01")
        XCTAssertEqual(LedgerFormat.dollars(0), "$0.00")
        XCTAssertEqual(LedgerFormat.short(1_500), "1.5K")
        XCTAssertEqual(LedgerFormat.short(2_500_000), "2.5M")
        XCTAssertEqual(LedgerFormat.short(999), "999")
    }

    // MARK: - usagebar stats

    func testStatsOptionParsing() {
        XCTAssertEqual(StatsCommand.parse(["usagebar", "stats"]), .ok(.init()))
        var o = StatsCommand.Options()
        o.days = 30
        o.json = true
        o.refresh = true
        XCTAssertEqual(StatsCommand.parse(["usagebar", "stats", "--days", "30", "--json", "--refresh"]), .ok(o))
        o.days = 400
        XCTAssertEqual(StatsCommand.parse(["usagebar", "stats", "--days", "400", "--json", "--refresh"]), .ok(o))
        guard case .bad = StatsCommand.parse(["usagebar", "stats", "--days", "0"]) else { return XCTFail() }
        guard case .bad = StatsCommand.parse(["usagebar", "stats", "--days", "401"]) else { return XCTFail() }
        guard case .bad = StatsCommand.parse(["usagebar", "stats", "--days"]) else { return XCTFail() }
        guard case .bad = StatsCommand.parse(["usagebar", "stats", "--nope"]) else { return XCTFail() }
        // 계정 구분이 없으므로 --account도 없다.
        guard case .bad = StatsCommand.parse(["usagebar", "stats", "--account", "me@x.com"]) else { return XCTFail() }
    }

    func context(started: Date? = Date(timeIntervalSince1970: 1_795_000_000)) -> StatsCommand.Context {
        StatsCommand.Context(fromDay: "2026-11-13", toDay: "2026-11-19", days: 7, trackingStartedAt: started,
                             timeZone: TimeZone(identifier: "Asia/Seoul")!, priceSource: "테스트 단가")
    }

    func testStatsTextAndJSON() throws {
        let rows = [row("2026-11-18", "claude-small", input: 2_000_000),
                    row("2026-11-19", "claude-big", input: 1_000_000), row("2026-11-19", "claude-mystery", input: 7)]
        let report = LedgerReport(rows: rows, table: table)
        let ctx = context()
        let text = StatsCommand.text(report, ctx)
        XCTAssertTrue(text.contains("이 맥 전체"))
        XCTAssertTrue(text.contains("집계 시작 2026-11-18 "), text)
        XCTAssertTrue(text.contains("API 환산 비용"))
        XCTAssertTrue(text.contains("구독 청구액이 아닙니다"))
        XCTAssertTrue(text.contains("2026-11-18"))
        XCTAssertTrue(text.contains("합계"))
        XCTAssertTrue(text.contains("3,000,007"))
        XCTAssertTrue(text.contains("단가 미상 모델 (토큰만 집계, 금액에서 빠짐): claude-mystery"))
        XCTAssertFalse(text.contains("요금"))

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(StatsCommand.json(report, ctx).utf8)) as? [String: Any])
        XCTAssertEqual(json["costLabel"] as? String, "API 환산 비용")
        XCTAssertEqual(json["scope"] as? String, "mac")
        XCTAssertNil(json["accounts"])
        XCTAssertNotNil(json["trackingStartedAt"] as? String)
        let totals = try XCTUnwrap(json["totals"] as? [String: Any])
        XCTAssertEqual(totals["apiCostUSD"] as? Double ?? -1, 12, accuracy: 1e-9)
        XCTAssertEqual(totals["costComplete"] as? Bool, false)
        XCTAssertEqual(totals["unpricedModels"] as? [String], ["claude-mystery"])
        let daily = try XCTUnwrap(json["daily"] as? [[String: Any]])
        XCTAssertEqual(daily.map { $0["date"] as? String }, ["2026-11-18", "2026-11-19"])
        let models = try XCTUnwrap(json["models"] as? [[String: Any]])
        XCTAssertEqual(models.map { $0["model"] as? String }, ["claude-big", "claude-small", "claude-mystery"])
    }

    func testStatsTextBeforeTrackingStarted() {
        let text = StatsCommand.text(LedgerReport(rows: [], table: table), context(started: nil))
        XCTAssertTrue(text.contains("아직 집계 기록이 없습니다"))
        let empty = StatsCommand.text(LedgerReport(rows: [], table: table), context())
        XCTAssertTrue(empty.contains("이 기간에 집계된 기록이 없습니다"))
    }

    func testStatsCommandEndToEnd() {
        let root = makeTempDir()
        let ledger = UsageLedger(directory: root.appendingPathComponent("claude"),
                                 projectsRoot: root.appendingPathComponent("projects"),
                                 prices: { ModelPriceSource.bundledTable })
        let prices = ModelPriceSource(directory: root)
        // 장부가 없을 때 읽기만 하면 만들지 않는다.
        XCTAssertEqual(StatsCommand.run(["usagebar", "stats"], ledger: ledger, prices: prices), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledger.dbURL.path))
        XCTAssertEqual(StatsCommand.run(["usagebar", "stats", "--refresh", "--json"], ledger: ledger, prices: prices), 0)
        XCTAssertNotNil(ledger.trackingStartedAt())
        XCTAssertEqual(StatsCommand.run(["usagebar", "stats", "--days", "nope"], ledger: ledger, prices: prices), 1)
    }
}

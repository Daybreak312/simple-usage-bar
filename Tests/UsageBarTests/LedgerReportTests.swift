import Foundation
import XCTest
@testable import usagebar

final class LedgerReportTests: XCTestCase {
    let a = UUID()
    let b = UUID()
    let table = ModelPriceTable(prices: [
        "claude-big": ModelPrice(input: 1e-5, output: 0, cacheWrite5m: 0, cacheWrite1h: nil, cacheRead: 0),
        "claude-small": ModelPrice(input: 1e-6, output: 0, cacheWrite5m: 0, cacheWrite1h: nil, cacheRead: 0),
    ])

    func row(_ account: UUID, _ day: String, _ model: String, input: Int64) -> LedgerRow {
        var t = TokenCounts()
        t.input = input
        t.messages = 1
        return LedgerRow(accountId: account, day: day, model: model, fast: false, us: false, tokens: t)
    }

    func testGroupsByAccountAndDaySortedAndPricesModels() {
        let rows = [
            row(a, "2026-11-19", "claude-small", input: 1_000_000),  // $1
            row(a, "2026-11-18", "claude-big", input: 1_000_000),    // $10
            row(a, "2026-11-19", "claude-mystery", input: 5),        // unpriced
            row(b, "2026-11-19", "claude-small", input: 100_000),    // $0.1
        ]
        let r = LedgerReport(rows: rows, table: table)
        XCTAssertEqual(r.accounts.map(\.accountId), [a, b])  // cost desc
        let accountA = r.accounts[0]
        XCTAssertEqual(accountA.days.map(\.day), ["2026-11-18", "2026-11-19"])
        XCTAssertEqual(accountA.total.cost, 11, accuracy: 1e-9)
        XCTAssertEqual(accountA.total.unpricedModels, ["claude-mystery"])
        XCTAssertFalse(accountA.total.isFullyPriced)
        XCTAssertEqual(accountA.total.tokens.input, 2_000_005)  // unpriced tokens still counted
        XCTAssertEqual(accountA.models.map(\.model), ["claude-big", "claude-small", "claude-mystery"])
        XCTAssertEqual(accountA.models[0].costShare!, 10.0 / 11.0, accuracy: 1e-9)
        XCTAssertNil(accountA.models[2].costShare)
        XCTAssertEqual(r.total.cost, 11.1, accuracy: 1e-9)
        XCTAssertEqual(LedgerFormat.cost(accountA.total), "$11.00 + 단가 미상")
        XCTAssertEqual(LedgerFormat.cost(accountA.models[2].total), "단가 미상")
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
        o.account = "me@x.com"
        o.json = true
        o.refresh = true
        XCTAssertEqual(StatsCommand.parse(["usagebar", "stats", "--days", "30", "--account", "me@x.com", "--json", "--refresh"]), .ok(o))
        guard case .bad = StatsCommand.parse(["usagebar", "stats", "--days", "0"]) else { return XCTFail() }
        guard case .bad = StatsCommand.parse(["usagebar", "stats", "--days"]) else { return XCTFail() }
        guard case .bad = StatsCommand.parse(["usagebar", "stats", "--nope"]) else { return XCTFail() }
    }

    func testStatsTextAndJSON() throws {
        let rows = [row(a, "2026-11-19", "claude-big", input: 1_000_000), row(a, "2026-11-19", "claude-mystery", input: 7)]
        let report = LedgerReport(rows: rows, table: table)
        let ctx = StatsCommand.Context(
            fromDay: "2026-11-13", toDay: "2026-11-19", days: 7,
            trackingStartedAt: Date(timeIntervalSince1970: 1_795_000_000),
            timeZone: TimeZone(identifier: "Asia/Seoul")!, priceSource: "테스트 단가", labels: [a: "me@x.com"])
        let text = StatsCommand.text(report, ctx)
        XCTAssertTrue(text.contains("API 환산 비용"))
        XCTAssertTrue(text.contains("구독 청구액이 아닙니다"))
        XCTAssertTrue(text.contains("me@x.com"))
        XCTAssertTrue(text.contains("1,000,007"))
        XCTAssertTrue(text.contains("단가 미상 모델 (토큰만 집계, 금액에서 빠짐): claude-mystery"))
        XCTAssertFalse(text.contains("요금"))

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(StatsCommand.json(report, ctx).utf8)) as? [String: Any])
        XCTAssertEqual(json["costLabel"] as? String, "API 환산 비용")
        let totals = try XCTUnwrap(json["totals"] as? [String: Any])
        XCTAssertEqual(totals["apiCostUSD"] as? Double ?? -1, 10, accuracy: 1e-9)
        XCTAssertEqual(totals["costComplete"] as? Bool, false)
        XCTAssertEqual(totals["unpricedModels"] as? [String], ["claude-mystery"])
        let accounts = try XCTUnwrap(json["accounts"] as? [[String: Any]])
        XCTAssertEqual(accounts.first?["label"] as? String, "me@x.com")
        XCTAssertEqual((accounts.first?["days"] as? [[String: Any]])?.first?["date"] as? String, "2026-11-19")
    }

    func testStatsCommandEndToEndWithEmptyLedger() {
        let root = makeTempDir()
        let store = AccountStore(directory: root)
        let ledger = UsageLedger(directory: root.appendingPathComponent("claude"),
                                 projectsRoot: root.appendingPathComponent("projects"))
        let code = StatsCommand.run(["usagebar", "stats", "--refresh", "--json"], store: store, ledger: ledger,
                                    prices: ModelPriceSource(directory: root))
        XCTAssertEqual(code, 0)
        XCTAssertEqual(StatsCommand.run(["usagebar", "stats", "--account", "nobody@x.com"], store: store,
                                        ledger: ledger, prices: ModelPriceSource(directory: root)), 1)
    }
}

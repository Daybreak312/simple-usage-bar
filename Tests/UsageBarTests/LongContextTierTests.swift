import Foundation
import XCTest
@testable import usagebar

/// PRD Phase 5 — long-context tier prices (`*_above_<N>k_tokens`), judged per
/// request on the prompt size, applied to every token kind of that request.
/// Fixed values: CLI `result.modelUsage["claude-haiku-5-5"].costUSD`
/// (2026-11-19, claude 2.1.293).
final class LongContextTierTests: XCTestCase {
    let bundled = ModelPriceSource.bundledTable

    func counts(input: Int64 = 0, output: Int64 = 0, c5: Int64 = 0, c1: Int64 = 0, read: Int64 = 0) -> TokenCounts {
        TokenCounts(input: input, output: output, cacheWrite5m: c5, cacheWrite1h: c1, cacheRead: read,
                    webSearches: 0, messages: 1)
    }

    /// T1: 입력 2 / 출력 4 / 캐시 읽기 10,480 / 1시간 캐시 쓰기 52,352
    var t1: TokenCounts { counts(input: 2, output: 4, c1: 52_352, read: 10_480) }
    /// T2: 입력 2 / 출력 4 / 캐시 읽기 13,049 / 1시간 캐시 쓰기 329,604
    var t2: TokenCounts { counts(input: 2, output: 4, c1: 329_604, read: 13_049) }

    func haiku55() throws -> ModelPrice { try XCTUnwrap(bundled.lookup("claude-haiku-5-5")?.price) }

    /// Judge and price one request the way the ledger does.
    func requestCost(_ p: ModelPrice, _ t: TokenCounts, fast: Bool = false) -> Double? {
        p.cost(t, fast: fast, tier: p.tierThreshold(promptTokens: t.promptTokens))
    }

    // MARK: - Parsing

    func testBundledHaiku55TierMatchesLiteLLM() throws {
        let p = try haiku55()
        XCTAssertEqual(p.tiers.count, 1)
        let tier = try XCTUnwrap(p.tiers.first)
        XCTAssertEqual(tier.threshold, 100_000)
        XCTAssertEqual(tier.input!, 5e-7, accuracy: 1e-18)
        XCTAssertEqual(tier.output!, 2.5e-6, accuracy: 1e-18)
        XCTAssertEqual(tier.cacheWrite5m!, 6.25e-7, accuracy: 1e-18)
        XCTAssertEqual(tier.cacheWrite1h!, 1e-6, accuracy: 1e-18)
        XCTAssertEqual(tier.cacheRead!, 5e-8, accuracy: 1e-18)
        // Models without tier keys keep the old behaviour.
        XCTAssertEqual(bundled.lookup("claude-haiku-4-5")?.price.tiers, [])
        XCTAssertEqual(bundled.lookup("claude-opus-5-5")?.price.tiers, [])
    }

    func testTierKeyPattern() {
        XCTAssertEqual(ModelPrice.parseTierKey("input_cost_per_token_above_100k_tokens")?.base, "input_cost_per_token")
        XCTAssertEqual(ModelPrice.parseTierKey("input_cost_per_token_above_100k_tokens")?.threshold, 100_000)
        XCTAssertEqual(ModelPrice.parseTierKey("cache_creation_input_token_cost_above_1hr_above_200k_tokens")?.base,
                       "cache_creation_input_token_cost_above_1hr")
        XCTAssertEqual(ModelPrice.parseTierKey("cache_creation_input_token_cost_above_200k_tokens")?.base,
                       "cache_creation_input_token_cost")
        XCTAssertNil(ModelPrice.parseTierKey("input_cost_per_token_above_100k_tokens_batches"))
        XCTAssertNil(ModelPrice.parseTierKey("cache_creation_input_token_cost_above_1hr"))
        XCTAssertNil(ModelPrice.parseTierKey("input_cost_per_token_above_0k_tokens"))
        XCTAssertNil(ModelPrice.parseTierKey("output_cost_per_token_batches"))
        XCTAssertNil(ModelPrice.parseTierKey("input_cost_per_token"))
    }

    func testSubsetKeepsTierKeysButNotBatches() throws {
        let full = Data(#"""
        {"claude-x":{"input_cost_per_token":1e-6,"output_cost_per_token":2e-6,
          "input_cost_per_token_above_100k_tokens":2e-6,
          "cache_creation_input_token_cost_above_1hr_above_100k_tokens":3e-6,
          "input_cost_per_token_above_100k_tokens_batches":1e-6,
          "input_cost_per_token_batches":5e-7}}
        """#.utf8)
        let sub = try JSONSerialization.jsonObject(with: ModelPriceTable.claudeSubset(full)) as? [String: [String: Any]]
        XCTAssertEqual(sub?["claude-x"]?.keys.sorted(), [
            "cache_creation_input_token_cost_above_1hr_above_100k_tokens",
            "input_cost_per_token", "input_cost_per_token_above_100k_tokens", "output_cost_per_token",
        ])
        // The cached copy parses back to the same tiers.
        let p = try XCTUnwrap(ModelPriceTable(litellmJSON: ModelPriceTable.claudeSubset(full)).prices["claude-x"])
        XCTAssertEqual(p.tiers, [ModelPrice.LongContextTier(threshold: 100_000, input: 2e-6, cacheWrite1h: 3e-6)])
    }

    // MARK: - Fixed CLI values

    func testT1BelowThresholdIsBasePrice() throws {
        let p = try haiku55()
        XCTAssertEqual(t1.promptTokens, 62_834)
        XCTAssertEqual(p.tierThreshold(promptTokens: t1.promptTokens), 0)
        XCTAssertEqual(requestCost(p, t1)!, 0.0105774, accuracy: 1e-9)
    }

    func testT2AboveThresholdPricesEveryKindAtTier() throws {
        let p = try haiku55()
        XCTAssertEqual(t2.promptTokens, 342_655)
        XCTAssertEqual(p.tierThreshold(promptTokens: t2.promptTokens), 100_000)
        XCTAssertEqual(requestCost(p, t2)!, 0.33026745, accuracy: 1e-9)
        // Not the "only the part above the threshold" rule (ccusage) — that
        // can't produce the CLI value.
        XCTAssertNotEqual(p.cost(t2)!, 0.33026745, accuracy: 1e-3)
    }

    func testThresholdIsStrictlyAbove() throws {
        let p = try haiku55()
        let at = counts(input: 100_000, output: 10)
        let over = counts(input: 100_001, output: 10)
        XCTAssertEqual(p.tierThreshold(promptTokens: at.promptTokens), 0)
        XCTAssertEqual(requestCost(p, at)!, 100_000 * 1e-7 + 10 * 5e-7, accuracy: 1e-9)
        XCTAssertEqual(p.tierThreshold(promptTokens: over.promptTokens), 100_000)
        XCTAssertEqual(requestCost(p, over)!, 100_001 * 5e-7 + 10 * 2.5e-6, accuracy: 1e-9)
        // Output tokens don't count toward the prompt.
        XCTAssertEqual(counts(input: 99_999, output: 50_000).promptTokens, 99_999)
    }

    func testHaiku45WithoutTiersUnchangedF9() throws {
        let p = try XCTUnwrap(bundled.lookup("claude-haiku-4-5")?.price)
        let f9 = counts(input: 10, output: 891, c1: 44_247, read: 17_957)
        XCTAssertEqual(requestCost(p, f9)!, 0.0947547, accuracy: 1e-9)
        // Huge prompt, still no tier.
        let big = counts(input: 500_000)
        XCTAssertEqual(p.tierThreshold(promptTokens: big.promptTokens), 0)
        XCTAssertEqual(p.cost(big, tier: 100_000)!, 500_000 * 1e-6, accuracy: 1e-9)
    }

    // MARK: - Fallbacks / multiple tiers / multipliers

    func testPartialTierFallsBackPerKind() {
        let base = ModelPrice(input: 1e-6, output: 2e-6, cacheWrite5m: 3e-6, cacheWrite1h: 4e-6, cacheRead: 5e-7)
        let t = counts(input: 1, output: 1, c5: 1, c1: 1, read: 1)
        // Only input + 5-minute cache tier: 1 h cache → tier 5 m; others → base.
        var p = base
        p.tiers = [.init(threshold: 100_000, input: 1e-5, cacheWrite5m: 3e-5)]
        XCTAssertEqual(p.cost(t, tier: 100_000)!, 1e-5 + 2e-6 + 3e-5 + 3e-5 + 5e-7, accuracy: 1e-15)
        // No cache tier at all: 1 h cache → base 1 h.
        p.tiers = [.init(threshold: 100_000, output: 7e-6)]
        XCTAssertEqual(p.cost(t, tier: 100_000)!, 1e-6 + 7e-6 + 3e-6 + 4e-6 + 5e-7, accuracy: 1e-15)
        // Tier 1 h price present wins over tier 5 m.
        p.tiers = [.init(threshold: 100_000, cacheWrite5m: 3e-5, cacheWrite1h: 6e-5)]
        XCTAssertEqual(p.cost(t, tier: 100_000)!, 1e-6 + 2e-6 + 3e-5 + 6e-5 + 5e-7, accuracy: 1e-15)
    }

    func testMultipleThresholdsPickLargestBelowPrompt() throws {
        let e: [String: Any] = [
            "input_cost_per_token": 1e-6, "output_cost_per_token": 2e-6,
            "input_cost_per_token_above_200k_tokens": 3e-6,
            "input_cost_per_token_above_100k_tokens": 2e-6,
        ]
        let p = try XCTUnwrap(ModelPrice(litellm: e))
        XCTAssertEqual(p.tiers.map(\.threshold), [100_000, 200_000])
        XCTAssertEqual(p.tierThreshold(promptTokens: 100_000), 0)
        XCTAssertEqual(p.tierThreshold(promptTokens: 150_000), 100_000)
        XCTAssertEqual(p.tierThreshold(promptTokens: 200_000), 100_000)
        XCTAssertEqual(p.tierThreshold(promptTokens: 200_001), 200_000)
        XCTAssertEqual(p.cost(counts(input: 250_000), tier: 200_000)!, 250_000 * 3e-6, accuracy: 1e-9)
        // A stored threshold the table no longer has → the next lower tier.
        XCTAssertEqual(p.cost(counts(input: 160_000), tier: 150_000)!, 160_000 * 2e-6, accuracy: 1e-9)
        XCTAssertEqual(p.cost(counts(input: 60_000), tier: 50_000)!, 60_000 * 1e-6, accuracy: 1e-9)
    }

    func testLongContextTimesFastMultiplier() throws {
        var p = try haiku55()
        p.multipliers["fast"] = 2
        XCTAssertEqual(requestCost(p, t2, fast: true)!, 0.33026745 * 2, accuracy: 1e-9)
        XCTAssertEqual(requestCost(p, t1, fast: true)!, 0.0105774 * 2, accuracy: 1e-9)
    }

    // MARK: - Report

    func testMixedDayReportSumsPerRequestCosts() throws {
        let me = UUID()
        var fastHaiku = try haiku55()
        fastHaiku.multipliers["fast"] = 2
        let table = ModelPriceTable(prices: ["claude-haiku-5-5": try haiku55(), "claude-fast": fastHaiku])
        let rows = [
            LedgerRow(accountId: me, day: "2026-11-19", model: "claude-haiku-5-5", fast: false, us: false, tier: 0, tokens: t1),
            LedgerRow(accountId: me, day: "2026-11-19", model: "claude-haiku-5-5", fast: false, us: false, tier: 100_000, tokens: t2),
            LedgerRow(accountId: me, day: "2026-11-19", model: "claude-fast", fast: true, us: false, tier: 100_000, tokens: t2),
        ]
        let r = LedgerReport(rows: rows, table: table)
        let day = try XCTUnwrap(r.accounts.first?.days.first)
        XCTAssertEqual(r.total.cost, 0.0105774 + 0.33026745 + 0.33026745 * 2, accuracy: 1e-9)
        XCTAssertEqual(r.total.tokens, t1 + t2 + t2)
        XCTAssertEqual(r.total.longContextTokens, t2 + t2)
        let haikuLine = try XCTUnwrap(day.models.first { $0.model == "claude-haiku-5-5" })
        XCTAssertEqual(haikuLine.total.cost, 0.0105774 + 0.33026745, accuracy: 1e-9)
        XCTAssertEqual(haikuLine.total.tokens, t1 + t2)
    }

    func testStatsJSONSeparatesLongContextTokens() throws {
        let me = UUID()
        let rows = [
            LedgerRow(accountId: me, day: "2026-11-19", model: "claude-haiku-5-5", fast: false, us: false, tier: 0, tokens: t1),
            LedgerRow(accountId: me, day: "2026-11-19", model: "claude-haiku-5-5", fast: false, us: false, tier: 100_000, tokens: t2),
        ]
        let report = LedgerReport(rows: rows, table: bundled)
        let ctx = StatsCommand.Context(fromDay: "2026-11-19", toDay: "2026-11-19", days: 1, trackingStartedAt: Date(timeIntervalSince1970: 1_795_000_000),
                                       timeZone: TimeZone(identifier: "Asia/Seoul")!, priceSource: "번들", labels: [me: "me@x.com"])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(StatsCommand.json(report, ctx).utf8)) as? [String: Any])
        let totals = try XCTUnwrap(json["totals"] as? [String: Any])
        XCTAssertEqual(totals["totalTokens"] as? Int64, (t1 + t2).totalTokens)
        XCTAssertEqual(totals["longContextTokens"] as? Int64, t2.totalTokens)
        XCTAssertEqual(totals["longContextMessages"] as? Int64, 1)
        XCTAssertEqual(totals["apiCostUSD"] as? Double ?? -1, 0.0105774 + 0.33026745, accuracy: 1e-9)
        // Text view: one combined line per model.
        let text = StatsCommand.text(report, ctx)
        XCTAssertTrue(text.contains(LedgerFormat.count((t1 + t2).totalTokens)), text)
        XCTAssertTrue(text.contains("$0.34"), text)
        XCTAssertTrue(text.contains("장문 구간(할증 단가) 응답 1건 · 토큰 \(LedgerFormat.count(t2.totalTokens))"), text)
    }
}

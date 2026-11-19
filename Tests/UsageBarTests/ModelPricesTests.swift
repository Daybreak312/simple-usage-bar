import Foundation
import XCTest
@testable import usagebar

final class ModelPricesTests: XCTestCase {
    let bundled = ModelPriceSource.bundledTable

    /// F9: CLI `modelUsage.claude-haiku-4-5.costUSD` 0.0947547 for this response.
    func testF9HaikuCostMatchesCLI() throws {
        var t = TokenCounts()
        t.input = 10
        t.output = 891
        t.cacheRead = 17_957
        t.cacheWrite1h = 44_247
        let price = try XCTUnwrap(bundled.lookup("claude-haiku-4-5")?.price)
        let cost = try XCTUnwrap(price.cost(t))
        XCTAssertEqual(cost, 0.0947547, accuracy: 1e-9)
        // The dated id logged by Claude Code prices the same.
        let dated = try XCTUnwrap(bundled.lookup("claude-haiku-4-5-20251001")?.price.cost(t))
        XCTAssertEqual(dated, 0.0947547, accuracy: 1e-9)
    }

    func testLookupOrderExactThenUndatedThenAnthropicPrefix() {
        let p1 = ModelPrice(input: 1, output: 1, cacheWrite5m: 1, cacheWrite1h: nil, cacheRead: 1)
        let p2 = ModelPrice(input: 2, output: 2, cacheWrite5m: 2, cacheWrite1h: nil, cacheRead: 2)
        let p3 = ModelPrice(input: 3, output: 3, cacheWrite5m: 3, cacheWrite1h: nil, cacheRead: 3)
        let table = ModelPriceTable(prices: [
            "claude-a-20250101": p1, "claude-a": p2, "anthropic/claude-b": p3,
        ])
        XCTAssertEqual(table.lookup("claude-a-20250101")?.key, "claude-a-20250101")
        XCTAssertEqual(table.lookup("claude-a-20990101")?.key, "claude-a")
        XCTAssertEqual(table.lookup("claude-b")?.key, "anthropic/claude-b")
        XCTAssertEqual(table.lookup("claude-b-20250101")?.key, "anthropic/claude-b")
        XCTAssertNil(table.lookup("claude-c"))
        XCTAssertEqual(ModelPriceTable.stripDateSuffix("claude-opus-5-5-20261101"), "claude-opus-5-5")
        XCTAssertEqual(ModelPriceTable.stripDateSuffix("claude-opus-5-5"), "claude-opus-5-5")
    }

    func testRealModelsArePriced() {
        for m in ["claude-opus-5-5", "claude-fable-5-1", "claude-sonnet-5", "claude-haiku-4-5",
                  "claude-haiku-4-5-20251001", "claude-opus-4-8", "claude-sonnet-5-5"] {
            XCTAssertNotNil(bundled.lookup(m), m)
        }
    }

    func testFastAndUSMultipliers() throws {
        var t = TokenCounts()
        t.input = 1_000_000  // opus-5-5: $4 / MTok
        let opus = try XCTUnwrap(bundled.lookup("claude-opus-5-5")?.price)
        XCTAssertEqual(opus.cost(t)!, 4, accuracy: 1e-9)
        XCTAssertEqual(opus.cost(t, fast: true)!, 8, accuracy: 1e-9)
        XCTAssertEqual(opus.cost(t, us: true)!, 4.4, accuracy: 1e-9)
        XCTAssertEqual(opus.cost(t, fast: true, us: true)!, 8.8, accuracy: 1e-9)
        // fable-5-1 has no `fast` entry → multiplier not applied.
        let fable = try XCTUnwrap(bundled.lookup("claude-fable-5-1")?.price)
        XCTAssertEqual(fable.cost(t, fast: true)!, fable.cost(t)!, accuracy: 1e-12)
    }

    func testCacheAndWebSearchPricing() throws {
        let opus = try XCTUnwrap(bundled.lookup("claude-opus-5-5")?.price)
        var t = TokenCounts()
        t.cacheWrite5m = 1_000_000  // $5
        t.cacheWrite1h = 1_000_000  // $8
        t.cacheRead = 1_000_000     // $0.2
        t.webSearches = 3           // 3 × $0.01
        XCTAssertEqual(opus.cost(t)!, 5 + 8 + 0.2 + 0.03, accuracy: 1e-9)

        // No 1h price → the 5m price; no web-search price → 0.
        let bare = ModelPrice(input: 0, output: 0, cacheWrite5m: 2e-6, cacheWrite1h: nil, cacheRead: 0)
        var u = TokenCounts()
        u.cacheWrite1h = 1_000_000
        u.webSearches = 5
        XCTAssertEqual(bare.cost(u)!, 2, accuracy: 1e-9)
    }

    func testMissingCachePriceIsUnknownNotZero() {
        let noCache = ModelPrice(input: 1e-6, output: 1e-6, cacheWrite5m: nil, cacheWrite1h: nil, cacheRead: nil)
        var t = TokenCounts()
        t.input = 100
        XCTAssertNotNil(noCache.cost(t))  // no cache tokens → fine
        t.cacheRead = 1
        XCTAssertNil(noCache.cost(t))
    }

    func testParseRejectsTablesWithoutClaude() {
        XCTAssertThrowsError(try ModelPriceTable(litellmJSON: Data(#"{"gpt-x":{"input_cost_per_token":1,"output_cost_per_token":1}}"#.utf8)))
        XCTAssertThrowsError(try ModelPriceTable(litellmJSON: Data("[1]".utf8)))
        XCTAssertThrowsError(try ModelPriceTable(litellmJSON: Data("{trunc".utf8)))
        // `-latest` aliases without prices are skipped, not fatal.
        let t = try? ModelPriceTable(litellmJSON: Data(#"{"claude-x-latest":{"mode":"chat"},"claude-x":{"input_cost_per_token":1e-6,"output_cost_per_token":2e-6}}"#.utf8))
        XCTAssertEqual(t?.prices.keys.sorted(), ["claude-x"])
    }

    /// The bundled copy follows the subset rule (re-subsetting changes nothing).
    func testBundledCopyIsAClaudeSubsetFixedPoint() throws {
        XCTAssertFalse(bundled.prices.isEmpty)
        let again = try ModelPriceTable(litellmJSON: ModelPriceTable.claudeSubset(Data(BundledPrices.json.utf8)))
        XCTAssertEqual(again.prices, bundled.prices)
        XCTAssertTrue(bundled.prices.keys.allSatisfy(ModelPriceTable.isClaudeKey))
        XCTAssertEqual(BundledPrices.sourceURL, ModelPriceSource.remoteURL.absoluteString)
    }

    func testSubsetDropsForeignEntriesAndFields() throws {
        let full = Data(#"""
        {"sample_spec":{"input_cost_per_token":0},
         "gpt-5":{"input_cost_per_token":1,"output_cost_per_token":1},
         "bedrock/anthropic.claude-x":{"input_cost_per_token":1,"output_cost_per_token":1},
         "claude-x":{"input_cost_per_token":1e-6,"output_cost_per_token":2e-6,"max_tokens":9,"provider_specific_entry":{"fast":2}}}
        """#.utf8)
        let sub = try JSONSerialization.jsonObject(with: ModelPriceTable.claudeSubset(full)) as? [String: [String: Any]]
        XCTAssertEqual(sub?.keys.sorted(), ["claude-x"])
        XCTAssertEqual(sub?["claude-x"]?.keys.sorted(), ["input_cost_per_token", "output_cost_per_token", "provider_specific_entry"])
    }

    // MARK: - Source (cache → bundled)

    func testSourceFallsBackToBundledThenUsesValidCache() throws {
        let dir = makeTempDir()
        let src = ModelPriceSource(directory: dir)
        guard case .bundled = src.current().origin else { return XCTFail("no cache → bundled") }

        try Data("{garbage".utf8).write(to: src.cacheURL)
        guard case .bundled = src.current().origin else { return XCTFail("broken cache → bundled") }

        try Data(#"{"claude-only":{"input_cost_per_token":1e-6,"output_cost_per_token":1e-6}}"#.utf8).write(to: src.cacheURL)
        // A different mtime forces a re-read even within the same second.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: src.cacheURL.path)
        let (table, origin) = src.current()
        guard case .cache = origin else { return XCTFail("valid cache → cache") }
        XCTAssertEqual(table.prices.keys.sorted(), ["claude-only"])
    }

    func testRefreshWritesSubsetAndFailureKeepsCache() async throws {
        let dir = makeTempDir()
        let src = ModelPriceSource(directory: dir)
        var calls = 0
        src.download = { _ in
            calls += 1
            return (200, Data(#"{"gpt":{"input_cost_per_token":1,"output_cost_per_token":1},"claude-new":{"input_cost_per_token":3e-6,"output_cost_per_token":1e-5,"mode":"chat"}}"#.utf8))
        }
        let now = Date()
        let changed = await src.refreshIfStale(now: now)
        XCTAssertTrue(changed)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(src.current().table.prices.keys.sorted(), ["claude-new"])
        XCTAssertEqual(posixMode(src.cacheURL), 0o600)

        // Fresh cache → no download within a day.
        let again = await src.refreshIfStale(now: now.addingTimeInterval(3600))
        XCTAssertFalse(again)
        XCTAssertEqual(calls, 1)

        // A day later the download fails → cache kept; no retry for 6 h.
        src.download = { _ in calls += 1; return (500, Data()) }
        let failed = await src.refreshIfStale(now: now.addingTimeInterval(86_400 * 2))
        XCTAssertFalse(failed)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(src.current().table.prices.keys.sorted(), ["claude-new"])
        let soon = await src.refreshIfStale(now: now.addingTimeInterval(86_400 * 2 + 600))
        XCTAssertFalse(soon)
        XCTAssertEqual(calls, 2)

        // Garbage body (no Claude entries) is a failure too.
        src.download = { _ in calls += 1; return (200, Data(#"{"gpt":{"input_cost_per_token":1,"output_cost_per_token":1}}"#.utf8)) }
        let garbage = await src.refreshIfStale(now: now.addingTimeInterval(86_400 * 3))
        XCTAssertFalse(garbage)
        XCTAssertEqual(src.current().table.prices.keys.sorted(), ["claude-new"])
    }
}

import Foundation

/// Token counts of one ledger cell (or any sum of cells). Field meanings per
/// the session log's `message.usage` (F7).
struct TokenCounts: Equatable, Codable {
    /// `input_tokens`
    var input: Int64 = 0
    /// `output_tokens`
    var output: Int64 = 0
    /// `cache_creation.ephemeral_5m_input_tokens` (or the whole
    /// `cache_creation_input_tokens` when no breakdown is logged)
    var cacheWrite5m: Int64 = 0
    /// `cache_creation.ephemeral_1h_input_tokens`
    var cacheWrite1h: Int64 = 0
    /// `cache_read_input_tokens`
    var cacheRead: Int64 = 0
    /// `server_tool_use.web_search_requests` (a count, not tokens)
    var webSearches: Int64 = 0
    /// Distinct API responses counted.
    var messages: Int64 = 0

    /// Every token kind (web searches and message count excluded).
    var totalTokens: Int64 { input + output + cacheWrite5m + cacheWrite1h + cacheRead }

    /// Prompt size of one request — what the long-context tier is judged on:
    /// `input_tokens + cache_creation_input_tokens + cache_read_input_tokens`.
    var promptTokens: Int64 { input + cacheWrite5m + cacheWrite1h + cacheRead }

    static func + (a: TokenCounts, b: TokenCounts) -> TokenCounts {
        var s = a
        s += b
        return s
    }

    static func += (a: inout TokenCounts, b: TokenCounts) {
        a.input += b.input
        a.output += b.output
        a.cacheWrite5m += b.cacheWrite5m
        a.cacheWrite1h += b.cacheWrite1h
        a.cacheRead += b.cacheRead
        a.webSearches += b.webSearches
        a.messages += b.messages
    }
}

/// Per-token prices of one model, read from LiteLLM's
/// `model_prices_and_context_window.json` (the table ccusage uses — F8).
struct ModelPrice: Equatable {
    /// `input_cost_per_token`
    var input: Double
    /// `output_cost_per_token`
    var output: Double
    /// `cache_creation_input_token_cost` (5-minute cache write). nil = the
    /// table has no price — cost is unknown if such tokens were used.
    var cacheWrite5m: Double?
    /// `cache_creation_input_token_cost_above_1hr`; nil → the 5-minute price
    var cacheWrite1h: Double?
    /// `cache_read_input_token_cost`. nil = no price (see `cacheWrite5m`).
    var cacheRead: Double?
    /// `search_context_cost_per_query.search_context_size_medium` (per search)
    var webSearch: Double?
    /// `provider_specific_entry` multipliers, e.g. `{"us": 1.1, "fast": 2}`
    var multipliers: [String: Double]
    /// Long-context tiers (`*_above_<N>k_tokens`), threshold ascending. Empty
    /// for models without such keys.
    var tiers: [LongContextTier] = []

    /// Prices of one long-context tier. A request whose prompt
    /// (`TokenCounts.promptTokens`) is **above** `threshold` pays these prices
    /// for **all** its tokens, output included — not only the part above the
    /// threshold (CLI `costUSD` T2 실측). nil = the table has
    /// no tier price for that kind → fallback in `ModelPrice.cost`.
    struct LongContextTier: Equatable {
        var threshold: Int64
        var input: Double?
        var output: Double?
        var cacheWrite5m: Double?
        var cacheWrite1h: Double?
        var cacheRead: Double?
    }

    /// `<base>_above_<N>k_tokens` for the five base fields. `_batches` keys
    /// (batch API prices) don't match (anchored `$`). For
    /// `cache_creation_input_token_cost_above_1hr_above_100k_tokens` the
    /// alternation backtracks to the `…_above_1hr` base.
    static let tierKeyPattern = try! NSRegularExpression(pattern:
        #"^(input_cost_per_token|output_cost_per_token|cache_creation_input_token_cost|cache_creation_input_token_cost_above_1hr|cache_read_input_token_cost)_above_(\d+)k_tokens$"#)

    /// (base field, threshold in tokens) of a tier key; nil for other keys.
    static func parseTierKey(_ key: String) -> (base: String, threshold: Int64)? {
        let ns = key as NSString
        guard let m = tierKeyPattern.firstMatch(in: key, range: NSRange(location: 0, length: ns.length)),
              let k = Int64(ns.substring(with: m.range(at: 2))), k > 0, k < 1_000_000_000 else { return nil }
        return (ns.substring(with: m.range(at: 1)), k * 1000)
    }

    /// nil when the entry has no input/output price (not a priced chat model).
    init?(litellm e: [String: Any]) {
        func num(_ v: Any?) -> Double? {
            guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            let d = n.doubleValue
            return d.isFinite && d >= 0 ? d : nil
        }
        guard let input = num(e["input_cost_per_token"]),
              let output = num(e["output_cost_per_token"]) else { return nil }
        self.input = input
        self.output = output
        cacheWrite5m = num(e["cache_creation_input_token_cost"])
        cacheWrite1h = num(e["cache_creation_input_token_cost_above_1hr"])
        cacheRead = num(e["cache_read_input_token_cost"])
        webSearch = num((e["search_context_cost_per_query"] as? [String: Any])?["search_context_size_medium"])
        var m: [String: Double] = [:]
        for (k, v) in e["provider_specific_entry"] as? [String: Any] ?? [:] {
            if let d = num(v), d > 0 { m[k] = d }
        }
        multipliers = m
        var byThreshold: [Int64: LongContextTier] = [:]
        for (key, value) in e {
            guard let (base, threshold) = Self.parseTierKey(key), let price = num(value) else { continue }
            var t = byThreshold[threshold] ?? LongContextTier(threshold: threshold)
            switch base {
            case "input_cost_per_token": t.input = price
            case "output_cost_per_token": t.output = price
            case "cache_creation_input_token_cost": t.cacheWrite5m = price
            case "cache_creation_input_token_cost_above_1hr": t.cacheWrite1h = price
            default: t.cacheRead = price
            }
            byThreshold[threshold] = t
        }
        tiers = byThreshold.values.sorted { $0.threshold < $1.threshold }
    }

    init(input: Double, output: Double, cacheWrite5m: Double?, cacheWrite1h: Double?,
         cacheRead: Double?, webSearch: Double? = nil, multipliers: [String: Double] = [:],
         tiers: [LongContextTier] = []) {
        self.input = input
        self.output = output
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead
        self.webSearch = webSearch
        self.multipliers = multipliers
        self.tiers = tiers.sorted { $0.threshold < $1.threshold }
    }

    /// Long-context threshold a request with `promptTokens` falls in: the
    /// largest tier threshold the prompt is **above** (`>`), 0 = base prices.
    /// The ledger stores this per request at ingest time (`LedgerRow.tier`).
    func tierThreshold(promptTokens: Int64) -> Int64 {
        tiers.last { promptTokens > $0.threshold }?.threshold ?? 0
    }

    /// The tier priced for a stored threshold: the largest tier at or below
    /// it. Equal to the stored one unless the table changed since ingest
    /// (a removed/raised tier → the next lower one, or base prices).
    func tier(at threshold: Int64) -> LongContextTier? {
        threshold > 0 ? tiers.last { $0.threshold <= threshold } : nil
    }

    /// API 환산 비용 (USD) of `t`. `fast` / `us` = the response's
    /// `usage.speed == "fast"` / `usage.inference_geo == "us"`; each applies
    /// its `provider_specific_entry` multiplier only when the entry has one.
    /// nil when cache tokens were used but the table has no cache price —
    /// an unknown is never passed off as $0. Web searches without a price
    /// cost 0 (PRD: 「없으면 0」).
    ///
    /// `tier` = the long-context threshold the tokens were judged in
    /// (`tierThreshold`, stored per ledger row; 0 = base). Every kind then
    /// uses the tier price; a kind the tier lacks uses its base price, except
    /// the 1-hour cache write: tier 1 h → tier 5 m → base 1 h → base 5 m.
    func cost(_ t: TokenCounts, fast: Bool = false, us: Bool = false, tier threshold: Int64 = 0) -> Double? {
        func part(_ n: Int64, _ price: Double?) -> Double? {
            n == 0 ? 0 : price.map { Double(n) * $0 }
        }
        let tier = tier(at: threshold)
        let w5Price = tier?.cacheWrite5m ?? cacheWrite5m
        let w1Price = tier?.cacheWrite1h ?? tier?.cacheWrite5m ?? cacheWrite1h ?? cacheWrite5m
        guard let w5 = part(t.cacheWrite5m, w5Price),
              let w1 = part(t.cacheWrite1h, w1Price),
              let r = part(t.cacheRead, tier?.cacheRead ?? cacheRead) else { return nil }
        var c = Double(t.input) * (tier?.input ?? input) + Double(t.output) * (tier?.output ?? output)
            + w5 + w1 + r
            + Double(t.webSearches) * (webSearch ?? 0)
        if fast, let m = multipliers["fast"] { c *= m }
        if us, let m = multipliers["us"] { c *= m }
        return c
    }
}

/// A model-name → price map with the lookup rule of the ledger.
struct ModelPriceTable {
    var prices: [String: ModelPrice]

    init(prices: [String: ModelPrice]) {
        self.prices = prices
    }

    /// Parse LiteLLM JSON (full file or the Claude-only subset — same shape).
    /// Throws when it isn't a JSON object or holds no Claude price at all
    /// (a truncated / foreign download must not replace a good table).
    init(litellmJSON data: Data) throws {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageBarError.parse("단가표 최상위가 JSON 객체가 아님")
        }
        var prices: [String: ModelPrice] = [:]
        for (name, value) in obj where Self.isClaudeKey(name) {
            if let e = value as? [String: Any], let p = ModelPrice(litellm: e) { prices[name] = p }
        }
        guard !prices.isEmpty else { throw UsageBarError.parse("단가표에 Claude 모델 단가가 없음") }
        self.prices = prices
    }

    /// Entries kept from the LiteLLM table: direct Anthropic API names
    /// (`claude-…`, `anthropic/claude-…`). Bedrock/Vertex aliases are other
    /// products' names and never appear in Claude Code session logs.
    static func isClaudeKey(_ name: String) -> Bool {
        name.hasPrefix("claude-") || name.hasPrefix("anthropic/claude-")
    }

    /// LiteLLM fields the ledger reads — the only ones kept in the bundled
    /// copy and the downloaded cache, plus the long-context tier keys
    /// (`ModelPrice.parseTierKey`).
    static let keptFields = [
        "input_cost_per_token", "output_cost_per_token",
        "cache_creation_input_token_cost", "cache_creation_input_token_cost_above_1hr",
        "cache_read_input_token_cost", "search_context_cost_per_query", "provider_specific_entry",
    ]

    static func isKeptField(_ key: String) -> Bool {
        keptFields.contains(key) || ModelPrice.parseTierKey(key) != nil
    }

    /// The Claude-only subset of a LiteLLM table (sorted, compact JSON).
    static func claudeSubset(_ data: Data) throws -> Data {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageBarError.parse("단가표 최상위가 JSON 객체가 아님")
        }
        var out: [String: Any] = [:]
        for (name, value) in obj where isClaudeKey(name) {
            guard let e = value as? [String: Any], ModelPrice(litellm: e) != nil else { continue }
            out[name] = e.filter { isKeptField($0.key) }
        }
        guard !out.isEmpty else { throw UsageBarError.parse("단가표에 Claude 모델 단가가 없음") }
        return try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
    }

    /// Exact name → without a date suffix (`-20251001`) → with the
    /// `anthropic/` prefix (both forms). Returns the matched table key too.
    func lookup(_ model: String) -> (key: String, price: ModelPrice)? {
        var candidates = [model]
        let undated = Self.stripDateSuffix(model)
        if undated != model { candidates.append(undated) }
        candidates += candidates.map { "anthropic/\($0)" }
        for c in candidates {
            if let p = prices[c] { return (c, p) }
        }
        return nil
    }

    static func stripDateSuffix(_ model: String) -> String {
        guard let r = model.range(of: #"-\d{8}$"#, options: .regularExpression) else { return model }
        return String(model[..<r.lowerBound])
    }
}

/// Where the price table comes from: the daily download cache
/// (`claude/prices.json`) when it parses, else the copy compiled into the app
/// (`BundledPrices`). The cache is refreshed by the app at most once a day.
final class ModelPriceSource: @unchecked Sendable {  // state behind lock
    static let shared = ModelPriceSource()

    static let remoteURL = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!
    static let refreshInterval: TimeInterval = 86_400
    /// After a failed download, wait this long before trying again.
    static let retryAfterFailure: TimeInterval = 6 * 3600

    enum Origin: Equatable {
        case cache(fetchedAt: Date)
        case bundled(fetchedOn: String)

        var description: String {
            switch self {
            case .cache(let at):
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd HH:mm"
                return "LiteLLM 단가표 (\(f.string(from: at)) 받음)"
            case .bundled(let on):
                return "LiteLLM 단가표 번들 사본 (\(on) 기준)"
            }
        }
    }

    let cacheURL: URL
    private let lock = NSLock()
    private var loaded: (table: ModelPriceTable, origin: Origin, cacheMtime: Date?)?
    private var lastAttempt: Date?

    /// Network seam — tests swap in a recorded body.
    var download: (URL) async throws -> (Int, Data) = { url in
        try await HTTP.request(url.absoluteString, timeout: 60)
    }

    init(directory: URL = AppPaths.claudeDirectory) {
        cacheURL = directory.appendingPathComponent("prices.json")
    }

    /// Current table (re-read when the cache file changed on disk — e.g. the
    /// app refreshed it while a CLI process runs).
    func current() -> (table: ModelPriceTable, origin: Origin) {
        lock.lock()
        defer { lock.unlock() }
        let mtime = Self.mtime(cacheURL)
        if let loaded, loaded.cacheMtime == mtime { return (loaded.table, loaded.origin) }
        if let mtime, let data = try? Data(contentsOf: cacheURL),
           let table = try? ModelPriceTable(litellmJSON: data) {
            loaded = (table, .cache(fetchedAt: mtime), mtime)
        } else {
            loaded = (Self.bundledTable, .bundled(fetchedOn: BundledPrices.fetchedOn), mtime)
        }
        return (loaded!.table, loaded!.origin)
    }

    /// Download a fresh table when the cache is a day old (or missing).
    /// Failures keep whatever was in use. Returns true when the cache changed.
    @discardableResult
    func refreshIfStale(now: Date = Date()) async -> Bool {
        guard claimRefresh(now: now) else { return false }
        do {
            let (status, body) = try await download(Self.remoteURL)
            guard status == 200 else { throw UsageBarError.http(status, "") }
            let subset = try ModelPriceTable.claudeSubset(body)
            try AppPaths.ensurePrivateDirectory(cacheURL.deletingLastPathComponent())
            try subset.write(to: cacheURL, options: .atomic)
            chmod(cacheURL.path, 0o600)
            refreshed()
            return true
        } catch {
            FileHandle.standardError.write(Data("단가표 갱신 실패 (기존 단가 유지): \(error.localizedDescription)\n".utf8))
            return false
        }
    }

    /// Due (cache a day old or missing, no failed attempt in the last 6 h)?
    /// Marks the attempt so concurrent callers don't download twice.
    private func claimRefresh(now: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < Self.retryAfterFailure { return false }
        if let m = Self.mtime(cacheURL), now.timeIntervalSince(m) < Self.refreshInterval { return false }
        lastAttempt = now
        return true
    }

    private func refreshed() {
        lock.lock()
        defer { lock.unlock() }
        loaded = nil
        lastAttempt = nil
    }

    static let bundledTable: ModelPriceTable = {
        // Compiled-in literal produced by scripts/update-bundled-prices.swift;
        // a parse failure here is a build-time bug caught by the tests.
        (try? ModelPriceTable(litellmJSON: Data(BundledPrices.json.utf8))) ?? ModelPriceTable(prices: [:])
    }()

    private static func mtime(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

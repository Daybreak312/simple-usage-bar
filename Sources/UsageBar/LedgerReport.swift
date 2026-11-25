import Foundation

/// Ledger rows priced with a table — the shared arithmetic behind
/// `usagebar stats` and the Mac usage window. Pure (tested).
///
/// 「API 환산 비용」 = what the same tokens would cost at Anthropic API list
/// prices (LiteLLM table). Not what the subscription bills.
struct LedgerReport: Equatable {
    /// Tokens and API 환산 비용 of some slice. `cost` sums the priced part;
    /// `unpricedModels` lists models whose tokens are included but couldn't be
    /// priced — when non-empty the cost is a lower bound, never a hidden $0.
    struct Total: Equatable {
        var tokens = TokenCounts()
        /// The part of `tokens` from long-context requests (priced at a
        /// long-context tier) — already included in `tokens`.
        var longContextTokens = TokenCounts()
        var cost: Double = 0
        var unpricedModels: Set<String> = []

        var isFullyPriced: Bool { unpricedModels.isEmpty }

        static func += (a: inout Total, b: Total) {
            a.tokens += b.tokens
            a.longContextTokens += b.longContextTokens
            a.cost += b.cost
            a.unpricedModels.formUnion(b.unpricedModels)
        }
    }

    struct ModelLine: Equatable {
        var model: String
        var total: Total
        /// Share of the slice's priced cost, 0…1 (nil when unpriced or the
        /// slice cost is 0).
        var costShare: Double?
    }

    struct DayLine: Equatable {
        var day: String
        var total: Total
        var models: [ModelLine]
    }

    /// Days with any usage, ascending.
    var days: [DayLine]
    /// Models over the whole slice.
    var models: [ModelLine]
    var total: Total

    /// Price one row (nil = model not in the table, or cache tokens without a
    /// cache price).
    static func cost(_ row: LedgerRow, table: ModelPriceTable) -> Double? {
        table.lookup(row.model)?.price.cost(row.tokens, fast: row.fast, us: row.us, tier: row.tier)
    }

    static func total(_ row: LedgerRow, table: ModelPriceTable) -> Total {
        var t = Total(tokens: row.tokens, longContextTokens: row.tier > 0 ? row.tokens : TokenCounts())
        if let c = cost(row, table: table) { t.cost = c } else { t.unpricedModels = [row.model] }
        return t
    }

    /// Model lines sorted by cost (desc), unpriced last (by tokens desc).
    static func modelLines(_ rows: [LedgerRow], table: ModelPriceTable) -> [ModelLine] {
        var byModel: [String: Total] = [:]
        for r in rows { byModel[r.model, default: Total()] += total(r, table: table) }
        let pricedSum = byModel.values.filter(\.isFullyPriced).reduce(0) { $0 + $1.cost }
        return byModel.map { model, t in
            ModelLine(model: model, total: t,
                      costShare: t.isFullyPriced && pricedSum > 0 ? t.cost / pricedSum : nil)
        }.sorted { a, b in
            if a.total.isFullyPriced != b.total.isFullyPriced { return a.total.isFullyPriced }
            if a.total.cost != b.total.cost { return a.total.cost > b.total.cost }
            if a.total.tokens.totalTokens != b.total.tokens.totalTokens {
                return a.total.tokens.totalTokens > b.total.tokens.totalTokens
            }
            return a.model < b.model
        }
    }

    /// Group rows per day (ascending) and per model.
    init(rows: [LedgerRow], table: ModelPriceTable) {
        var grand = Total()
        var days: [DayLine] = []
        for (day, dayRows) in Dictionary(grouping: rows, by: \.day) {
            var dayTotal = Total()
            for r in dayRows { dayTotal += Self.total(r, table: table) }
            days.append(DayLine(day: day, total: dayTotal, models: Self.modelLines(dayRows, table: table)))
            grand += dayTotal
        }
        days.sort { $0.day < $1.day }
        self.days = days
        models = Self.modelLines(rows, table: table)
        total = grand
    }
}

/// Number formatting for the ledger (thousands separators, $ with 2 digits).
enum LedgerFormat {
    static func count(_ n: Int64) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }

    /// `$1,234.56`; values under a cent but above 0 show `<$0.01`.
    static func dollars(_ v: Double) -> String {
        if v > 0 && v < 0.005 { return "<$0.01" }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return "$" + (f.string(from: NSNumber(value: v)) ?? String(format: "%.2f", v))
    }

    /// Cost text for a total: `$12.34`, `$12.34 + 단가 미상`, or `단가 미상`.
    static func cost(_ t: LedgerReport.Total) -> String {
        if t.isFullyPriced { return dollars(t.cost) }
        if t.cost > 0 { return "\(dollars(t.cost)) + 단가 미상" }
        return "단가 미상"
    }

    /// 1.2K / 3.4M / 5.6B
    static func short(_ n: Int64) -> String {
        let v = Double(n)
        switch abs(v) {
        case 1e9...: return String(format: "%.1fB", v / 1e9)
        case 1e6...: return String(format: "%.1fM", v / 1e6)
        case 1e3...: return String(format: "%.1fK", v / 1e3)
        default: return String(n)
        }
    }
}

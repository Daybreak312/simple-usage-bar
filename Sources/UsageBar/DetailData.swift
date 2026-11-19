import Foundation

/// Period of the per-account detail window. All charts and totals follow it.
enum DetailPeriod: Int, CaseIterable, Identifiable {
    case week = 7
    case month = 30
    case quarter = 90

    static let `default`: DetailPeriod = .month

    var id: Int { rawValue }
    var days: Int { rawValue }
    var label: String { "\(rawValue)일" }
}

/// One local calendar day of the period: the ledger key and its midnight.
struct DetailDay: Equatable, Hashable {
    /// `yyyy-MM-dd` in the ledger's time zone (matches `LedgerRow.day`).
    var key: String
    /// Local midnight — the x value of the daily bars.
    var start: Date
}

/// Token kinds stacked in the daily token chart (bottom → top).
enum DetailTokenKind: String, CaseIterable, Identifiable {
    case input, output, cacheWrite, cacheRead

    var id: String { rawValue }

    var label: String {
        switch self {
        case .input: return "입력"
        case .output: return "출력"
        case .cacheWrite: return "캐시 쓰기"
        case .cacheRead: return "캐시 읽기"
        }
    }

    /// Cache writes = 5-minute + 1-hour.
    func value(_ t: TokenCounts) -> Int64 {
        switch self {
        case .input: return t.input
        case .output: return t.output
        case .cacheWrite: return t.cacheWrite5m + t.cacheWrite1h
        case .cacheRead: return t.cacheRead
        }
    }

    /// Kinds shown — cache reads (often tens of times the rest) are opt-in.
    static func visible(includeCacheRead: Bool) -> [DetailTokenKind] {
        includeCacheRead ? allCases : allCases.filter { $0 != .cacheRead }
    }
}

/// Raw inputs of one account's detail window, as read from the stores.
struct DetailInput {
    var accountId: UUID
    /// Ledger rows covering the period (other accounts/days are ignored).
    var rows: [LedgerRow]
    /// Utilization history of the account (any range; clipped to the period).
    var samples: [UsageSample]
    /// Active-account roll history (all accounts).
    var rolls: [ActiveAccountStore.RollRecord]
    /// The account is in the active-account file right now.
    var activeNow: Bool
    var trackingStartedAt: Date?
    /// Earliest ledger day of this account (nil = never counted).
    var firstLedgerDay: String?
    var table: ModelPriceTable
}

/// Everything the detail window draws, derived from `DetailInput` — pure, so
/// the period cut, the zero-filled days, the stacking, the cache-read toggle,
/// the model order and the shares are unit-tested apart from the views.
struct DetailData {
    struct DayTotal: Equatable {
        var day: DetailDay
        var total: LedgerReport.Total
        /// Priced cost per model on this day (models of `chartModels` only).
        var modelCosts: [String: Double]
    }

    struct TokenBar: Equatable, Identifiable {
        var day: DetailDay
        var kind: DetailTokenKind
        var value: Int64
        var id: String { "\(day.key)|\(kind.rawValue)" }
    }

    struct CostBar: Equatable, Identifiable {
        var day: DetailDay
        var model: String
        var cost: Double
        var id: String { "\(day.key)|\(model)" }
    }

    struct ModelShare: Equatable {
        var model: String
        var total: LedgerReport.Total
        /// Share of the period's priced cost (nil = unpriced or no cost).
        var costShare: Double?
        /// Share of the period's tokens (nil = no tokens at all).
        var tokenShare: Double?
    }

    struct UsagePoint: Equatable, Identifiable {
        enum Window: String { case sevenDay = "7d", fiveHour = "5h" }
        var ts: Date
        var window: Window
        var percent: Double
        var id: String { "\(window.rawValue)|\(ts.timeIntervalSince1970)" }
    }

    let period: DetailPeriod
    let timeZone: TimeZone
    let days: [DetailDay]
    /// Period bounds: first day's midnight … now.
    let rangeStart: Date
    let rangeEnd: Date
    /// One entry per day of the period, zero-filled.
    let dayTotals: [DayTotal]
    let periodTotal: LedgerReport.Total
    let today: LedgerReport.Total
    /// Cost desc, unpriced last (`LedgerReport.modelLines` order).
    let models: [ModelShare]
    /// Models drawn in the cost chart: those with a priced cost > 0, cost desc.
    let chartModels: [String]
    /// day × chartModel, zero-filled.
    let costBars: [CostBar]
    /// Usage samples inside the period, oldest first; 5h only when present.
    let usage: [UsagePoint]
    /// When this account was the active one (inside the period).
    let activeIntervals: [DateInterval]
    let trackingStartedAt: Date?
    /// The ledger ever counted something for this account.
    let hasLedgerHistory: Bool

    init(input: DetailInput, period: DetailPeriod, now: Date, timeZone: TimeZone) {
        self.period = period
        self.timeZone = timeZone
        let days = Self.days(count: period.days, endingAt: now, timeZone: timeZone)
        self.days = days
        rangeStart = days.first?.start ?? now
        rangeEnd = now
        trackingStartedAt = input.trackingStartedAt
        hasLedgerHistory = input.firstLedgerDay != nil

        let keys = Set(days.map(\.key))
        let rows = input.rows.filter { $0.accountId == input.accountId && keys.contains($0.day) }
        let lines = LedgerReport.modelLines(rows, table: input.table)
        let tokenSum = lines.reduce(Int64(0)) { $0 + $1.total.tokens.totalTokens }
        models = lines.map {
            ModelShare(model: $0.model, total: $0.total, costShare: $0.costShare,
                       tokenShare: tokenSum > 0 ? Double($0.total.tokens.totalTokens) / Double(tokenSum) : nil)
        }
        let chartModels = lines.filter { $0.total.cost > 0 }.map(\.model)
        self.chartModels = chartModels

        var byDay: [String: [LedgerRow]] = [:]
        for r in rows { byDay[r.day, default: []].append(r) }
        var totals: [DayTotal] = []
        var bars: [CostBar] = []
        var sum = LedgerReport.Total()
        for day in days {
            var t = LedgerReport.Total()
            var costs: [String: Double] = [:]
            for r in byDay[day.key] ?? [] {
                let rt = LedgerReport.total(r, table: input.table)
                t += rt
                costs[r.model, default: 0] += rt.cost
            }
            let chartCosts = costs.filter { chartModels.contains($0.key) }
            totals.append(DayTotal(day: day, total: t, modelCosts: chartCosts))
            bars += chartModels.map { CostBar(day: day, model: $0, cost: chartCosts[$0] ?? 0) }
            sum += t
        }
        dayTotals = totals
        costBars = bars
        periodTotal = sum
        today = totals.last?.total ?? LedgerReport.Total()

        usage = Self.usagePoints(input.samples, accountId: input.accountId, from: rangeStart, to: now)
        activeIntervals = Self.activeIntervals(
            rolls: input.rolls, account: input.accountId, activeNow: input.activeNow,
            from: rangeStart, to: now)
    }

    /// Stacked token bars of every day × visible kind (zeros included).
    func tokenBars(includeCacheRead: Bool) -> [TokenBar] {
        let kinds = DetailTokenKind.visible(includeCacheRead: includeCacheRead)
        return dayTotals.flatMap { d in
            kinds.map { TokenBar(day: d.day, kind: $0, value: $0.value(d.total.tokens)) }
        }
    }

    /// Day total under a chart x position (hover). nil outside the period.
    func dayTotal(at date: Date) -> DayTotal? {
        let key = DayFormatter(timeZone: timeZone).string(date)
        return dayTotals.first { $0.day.key == key }
    }

    /// Usage reading nearest to a chart x position (hover).
    func usageSample(near date: Date, window: UsagePoint.Window = .sevenDay) -> UsagePoint? {
        usage.filter { $0.window == window }
            .min { abs($0.ts.timeIntervalSince(date)) < abs($1.ts.timeIntervalSince(date)) }
    }

    var hasFiveHour: Bool { usage.contains { $0.window == .fiveHour } }

    // MARK: - Rules

    /// The last `count` local days ending today, oldest first.
    static func days(count: Int, endingAt now: Date, timeZone: TimeZone) -> [DetailDay] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let fmt = DayFormatter(timeZone: timeZone)
        let today = cal.startOfDay(for: now)
        return (0..<max(count, 1)).reversed().compactMap { back in
            cal.date(byAdding: .day, value: -back, to: today).map { DetailDay(key: fmt.string($0), start: $0) }
        }
    }

    /// 7d (and 5h when the account has it) readings inside `from…to`.
    static func usagePoints(_ samples: [UsageSample], accountId: UUID, from: Date, to: Date) -> [UsagePoint] {
        let inside = samples.filter { $0.accountId == accountId && $0.ts >= from && $0.ts <= to }
            .sorted { $0.ts < $1.ts }
        var out: [UsagePoint] = inside.compactMap { s in
            s.sevenDay.map { UsagePoint(ts: s.ts, window: .sevenDay, percent: Self.clampPercent($0)) }
        }
        out += inside.compactMap { s in
            s.fiveHour.map { UsagePoint(ts: s.ts, window: .fiveHour, percent: Self.clampPercent($0)) }
        }
        return out
    }

    static func clampPercent(_ v: Double) -> Double { min(max(v, 0), 100) }

    /// Spans when `account` was the active one, from the roll history, cut to
    /// `from…to`. A record makes its `to` account active until the next
    /// record. The open last span runs to `to` only when the active file
    /// still names the account; otherwise something changed the file without
    /// a history line (deleted account, failed history write) and the end is
    /// unknown — the span is not drawn rather than drawn wrong.
    static func activeIntervals(rolls: [ActiveAccountStore.RollRecord], account: UUID,
                                activeNow: Bool, from: Date, to: Date) -> [DateInterval] {
        var spans: [(Date, Date)] = []
        var start: Date?
        for r in rolls.sorted(by: { $0.ts < $1.ts }) {
            if r.to == account {
                if start == nil { start = r.ts }
            } else if let s = start {
                spans.append((s, r.ts))
                start = nil
            }
        }
        if let s = start, activeNow { spans.append((s, to)) }
        return spans.compactMap { s, e in
            let a = max(s, from), b = min(e, to)
            return b > a ? DateInterval(start: a, end: b) : nil
        }
    }
}

/// Text of the detail window (pure, tested).
enum DetailFormat {
    /// `62%` (rounded down like the popover gauge).
    static func percent(_ v: Double) -> String { "\(Int(v))%" }

    /// Share `0.123` → `12.3%`; under 0.1% but above 0 → `<0.1%`.
    static func share(_ v: Double?) -> String {
        guard let v else { return "—" }
        if v > 0 && v < 0.001 { return "<0.1%" }
        return String(format: "%.1f%%", v * 100)
    }

    /// Breakdown of a token count: `입력 1,234 · 출력 … · 캐시 쓰기 … · 캐시 읽기 …`.
    static func breakdown(_ t: TokenCounts) -> String {
        DetailTokenKind.allCases.map { "\($0.label) \(LedgerFormat.count($0.value(t)))" }
            .joined(separator: " · ")
    }

    /// Axis label for dollars: `$0`, `$1.5`, `$12`, `$1.2K`.
    static func axisDollars(_ v: Double) -> String {
        switch abs(v) {
        case 1000...: return String(format: "$%.1fK", v / 1000)
        case 10...: return String(format: "$%.0f", v)
        case 0: return "$0"
        case 1...: return String(format: "$%.1f", v)
        default: return String(format: "$%.2f", v)
        }
    }

    /// Empty-ledger notice (PRD 빈 상태 1).
    static func noLedgerNotice(trackingStartedAt: Date?, timeZone: TimeZone) -> String {
        let suffix = "usagebar-claude를 거친 실행만 집계됩니다"
        guard let started = trackingStartedAt else {
            return "아직 usagebar-claude를 거친 claude 실행이 없습니다 — \(suffix)"
        }
        return "\(DayFormatter(timeZone: timeZone).string(started)) 이후 이 계정으로 실행된 claude 기록이 없습니다 — \(suffix)"
    }

    /// Empty-history notice (PRD 빈 상태 2).
    static let noUsageNotice = "이 기간의 사용률 표본이 아직 없습니다 — 앱이 3분마다 조회하고 usagebar-claude 실행 때마다 쌓입니다"
}

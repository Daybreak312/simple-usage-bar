import Foundation

// 두 그래프 창(계정 사용률 · 이 맥 사용량)의 데이터 준비 계층.
// 뷰와 분리된 순수 계산 — 기간 자르기, 빈 날짜 0 채우기, 누적 구분, 캐시 읽기
// 토글, 모델 정렬·비중, 교체 시점 추출을 `swift test`로 검증한다.

/// 창의 기간. 그 창의 모든 그래프·합계가 같은 기간을 따른다.
enum ChartPeriod: Int, CaseIterable, Identifiable {
    case week = 7
    case month = 30
    case quarter = 90

    static let `default`: ChartPeriod = .month

    var id: Int { rawValue }
    var days: Int { rawValue }
    var label: String { "\(rawValue)일" }

    /// 계정 사용률 그래프의 한 점이 덮는 시간. 표본은 계정당 3분에 하나라 원본을
    /// 그대로 그리면 계열당 30일 약 1.4만·90일 약 4.3만 점이 되고, 그래프가 메인
    /// 스레드에서 그만큼의 마크를 그린다. 구간마다 최고값 하나로 줄여 계열당 약
    /// 700점 이하로 묶는다(최고값이라 95% 롤링 임계 근접이 묻히지 않는다).
    var usageBucket: TimeInterval {
        switch self {
        case .week: return 15 * 60
        case .month: return 3600
        case .quarter: return 3 * 3600
        }
    }
}

/// 기간의 로컬 하루: 장부 키와 그날 자정.
struct ChartDay: Equatable, Hashable {
    /// 장부 시간대의 `yyyy-MM-dd` (`LedgerRow.day`와 같은 키).
    var key: String
    /// 로컬 자정 — 일별 막대의 x 값.
    var start: Date

    /// 오늘로 끝나는 최근 `count`일, 오래된 날부터.
    static func period(count: Int, endingAt now: Date, timeZone: TimeZone) -> [ChartDay] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let fmt = DayFormatter(timeZone: timeZone)
        let today = cal.startOfDay(for: now)
        return (0..<max(count, 1)).reversed().compactMap { back in
            cal.date(byAdding: .day, value: -back, to: today).map { ChartDay(key: fmt.string($0), start: $0) }
        }
    }
}

/// 일별 토큰 그래프에 쌓는 구분(아래 → 위).
enum TokenKind: String, CaseIterable, Identifiable {
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

    /// 캐시 쓰기 = 5분 + 1시간.
    func value(_ t: TokenCounts) -> Int64 {
        switch self {
        case .input: return t.input
        case .output: return t.output
        case .cacheWrite: return t.cacheWrite5m + t.cacheWrite1h
        case .cacheRead: return t.cacheRead
        }
    }

    /// 표시할 구분 — 캐시 읽기(다른 구분의 수십 배인 경우가 많음)는 선택.
    static func visible(includeCacheRead: Bool) -> [TokenKind] {
        includeCacheRead ? allCases : allCases.filter { $0 != .cacheRead }
    }

    /// 구분 합 (캐시 읽기 포함 여부에 따라).
    static func sum(_ t: TokenCounts, includeCacheRead: Bool) -> Int64 {
        visible(includeCacheRead: includeCacheRead).reduce(0) { $0 + $1.value(t) }
    }
}

// MARK: - 이 맥 사용량

/// 이 맥 사용량 창이 그리는 모든 것 — 장부 행(계정 구분 없음)에서 도출.
struct MacUsageData {
    struct DayTotal: Equatable {
        var day: ChartDay
        var total: LedgerReport.Total
        /// 이 날의 모델별 API 환산 비용 (`chartModels`만, 「기타」 포함).
        var modelCosts: [String: Double]
    }

    struct TokenBar: Equatable, Identifiable {
        var day: ChartDay
        var kind: TokenKind
        var value: Int64
        var id: String { "\(day.key)|\(kind.rawValue)" }
    }

    struct CostBar: Equatable, Identifiable {
        var day: ChartDay
        var model: String
        var cost: Double
        var id: String { "\(day.key)|\(model)" }
    }

    struct ModelShare: Equatable {
        var model: String
        var total: LedgerReport.Total
        /// 기간 API 환산 비용 중 비중 (nil = 단가 미상 또는 비용 0).
        var costShare: Double?
        /// 기간 토큰 중 비중 (nil = 토큰 없음).
        var tokenShare: Double?
    }

    /// 비용 그래프에 따로 그리는 모델 수 상한. 넘치면 비용 하위 모델을
    /// 「기타」 하나로 접는다 — 색은 고정 순서 8개를 돌려 쓰지 않는다.
    static let maxChartSeries = 8
    static let otherModels = "기타"

    let period: ChartPeriod
    let timeZone: TimeZone
    let days: [ChartDay]
    /// 기간 경계: 첫날 자정 … 마지막 날 다음 자정 (막대 x 축).
    let rangeStart: Date
    let rangeEnd: Date
    /// 기간의 날마다 한 칸, 0 채움.
    let dayTotals: [DayTotal]
    let periodTotal: LedgerReport.Total
    let today: LedgerReport.Total
    /// 비용 내림차순, 단가 미상은 뒤 (`LedgerReport.modelLines` 순서).
    let models: [ModelShare]
    /// 비용 그래프 계열: 비용 > 0인 모델, 비용 내림차순 (넘치면 끝이 「기타」).
    let chartModels: [String]
    /// 날짜 × 계열, 0 채움.
    let costBars: [CostBar]
    let trackingStartedAt: Date?
    /// 장부에 무엇이든 집계된 적이 있다.
    let hasLedgerHistory: Bool

    init(rows: [LedgerRow], period: ChartPeriod, now: Date, timeZone: TimeZone,
         trackingStartedAt: Date?, firstLedgerDay: String?, table: ModelPriceTable) {
        self.period = period
        self.timeZone = timeZone
        let days = ChartDay.period(count: period.days, endingAt: now, timeZone: timeZone)
        self.days = days
        rangeStart = days.first?.start ?? now
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        rangeEnd = days.last.flatMap { cal.date(byAdding: .day, value: 1, to: $0.start) } ?? now
        self.trackingStartedAt = trackingStartedAt
        hasLedgerHistory = firstLedgerDay != nil

        let keys = Set(days.map(\.key))
        let rows = rows.filter { keys.contains($0.day) }
        let lines = LedgerReport.modelLines(rows, table: table)
        let tokenSum = lines.reduce(Int64(0)) { $0 + $1.total.tokens.totalTokens }
        models = lines.map {
            ModelShare(model: $0.model, total: $0.total, costShare: $0.costShare,
                       tokenShare: tokenSum > 0 ? Double($0.total.tokens.totalTokens) / Double(tokenSum) : nil)
        }
        let (chartModels, series) = Self.chartSeries(lines.filter { $0.total.cost > 0 }.map(\.model))
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
                let rt = LedgerReport.total(r, table: table)
                t += rt
                if let s = series[r.model], rt.cost > 0 { costs[s, default: 0] += rt.cost }
            }
            totals.append(DayTotal(day: day, total: t, modelCosts: costs))
            bars += chartModels.map { CostBar(day: day, model: $0, cost: costs[$0] ?? 0) }
            sum += t
        }
        dayTotals = totals
        costBars = bars
        periodTotal = sum
        today = totals.last?.total ?? LedgerReport.Total()
    }

    /// 계열 이름 목록과 모델 → 계열 매핑. 상한을 넘으면 앞 (상한-1)개 + 「기타」.
    static func chartSeries(_ models: [String]) -> ([String], [String: String]) {
        guard models.count > maxChartSeries else {
            return (models, Dictionary(uniqueKeysWithValues: models.map { ($0, $0) }))
        }
        let kept = Array(models.prefix(maxChartSeries - 1))
        var map = Dictionary(uniqueKeysWithValues: kept.map { ($0, $0) })
        for m in models.dropFirst(maxChartSeries - 1) { map[m] = otherModels }
        return (kept + [otherModels], map)
    }

    /// 날짜 × 표시 구분의 누적 막대 (0 포함).
    func tokenBars(includeCacheRead: Bool) -> [TokenBar] {
        let kinds = TokenKind.visible(includeCacheRead: includeCacheRead)
        return dayTotals.flatMap { d in
            kinds.map { TokenBar(day: d.day, kind: $0, value: $0.value(d.total.tokens)) }
        }
    }

    /// 그래프 x 위치의 날 (호버). 기간 밖이면 nil.
    func dayTotal(at date: Date) -> DayTotal? {
        let key = DayFormatter(timeZone: timeZone).string(date)
        return dayTotals.first { $0.day.key == key }
    }

    /// 기간에 집계된 토큰이 하나도 없다.
    var isEmptyPeriod: Bool { periodTotal.tokens.totalTokens == 0 }
}

// MARK: - 계정 사용률

/// 계정 사용률 창의 원재료 (저장소에서 읽은 그대로).
struct AccountUsageInput {
    /// 계정 키 (`AccountKey` — 이메일 소문자).
    var key: String
    /// 이 계정의 사용률 표본 (범위 무관 — 기간으로 자른다).
    var samples: [UsageSample]
    /// 키체인 교체 기록 전체 (활성 구간은 기간 이전 기록에서 시작될 수 있다).
    var rolls: [RollRecord]
    /// 지금 키체인 로그인(로컬 행)이 이 계정이다.
    var activeNow: Bool
    /// 이 계정의 가장 오래된 표본 시각 (nil = 기록 없음).
    var firstSampleAt: Date?
    /// 모든 계정을 통틀어 가장 오래된 표본 시각 = 사용률 기록 시작.
    var historyStartedAt: Date?
}

/// 계정 사용률 창이 그리는 모든 것.
struct AccountUsageData: Equatable {
    struct UsagePoint: Equatable, Identifiable {
        enum Window: String { case sevenDay = "7d", fiveHour = "5h" }
        var ts: Date
        var window: Window
        var percent: Double
        /// 같은 창 안에서 표본 공백(앱 종료·잠자기)으로 끊긴 선 조각 번호.
        var segment: Int = 0
        var id: String { "\(window.rawValue)|\(ts.timeIntervalSince1970)" }
        /// 그래프 선 계열 — 공백에서 선이 이어지지 않게 조각마다 다르다.
        var series: String { "\(window.rawValue)#\(segment)" }
    }

    /// 그래프 x 위치의 호버 값 — 그 위치에서 가장 가까운 점의 구간과, 같은 구간의
    /// 7d·5h 점.
    struct Hover: Equatable {
        /// 가장 가까운 점의 시각 (세로선 위치).
        var anchor: Date
        /// 그 점이 대표하는 구간 (`usageBucket`).
        var span: DateInterval
        var sevenDay: UsagePoint?
        var fiveHour: UsagePoint?
        /// 교체 기록으로 확인된 활성 구간 안이다.
        var active: Bool

        var points: [UsagePoint] { [sevenDay, fiveHour].compactMap { $0 } }
    }

    struct RollEvent: Equatable, Identifiable {
        enum Direction: Equatable {
            /// 이 계정으로 교체됨.
            case rolledIn
            /// 이 계정에서 다른 계정으로 빠져나감.
            case rolledOut
        }
        var ts: Date
        var direction: Direction
        /// 상대 계정 (교체 전 또는 후). 특정 못 했으면 nil.
        var counterpart: String?
        var reason: String
        var id: String { "\(ts.timeIntervalSince1970)|\(direction)" }
    }

    struct Peak: Equatable {
        var ts: Date
        var percent: Double
    }

    let key: String
    let period: ChartPeriod
    let timeZone: TimeZone
    /// 기간 경계: 첫날 자정 … 지금.
    let rangeStart: Date
    let rangeEnd: Date
    /// 한 점이 덮는 시간 (`ChartPeriod.usageBucket`).
    let bucket: TimeInterval
    /// 기간 안 7d 점 — 구간별 최고값으로 줄인 것, 오래된 것부터.
    let sevenDay: [UsagePoint]
    /// 기간 안 5h 점 (값이 있는 표본만) — 같은 규칙.
    let fiveHour: [UsagePoint]
    /// 앞뒤가 공백이라 선으로 그려지지 않는 외톨이 점 (점으로 따로 찍는다).
    let isolated: [UsagePoint]
    /// 기간 내 7d 최고값 (같은 값이면 최근 것) — 줄이기 전 원본 표본에서.
    let peakSevenDay: Peak?
    /// 기간 안 교체 시점 (이 계정으로 / 이 계정에서).
    let rollEvents: [RollEvent]
    /// 교체 기록 양끝이 모두 이 계정을 가리키는 활성 구간 (기간으로 자름).
    let activeIntervals: [DateInterval]
    let firstSampleAt: Date?
    let historyStartedAt: Date?

    init(input: AccountUsageInput, period: ChartPeriod, now: Date, timeZone: TimeZone) {
        key = input.key
        self.period = period
        self.timeZone = timeZone
        let days = ChartDay.period(count: period.days, endingAt: now, timeZone: timeZone)
        rangeStart = days.first?.start ?? now
        rangeEnd = now
        firstSampleAt = input.firstSampleAt
        historyStartedAt = input.historyStartedAt
        bucket = period.usageBucket
        let raw = Self.usagePoints(input.samples, key: input.key, from: rangeStart, to: now)
        let rawSeven = raw.filter { $0.window == .sevenDay }
        peakSevenDay = rawSeven.max(by: Self.lowerThenOlder).map { Peak(ts: $0.ts, percent: $0.percent) }
        let gap = Self.maxGap(bucket: bucket)
        sevenDay = Self.segmented(Self.downsampled(rawSeven, bucket: bucket), maxGap: gap)
        fiveHour = Self.segmented(Self.downsampled(raw.filter { $0.window == .fiveHour }, bucket: bucket),
                                  maxGap: gap)
        isolated = Self.isolatedPoints(sevenDay) + Self.isolatedPoints(fiveHour)
        rollEvents = Self.rollEvents(input.rolls, key: input.key, from: rangeStart, to: now)
        activeIntervals = Self.activeIntervals(rolls: input.rolls, key: input.key,
                                               activeNow: input.activeNow, from: rangeStart, to: now)
    }

    /// 그릴 점 전부 (7d 다음 5h).
    var usage: [UsagePoint] { sevenDay + fiveHour }

    var hasFiveHour: Bool { !fiveHour.isEmpty }

    /// 그래프 x 위치에 가장 가까운 점 (이진 탐색).
    func usageSample(near date: Date, window: UsagePoint.Window = .sevenDay) -> UsagePoint? {
        Self.nearest(window == .sevenDay ? sevenDay : fiveHour, to: date)
    }

    /// 그래프 x 위치의 호버 값. 가장 가까운 점(7d·5h 중)의 구간을 잡고, 같은 구간의
    /// 다른 창 점을 붙인다 — 두 창의 최고값은 구간 안 서로 다른 표본일 수 있다.
    func hover(at date: Date) -> Hover? {
        let candidates = [usageSample(near: date), usageSample(near: date, window: .fiveHour)]
            .compactMap { $0 }
        guard let anchor = candidates.min(by: {
            abs($0.ts.timeIntervalSince(date)) < abs($1.ts.timeIntervalSince(date))
        }) else { return nil }
        let index = Self.bucketIndex(anchor.ts, bucket: bucket)
        func inBucket(_ window: UsagePoint.Window) -> UsagePoint? {
            usageSample(near: anchor.ts, window: window)
                .flatMap { Self.bucketIndex($0.ts, bucket: bucket) == index ? $0 : nil }
        }
        return Hover(anchor: anchor.ts,
                     span: DateInterval(start: Date(timeIntervalSince1970: Double(index) * bucket),
                                        duration: bucket),
                     sevenDay: inBucket(.sevenDay), fiveHour: inBucket(.fiveHour),
                     active: activeIntervals.contains { $0.contains(anchor.ts) })
    }

    /// 표본이 없을 때의 안내 (nil = 그릴 표본이 있다).
    var emptyNotice: String? {
        guard usage.isEmpty else { return nil }
        let day = DayFormatter(timeZone: timeZone)
        if let first = firstSampleAt {
            return "최근 \(period.label) 동안 이 계정의 사용률 기록이 없습니다 (기록 시작 \(day.string(first)))"
        }
        if let started = historyStartedAt {
            return "\(day.string(started)) 이후 이 계정의 사용률 기록이 없습니다"
        }
        return "아직 사용률 기록이 없습니다 — 앱이 Claude 계정을 3분마다 조회해 쌓습니다"
    }

    // MARK: - Rules

    /// 이 계정의 7d(와 값이 있으면 5h) 표본 중 `from…to` 안의 것.
    static func usagePoints(_ samples: [UsageSample], key: String, from: Date, to: Date) -> [UsagePoint] {
        let inside = samples.filter { $0.key == key && $0.ts >= from && $0.ts <= to }
            .sorted { $0.ts < $1.ts }
        var out: [UsagePoint] = inside.compactMap { s in
            s.sevenDay.map { UsagePoint(ts: s.ts, window: .sevenDay, percent: clampPercent($0)) }
        }
        out += inside.compactMap { s in
            s.fiveHour.map { UsagePoint(ts: s.ts, window: .fiveHour, percent: clampPercent($0)) }
        }
        return out
    }

    static func clampPercent(_ v: Double) -> Double { min(max(v, 0), 100) }

    /// 최고값 비교 — 낮은 값이 먼저, 같으면 오래된 것이 먼저(= max는 최근 것).
    static func lowerThenOlder(_ a: UsagePoint, _ b: UsagePoint) -> Bool {
        a.percent < b.percent || (a.percent == b.percent && a.ts < b.ts)
    }

    /// 시각이 속한 구간 번호 (epoch 기준 `bucket`초 단위).
    static func bucketIndex(_ ts: Date, bucket: TimeInterval) -> Int {
        Int((ts.timeIntervalSince1970 / bucket).rounded(.down))
    }

    /// 한 창의 점(시각순)을 구간마다 최고값 하나로 줄인다 — 같은 값이면 최근 것.
    /// 점은 실제 표본의 시각·값을 그대로 쓴다(구간 대표 시각을 지어내지 않는다).
    static func downsampled(_ points: [UsagePoint], bucket: TimeInterval) -> [UsagePoint] {
        var out: [UsagePoint] = []
        var current: Int?
        for p in points {
            let index = bucketIndex(p.ts, bucket: bucket)
            if index == current, let last = out.last {
                if lowerThenOlder(last, p) { out[out.count - 1] = p }
            } else {
                out.append(p)
                current = index
            }
        }
        return out
    }

    /// 선을 끊는 표본 공백. 구간 최고값끼리는 최대 2구간 가까이 떨어질 수 있어
    /// 3구간(최소 30분)을 넘는 틈만 공백으로 본다.
    static func maxGap(bucket: TimeInterval) -> TimeInterval { max(3 * bucket, 30 * 60) }

    /// 이웃 점 사이가 `maxGap`을 넘으면 새 조각 번호를 매긴다.
    static func segmented(_ points: [UsagePoint], maxGap: TimeInterval) -> [UsagePoint] {
        var segment = 0
        var previous: Date?
        return points.map { p in
            if let prev = previous, p.ts.timeIntervalSince(prev) > maxGap { segment += 1 }
            previous = p.ts
            var q = p
            q.segment = segment
            return q
        }
    }

    /// 점 하나뿐인 조각 — 선으로는 보이지 않는다.
    static func isolatedPoints(_ points: [UsagePoint]) -> [UsagePoint] {
        let counts = Dictionary(grouping: points, by: \.segment).mapValues(\.count)
        return points.filter { counts[$0.segment] == 1 }
    }

    /// 시각순 배열에서 `date`에 가장 가까운 점 (같은 거리면 이른 것).
    static func nearest(_ points: [UsagePoint], to date: Date) -> UsagePoint? {
        var lo = 0, hi = points.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if points[mid].ts < date { lo = mid + 1 } else { hi = mid }
        }
        let before = lo > 0 ? points[lo - 1] : nil
        let after = lo < points.count ? points[lo] : nil
        guard let b = before else { return after }
        guard let a = after else { return b }
        return a.ts.timeIntervalSince(date) < date.timeIntervalSince(b.ts) ? a : b
    }

    /// `from…to` 안에서 이 계정으로 교체된 시점과 이 계정에서 빠져나간 시점.
    /// 같은 계정으로의 교체(from == to)는 변화가 없어 빼낸다.
    static func rollEvents(_ rolls: [RollRecord], key: String, from: Date, to: Date) -> [RollEvent] {
        rolls.filter { $0.ts >= from && $0.ts <= to }.sorted { $0.ts < $1.ts }.compactMap { r in
            if r.to == key, r.from != key {
                return RollEvent(ts: r.ts, direction: .rolledIn, counterpart: r.from, reason: r.reason)
            }
            if r.from == key, r.to != key {
                return RollEvent(ts: r.ts, direction: .rolledOut, counterpart: r.to, reason: r.reason)
            }
            return nil
        }
    }

    /// 이 계정이 활성이던 구간 — 교체 기록으로 양끝이 확인되는 것만.
    ///
    /// 구간은 「이 계정으로 교체」 기록에서 시작해, 다음 기록이 「이 계정에서」
    /// 교체(from == 이 계정)일 때 그 시각에 끝난다. 다음 기록의 from이 다른
    /// 계정이거나 미상이면 그 사이에 기록 없는 로그인 변경(`claude login` 등)이
    /// 있었다는 뜻이라 끝을 알 수 없다 — 틀리게 그리느니 그리지 않는다. 열린
    /// 마지막 구간은 지금 키체인 로그인이 이 계정일 때만 지금까지 이어진다.
    static func activeIntervals(rolls: [RollRecord], key: String, activeNow: Bool,
                                from: Date, to: Date) -> [DateInterval] {
        var spans: [(Date, Date)] = []
        var start: Date?
        for r in rolls.sorted(by: { $0.ts < $1.ts }) {
            if let s = start {
                if r.from == key {
                    if r.to == key { continue }  // 같은 계정 재지정 — 구간 유지
                    spans.append((s, r.ts))
                    start = nil
                } else {
                    // 끝을 모르는 구간은 버린다. 이 기록이 다시 이 계정으로의 교체면 새로 시작.
                    start = r.to == key ? r.ts : nil
                }
            } else if r.to == key {
                start = r.ts
            }
        }
        if let s = start, activeNow { spans.append((s, to)) }
        return spans.compactMap { s, e in
            let a = max(s, from), b = min(e, to)
            return b > a ? DateInterval(start: a, end: b) : nil
        }
    }
}

// MARK: - Text

/// 두 창의 문구 (순수, 테스트 대상).
enum ChartFormat {
    /// `62%` (팝오버 게이지처럼 내림).
    static func percent(_ v: Double) -> String { "\(Int(v))%" }

    /// 비중 `0.123` → `12.3%`; 0 초과 0.1% 미만 → `<0.1%`.
    static func share(_ v: Double?) -> String {
        guard let v else { return "—" }
        if v > 0 && v < 0.001 { return "<0.1%" }
        return String(format: "%.1f%%", v * 100)
    }

    /// `입력 1,234 · 출력 … · 캐시 쓰기 … · 캐시 읽기 …`.
    static func breakdown(_ t: TokenCounts) -> String {
        TokenKind.allCases.map { "\($0.label) \(LedgerFormat.count($0.value(t)))" }
            .joined(separator: " · ")
    }

    /// 달러 축 라벨: `$0`, `$0.25`, `$1.5`, `$12`, `$1.2K`.
    static func axisDollars(_ v: Double) -> String {
        switch abs(v) {
        case 1000...: return String(format: "$%.1fK", v / 1000)
        case 10...: return String(format: "$%.0f", v)
        case 0: return "$0"
        case 1...: return String(format: "$%.1f", v)
        default: return String(format: "$%.2f", v)
        }
    }

    /// 이 맥 사용량 빈 상태.
    static func noLedgerNotice(trackingStartedAt: Date?, timeZone: TimeZone) -> String {
        guard let started = trackingStartedAt else {
            return "아직 사용량 집계가 시작되지 않았습니다 — 앱이 1분 이내에 이 맥의 claude 세션 기록 집계를 시작합니다"
        }
        return "\(DayFormatter(timeZone: timeZone).string(started)) 이후 기록된 claude 사용량이 없습니다"
    }

    /// 교체 시점 한 줄: `11월 19일 14:03 이 계정으로 교체 (← a@x.com, 7d 95%)`.
    static func rollEvent(_ e: AccountUsageData.RollEvent, timeZone: TimeZone) -> String {
        var parts: [String] = []
        if let c = e.counterpart { parts.append(e.direction == .rolledIn ? "← \(c)" : "→ \(c)") }
        if !e.reason.isEmpty { parts.append(e.reason) }
        let what = e.direction == .rolledIn ? "이 계정으로 교체" : "다른 계정으로 교체"
        return "\(timeLabel(e.ts, timeZone: timeZone)) \(what)"
            + (parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))")
    }

    static func dayLabel(_ day: ChartDay, timeZone: TimeZone) -> String {
        format(day.start, "M월 d일 (E)", timeZone)
    }

    static func timeLabel(_ date: Date, timeZone: TimeZone) -> String {
        format(date, "M월 d일 HH:mm", timeZone)
    }

    /// `15분`, `1시간`, `3시간`.
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        return minutes % 60 == 0 ? "\(minutes / 60)시간" : "\(minutes)분"
    }

    /// 계정 사용률 호버 줄: `11월 19일 14:00–15:00 · 7d 62% · 5h 41% · 활성`.
    static func usageHover(_ h: AccountUsageData.Hover, timeZone: TimeZone) -> String {
        var parts = ["\(timeLabel(h.span.start, timeZone: timeZone))–\(format(h.span.end, "HH:mm", timeZone))"]
        if let seven = h.sevenDay { parts.append("7d \(percent(seven.percent))") }
        if let five = h.fiveHour { parts.append("5h \(percent(five.percent))") }
        if h.active { parts.append("활성") }
        return parts.joined(separator: " · ")
    }

    /// 계정 사용률 그래프 해상도 안내.
    static func bucketNote(_ period: ChartPeriod) -> String {
        "한 점 = \(duration(period.usageBucket)) 구간의 최고값 (3분 간격 기록을 줄여 그립니다)"
    }

    private static func format(_ date: Date, _ pattern: String, _ timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = pattern
        return f.string(from: date)
    }

    /// 날짜 축 라벨 간격: 기간과 무관하게 7~10개.
    static func dayStride(_ period: ChartPeriod) -> Int {
        switch period {
        case .week: return 1
        case .month: return 5
        case .quarter: return 14
        }
    }
}

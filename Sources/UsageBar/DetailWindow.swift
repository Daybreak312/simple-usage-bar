import AppKit
import Charts
import SwiftUI

// MARK: - Window management

/// One 「자세히」 window per Claude account. AppKit-managed rather than a
/// SwiftUI `WindowGroup`: the app is a menu-bar-only accessory app, and a
/// WindowGroup scene can be opened (or restored) by SwiftUI at launch — here
/// a window exists only while the user asked for it.
@MainActor
final class DetailWindowController: NSObject, NSWindowDelegate {
    static let shared = DetailWindowController()

    static let initialSize = NSSize(width: 780, height: 880)
    static let minimumSize = NSSize(width: 640, height: 520)

    private var windows: [UUID: NSWindow] = [:]

    static func title(_ account: Account) -> String { "\(account.email) — 사용량" }

    /// Open the account's window, or bring the existing one to the front.
    func show(_ account: Account, poller: Poller) {
        let window = windows[account.id] ?? makeWindow(account, poller: poller)
        window.title = Self.title(account)
        // Accessory app: without activation the window opens behind the
        // frontmost app.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Close the account's window (account removed).
    func close(accountId: UUID) {
        windows[accountId]?.close()
    }

    private func makeWindow(_ account: Account, poller: Poller) -> NSWindow {
        let host = NSHostingController(
            rootView: AccountDetailView(accountId: account.id).environmentObject(poller))
        // The window size is the user's, not the SwiftUI content's.
        host.sizingOptions = []
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(Self.initialSize)
        window.contentMinSize = Self.minimumSize
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        windows[account.id] = window
        return window
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        // Dropping the window releases its hosting view (and its timers).
        windows = windows.filter { $0.value !== window }
    }
}

// MARK: - Loading

/// Reads one account's detail inputs from the stores. Blocking (SQLite and
/// file reads) — call off the main thread.
enum DetailLoader {
    struct Loaded {
        var data: DetailData
        /// Ledger read failure (the charts then show what could be read).
        var error: String?
    }

    static func load(accountId: UUID, period: DetailPeriod, now: Date,
                     ledger: UsageLedger = .shared, history: UsageHistoryStore = .shared,
                     active: ActiveAccountStore = .shared, prices: ModelPriceSource = .shared) -> Loaded {
        let days = DetailData.days(count: period.days, endingAt: now, timeZone: ledger.timeZone)
        var failure: String?
        var rows: [LedgerRow] = []
        var firstDay: String?
        do {
            rows = try ledger.rows(fromDay: days.first?.key ?? "", toDay: days.last?.key ?? "", account: accountId)
            firstDay = try ledger.firstDay(account: accountId)
        } catch {
            failure = "사용량 장부 읽기 실패: \(error.localizedDescription)"
        }
        let input = DetailInput(
            accountId: accountId, rows: rows,
            samples: history.samples(for: accountId, since: days.first?.start),
            rolls: active.loadHistory(),
            activeNow: active.read()?.accountId == accountId,
            trackingStartedAt: ledger.trackingStartedAt(),
            firstLedgerDay: firstDay,
            table: prices.current().table)
        return Loaded(data: DetailData(input: input, period: period, now: now, timeZone: ledger.timeZone),
                      error: failure)
    }
}

@MainActor
final class AccountDetailModel: ObservableObject {
    @Published private(set) var data: DetailData?
    @Published private(set) var error: String?
    @Published private(set) var loading = false
    @Published private(set) var loadedAt: Date?

    let accountId: UUID
    /// Latest request wins — an older load finishing late is dropped.
    private var generation = 0

    init(accountId: UUID) {
        self.accountId = accountId
    }

    func reload(period: DetailPeriod) {
        generation += 1
        let gen = generation
        let id = accountId
        loading = true
        Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                DetailLoader.load(accountId: id, period: period, now: Date())
            }.value
            guard gen == generation else { return }
            data = loaded.data
            error = loaded.error
            loadedAt = Date()
            loading = false
        }
    }
}

// MARK: - Window root

struct AccountDetailView: View {
    let accountId: UUID
    @EnvironmentObject var poller: Poller
    @StateObject private var model: AccountDetailModel
    @State private var period = DetailPeriod.default
    @State private var includeCacheRead = false

    /// Re-read at least once a minute while open (usage samples land every
    /// poll and wrapper event; the ledger change also triggers a reload).
    private let tick = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    init(accountId: UUID) {
        self.accountId = accountId
        _model = StateObject(wrappedValue: AccountDetailModel(accountId: accountId))
    }

    private var state: AccountState? { poller.states.first { $0.account.id == accountId } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Picker("기간", selection: $period) {
                    ForEach(DetailPeriod.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Spacer()

                if model.loading {
                    ProgressView().controlSize(.small)
                }
                if let at = model.loadedAt {
                    Text("갱신 \(at, style: .time)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Button {
                    refresh(scan: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("지금 새로고침 — 세션 기록을 바로 집계하고 다시 읽습니다")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if state == nil {
                Text("이 계정은 제거되었습니다.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let data = model.data {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if let error = model.error {
                            Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        }
                        AccountDetailContent(data: data, snapshot: state?.snapshot,
                                             includeCacheRead: $includeCacheRead)
                    }
                    .padding(16)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: DetailWindowController.minimumSize.width,
               minHeight: DetailWindowController.minimumSize.height)
        .onAppear { refresh(scan: false) }
        .onChange(of: period) { refresh(scan: false) }
        .onChange(of: poller.ledgerUpdatedAt) { refresh(scan: false) }
        .onChange(of: poller.lastRefresh) { refresh(scan: false) }
        .onReceive(tick) { _ in refresh(scan: false) }
    }

    private func refresh(scan: Bool) {
        // A forced scan that adds rows bumps `ledgerUpdatedAt` → one more
        // reload with the new rows.
        if scan { poller.scanLedgerIfDue(force: true) }
        model.reload(period: period)
    }
}

// MARK: - Content (pure render of DetailData — also used for snapshots)

struct AccountDetailContent: View {
    let data: DetailData
    /// Live snapshot of the account (current 7d / 5h and resets).
    let snapshot: UsageSnapshot?
    @Binding var includeCacheRead: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            DetailSummary(data: data, snapshot: snapshot)
            DetailUsageChart(data: data)
            if data.hasLedgerHistory {
                DetailTokenChart(data: data, includeCacheRead: $includeCacheRead)
                DetailCostChart(data: data)
                DetailModelList(data: data)
            } else {
                DetailSection(title: "일별 토큰 · API 환산 비용") {
                    DetailNotice(text: DetailFormat.noLedgerNotice(
                        trackingStartedAt: data.trackingStartedAt, timeZone: data.timeZone))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DetailSection<Content: View>: View {
    let title: String
    var trailing: AnyView?
    @ViewBuilder let content: Content

    init(title: String, trailing: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if let trailing { trailing }
            }
            content
        }
    }
}

struct DetailNotice: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 80)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Hover line above a chart — fixed height so the chart doesn't jump.
struct DetailHoverLine: View {
    let text: String?

    var body: some View {
        Text(text ?? "그래프에 마우스를 올리면 값이 보입니다")
            .font(.caption.monospacedDigit())
            .foregroundStyle(text == nil ? .tertiary : .primary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(height: 16, alignment: .leading)
    }
}

enum DetailDates {
    static func dayLabel(_ day: DetailDay, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.timeZone = timeZone
        f.dateFormat = "M월 d일 (E)"
        return f.string(from: day.start)
    }

    static func timeLabel(_ date: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.timeZone = timeZone
        f.dateFormat = "M월 d일 HH:mm"
        return f.string(from: date)
    }

    /// Day-axis label stride: keeps 7–10 labels whatever the period.
    static func stride(_ period: DetailPeriod) -> Int {
        switch period {
        case .week: return 1
        case .month: return 5
        case .quarter: return 14
        }
    }
}

// MARK: - Summary

struct DetailSummary: View {
    let data: DetailData
    let snapshot: UsageSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 18) {
                window("7d", snapshot?.sevenDay)
                if let five = snapshot?.fiveHour { window("5h", five) }
                Spacer()
                if let started = data.trackingStartedAt {
                    Text("추적 시작 \(DayFormatter(timeZone: data.timeZone).string(started))")
                        .font(.caption).foregroundStyle(.secondary)
                        .help("usagebar-claude를 처음 거친 실행 시각 — 이전 기록은 집계하지 않습니다")
                } else {
                    Text("추적 시작 전").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                tile("\(data.period.label) 합계 토큰", LedgerFormat.count(data.periodTotal.tokens.totalTokens),
                     DetailFormat.breakdown(data.periodTotal.tokens))
                tile("\(data.period.label) 합계 API 환산 비용", LedgerFormat.cost(data.periodTotal),
                     "같은 토큰을 API 정가로 계산한 값 — 구독 청구액이 아닙니다")
                tile("오늘", "\(LedgerFormat.count(data.today.tokens.totalTokens)) 토큰",
                     "API 환산 비용 \(LedgerFormat.cost(data.today))")
            }
        }
    }

    private func window(_ name: String, _ usage: WindowUsage?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(name)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(usage.map { DetailFormat.percent($0.percent) } ?? "—")
                .font(.system(size: 22, weight: .semibold).monospacedDigit())
            if let resets = usage?.resetsAt {
                Text("리셋까지 \(UsageGauge.countdown(to: resets))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func tile(_ title: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 15, weight: .semibold).monospacedDigit())
            Text(detail)
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Chart 1: utilization trend

struct DetailUsageChart: View {
    let data: DetailData
    @State private var selected: Date?

    var body: some View {
        DetailSection(title: "7d 사용률 추이") {
            if data.usage.isEmpty {
                DetailNotice(text: DetailFormat.noUsageNotice)
            } else {
                DetailHoverLine(text: hoverText)
                Chart {
                    ForEach(Array(data.activeIntervals.enumerated()), id: \.offset) { _, span in
                        RectangleMark(
                            xStart: .value("시작", span.start), xEnd: .value("끝", span.end),
                            yStart: .value("하단", 0), yEnd: .value("상단", 100))
                            .foregroundStyle(Color.green.opacity(0.12))
                    }
                    ForEach(data.usage) { p in
                        LineMark(x: .value("시각", p.ts), y: .value("사용률", p.percent))
                            .foregroundStyle(by: .value("구간", p.window.rawValue))
                    }
                    RuleMark(y: .value("롤링 임계", RollingPolicy.threshold))
                        .foregroundStyle(Color.red.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("롤링 \(Int(RollingPolicy.threshold))%").font(.caption2).foregroundStyle(.red)
                        }
                    if let p = selectedPoint {
                        RuleMark(x: .value("선택", p.ts)).foregroundStyle(Color.secondary.opacity(0.5))
                        PointMark(x: .value("선택", p.ts), y: .value("사용률", p.percent))
                            .foregroundStyle(Color.orange)
                    }
                }
                .chartForegroundStyleScale(["7d": Color.orange, "5h": Color.blue])
                .chartLegend(data.hasFiveHour ? .visible : .hidden)
                .chartYScale(domain: 0...100)
                .chartYAxis {
                    AxisMarks(values: [0, 25, 50, 75, 100]) { v in
                        AxisGridLine()
                        AxisValueLabel { Text("\(v.as(Int.self) ?? 0)%") }
                    }
                }
                .chartXScale(domain: data.rangeStart...data.rangeEnd)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: DetailDates.stride(data.period))) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
                    }
                }
                .chartXSelection(value: $selected)
                .frame(height: 180)
                Text(data.activeIntervals.isEmpty
                     ? "이 기간에 이 계정이 활성이던 기록이 없습니다 (롤링 이력 기준)"
                     : "초록 띠 = 이 계정이 활성 계정이던 구간 (롤링 이력 기준)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var selectedPoint: DetailData.UsagePoint? {
        selected.flatMap { data.usageSample(near: $0) }
    }

    private var hoverText: String? {
        guard let p = selectedPoint else { return nil }
        var text = "\(DetailDates.timeLabel(p.ts, timeZone: data.timeZone)) — 7d \(DetailFormat.percent(p.percent))"
        if let five = data.usage.first(where: { $0.window == .fiveHour && $0.ts == p.ts }) {
            text += " · 5h \(DetailFormat.percent(five.percent))"
        }
        if data.activeIntervals.contains(where: { $0.contains(p.ts) }) { text += " · 활성" }
        return text
    }
}

// MARK: - Chart 2: daily tokens

struct DetailTokenChart: View {
    let data: DetailData
    @Binding var includeCacheRead: Bool
    @State private var selected: Date?

    private static func color(_ kind: DetailTokenKind) -> Color {
        switch kind {
        case .input: return .blue
        case .output: return .orange
        case .cacheWrite: return .purple
        case .cacheRead: return .gray
        }
    }

    var body: some View {
        let kinds = DetailTokenKind.visible(includeCacheRead: includeCacheRead)
        DetailSection(title: "일별 토큰", trailing: AnyView(
            Toggle("캐시 읽기 포함", isOn: $includeCacheRead)
                .toggleStyle(.checkbox)
                .font(.caption)
                .help("캐시 읽기는 다른 구분보다 수십 배 큰 경우가 많아 기본으로 막대에서 뺍니다"))
        ) {
            DetailHoverLine(text: hoverText)
            Chart {
                ForEach(data.tokenBars(includeCacheRead: includeCacheRead)) { b in
                    BarMark(x: .value("날짜", b.day.start, unit: .day), y: .value("토큰", b.value))
                        .foregroundStyle(by: .value("구분", b.kind.label))
                }
                if let d = selectedDay {
                    RuleMark(x: .value("선택", d.day.start, unit: .day))
                        .foregroundStyle(Color.secondary.opacity(0.25))
                        .lineStyle(StrokeStyle(lineWidth: 8))
                }
            }
            .chartForegroundStyleScale(domain: kinds.map(\.label), range: kinds.map(Self.color))
            .chartYAxis {
                AxisMarks { v in
                    AxisGridLine()
                    AxisValueLabel { Text(LedgerFormat.short(Int64(v.as(Double.self) ?? 0))) }
                }
            }
            .chartXAxis { DetailDayAxis.marks(data.period) }
            .chartXScale(domain: data.rangeStart...(data.days.last?.start.addingTimeInterval(86_400) ?? data.rangeEnd))
            .chartXSelection(value: $selected)
            .frame(height: 190)
        }
    }

    private var selectedDay: DetailData.DayTotal? { selected.flatMap { data.dayTotal(at: $0) } }

    private var hoverText: String? {
        guard let d = selectedDay else { return nil }
        let t = d.total.tokens
        return "\(DetailDates.dayLabel(d.day, timeZone: data.timeZone)) — 토큰 \(LedgerFormat.count(t.totalTokens)) (\(DetailFormat.breakdown(t)))"
    }
}

enum DetailDayAxis {
    static func marks(_ period: DetailPeriod) -> some AxisContent {
        AxisMarks(values: .stride(by: .day, count: DetailDates.stride(period))) { _ in
            AxisGridLine()
            AxisValueLabel(format: .dateTime.month(.defaultDigits).day(), centered: true)
        }
    }
}

// MARK: - Chart 3: daily API 환산 비용

struct DetailCostChart: View {
    let data: DetailData
    @State private var selected: Date?

    var body: some View {
        DetailSection(title: "일별 API 환산 비용") {
            if data.chartModels.isEmpty {
                DetailNotice(text: data.periodTotal.tokens.totalTokens > 0
                             ? "이 기간의 기록은 모두 단가 미상 모델입니다 — 토큰만 집계됩니다"
                             : "이 기간에 집계된 기록이 없습니다")
            } else {
                DetailHoverLine(text: hoverText)
                Chart {
                    ForEach(data.costBars) { b in
                        BarMark(x: .value("날짜", b.day.start, unit: .day), y: .value("API 환산 비용", b.cost))
                            .foregroundStyle(by: .value("모델", b.model))
                    }
                    if let d = selectedDay {
                        RuleMark(x: .value("선택", d.day.start, unit: .day))
                            .foregroundStyle(Color.secondary.opacity(0.25))
                            .lineStyle(StrokeStyle(lineWidth: 8))
                    }
                }
                .chartForegroundStyleScale(domain: data.chartModels)
                .chartYAxis {
                    AxisMarks { v in
                        AxisGridLine()
                        AxisValueLabel { Text(DetailFormat.axisDollars(v.as(Double.self) ?? 0)) }
                    }
                }
                .chartXAxis { DetailDayAxis.marks(data.period) }
                .chartXScale(domain: data.rangeStart...(data.days.last?.start.addingTimeInterval(86_400) ?? data.rangeEnd))
                .chartXSelection(value: $selected)
                .frame(height: 190)
            }
            if !data.periodTotal.isFullyPriced {
                Text("단가 미상 모델(\(data.periodTotal.unpricedModels.sorted().joined(separator: ", ")))은 금액에서 빠져 있습니다 — 토큰은 집계됩니다")
                    .font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var selectedDay: DetailData.DayTotal? { selected.flatMap { data.dayTotal(at: $0) } }

    private var hoverText: String? {
        guard let d = selectedDay else { return nil }
        let parts = data.chartModels.compactMap { m -> String? in
            guard let c = d.modelCosts[m], c > 0 else { return nil }
            return "\(m) \(LedgerFormat.dollars(c))"
        }
        let detail = parts.isEmpty ? "" : " (\(parts.joined(separator: " · ")))"
        return "\(DetailDates.dayLabel(d.day, timeZone: data.timeZone)) — API 환산 비용 \(LedgerFormat.cost(d.total))\(detail)"
    }
}

// MARK: - Model shares

struct DetailModelList: View {
    let data: DetailData

    var body: some View {
        DetailSection(title: "모델 비중 (\(data.period.label))") {
            if data.models.isEmpty {
                DetailNotice(text: "이 기간에 집계된 기록이 없습니다")
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                    GridRow {
                        Text("모델")
                        Text("API 환산 비용").gridColumnAlignment(.trailing)
                        Text("비용 비중").gridColumnAlignment(.trailing)
                        Text("토큰").gridColumnAlignment(.trailing)
                        Text("토큰 비중").gridColumnAlignment(.trailing)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(data.models, id: \.model) { m in
                        GridRow {
                            Text(m.model).font(.system(size: 12, design: .monospaced))
                                .lineLimit(1).truncationMode(.middle)
                            Text(LedgerFormat.cost(m.total))
                                .foregroundStyle(m.total.isFullyPriced ? .primary : Color.orange)
                            Text(m.total.isFullyPriced ? DetailFormat.share(m.costShare) : "단가 미상")
                                .foregroundStyle(m.total.isFullyPriced ? .primary : Color.orange)
                            Text(LedgerFormat.count(m.total.tokens.totalTokens))
                            Text(DetailFormat.share(m.tokenShare))
                        }
                        .font(.system(size: 12).monospacedDigit())
                    }
                }
            }
        }
    }
}

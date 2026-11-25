import AppKit
import Charts
import SwiftUI

// MARK: - Window management

/// 그래프 창 두 종류 — 계정(이메일)마다 「사용률」 창 하나, 「이 맥 사용량」 창 하나.
/// SwiftUI `WindowGroup`이 아니라 AppKit으로 관리한다: 메뉴바 전용(accessory)
/// 앱이라 SwiftUI가 실행 시 창을 열거나 복원하면 안 되고, 창은 사용자가 버튼을
/// 눌렀을 때만 존재한다.
@MainActor
final class ChartWindowController: NSObject, NSWindowDelegate {
    static let shared = ChartWindowController()

    static let accountSize = NSSize(width: 760, height: 560)
    static let accountMinimum = NSSize(width: 560, height: 420)
    static let macSize = NSSize(width: 780, height: 880)
    static let macMinimum = NSSize(width: 620, height: 520)

    private var windows: [String: NSWindow] = [:]

    static func accountTitle(_ key: String) -> String { "\(key) — 사용률" }
    static let macTitle = "이 맥 사용량"

    /// 계정 사용률 창을 열거나, 이미 있으면 앞으로.
    func showAccount(key: String, poller: Poller) {
        show(id: "account:\(key)", title: Self.accountTitle(key),
             size: Self.accountSize, minimum: Self.accountMinimum) {
            AccountUsageView(key: key).environmentObject(poller)
        }
    }

    /// 이 맥 사용량 창을 열거나, 이미 있으면 앞으로.
    func showMac() {
        show(id: "mac", title: Self.macTitle, size: Self.macSize, minimum: Self.macMinimum) {
            MacUsageView()
        }
    }

    private func show<V: View>(id: String, title: String, size: NSSize, minimum: NSSize,
                               root: () -> V) {
        let window = windows[id] ?? {
            let host = NSHostingController(rootView: root())
            // 창 크기는 사용자의 것 — SwiftUI 콘텐츠 크기를 따라가지 않는다.
            host.sizingOptions = []
            let w = NSWindow(contentViewController: host)
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(size)
            w.contentMinSize = minimum
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            windows[id] = w
            return w
        }()
        window.title = title
        // accessory 앱: 활성화하지 않으면 창이 앞 앱 뒤에 열린다.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        // 창을 놓으면 호스팅 뷰(와 그 갱신 루프)도 해제된다.
        windows = windows.filter { $0.value !== window }
    }
}

extension AccountState {
    /// 사용률 이력의 계정 키 (Claude 행만) — 표본 키(`UsageSample(account:result:)`)와
    /// 같은 규칙. 로컬 행은 조회에서 해석된 이메일만 쓴다: 키체인 로그인을 따라
    /// 사람이 바뀌어 저장된 라벨은 이전 로그인의 것일 수 있다.
    var usageKey: String? {
        guard account.provider == .claude else { return nil }
        let source = account.kind == .localClaudeCLI ? snapshot?.resolvedLabel : account.email
        return AccountKey.normalize(source)
    }
}

// MARK: - Loading

/// 사용률 이력·교체 기록에서 한 계정의 창 데이터를 만든다. 차단 호출(파일 읽기)
/// — 메인 스레드 밖에서 부른다.
enum AccountUsageLoader {
    static func load(key: String, period: ChartPeriod, now: Date, activeNow: Bool,
                     timeZone: TimeZone = .current,
                     history: UsageHistoryStore = .shared,
                     rolls: RollHistoryStore = .shared) -> AccountUsageData {
        let start = ChartDay.period(count: period.days, endingAt: now, timeZone: timeZone).first?.start
        let input = AccountUsageInput(
            key: key,
            samples: history.samples(key: key, from: start, to: now),
            // 활성 구간은 기간 이전 교체에서 시작할 수 있어 전부 읽는다(파일이 작다).
            rolls: rolls.records(),
            activeNow: activeNow,
            firstSampleAt: history.firstSampleDate(key: key),
            historyStartedAt: history.firstSampleDate())
        return AccountUsageData(input: input, period: period, now: now, timeZone: timeZone)
    }
}

/// 장부에서 이 맥 사용량 창 데이터를 만든다. 차단 호출(SQLite) — 메인 스레드 밖에서.
enum MacUsageLoader {
    struct Loaded {
        var data: MacUsageData
        /// 장부 읽기 실패 (그래프는 읽은 만큼 그린다).
        var error: String?
    }

    static func load(period: ChartPeriod, now: Date,
                     ledger: UsageLedger = .shared, prices: ModelPriceSource = .shared) -> Loaded {
        let days = ChartDay.period(count: period.days, endingAt: now, timeZone: ledger.timeZone)
        var failure: String?
        var rows: [LedgerRow] = []
        var firstDay: String?
        do {
            rows = try ledger.rows(fromDay: days.first?.key ?? "", toDay: days.last?.key ?? "")
            firstDay = try ledger.firstDay()
        } catch {
            failure = "사용량 장부 읽기 실패: \(error.localizedDescription)"
        }
        let data = MacUsageData(rows: rows, period: period, now: now, timeZone: ledger.timeZone,
                                trackingStartedAt: ledger.trackingStartedAt(),
                                firstLedgerDay: firstDay, table: prices.current().table)
        return Loaded(data: data, error: failure)
    }
}

/// 창 데이터 비동기 적재 — 최신 요청만 반영(늦게 끝난 이전 요청은 버린다).
@MainActor
final class ChartLoadModel<Value>: ObservableObject {
    @Published private(set) var value: Value?
    @Published private(set) var loading = false
    @Published private(set) var loadedAt: Date?

    private var generation = 0

    func reload(_ work: @escaping @Sendable () -> Value) {
        generation += 1
        let gen = generation
        loading = true
        Task {
            let box = await Task.detached(priority: .userInitiated) { UncheckedBox(work()) }.value
            guard gen == generation else { return }
            value = box.value
            loadedAt = Date()
            loading = false
        }
    }
}

/// 백그라운드에서 만든 불변 값을 메인으로 넘기는 상자. 값은 만든 뒤 바뀌지 않는다.
private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// 열려 있는 동안 갱신 주기 (PRD: 1분 이내).
private let chartRefreshInterval: UInt64 = 60_000_000_000

// MARK: - Shared pieces

/// 고정 순서 범주 색 (dataviz 기준 팔레트, 라이트/다크 각각 검증된 단계).
enum ChartPalette {
    private static let slots: [(light: UInt32, dark: UInt32)] = [
        (0x2a78d6, 0x3987e5),  // blue
        (0xeb6834, 0xd95926),  // orange
        (0x1baf7a, 0x199e70),  // aqua
        (0xeda100, 0xc98500),  // yellow
        (0xe87ba4, 0xd55181),  // magenta
        (0x008300, 0x008300),  // green
        (0x4a3aa7, 0x9085e9),  // violet
        (0xe34948, 0xe66767),  // red
    ]

    /// 슬롯 n (0부터, 8개 고정 — 넘는 계열은 호출부가 「기타」로 접는다).
    static func slot(_ n: Int) -> Color {
        let s = slots[min(max(n, 0), slots.count - 1)]
        return Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return rgb(dark ? s.dark : s.light)
        })
    }

    static let other = Color.gray
    static let threshold = Color(nsColor: .systemRed)

    private static func rgb(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
}

/// 기간 선택 · 갱신 시각 · 새로고침 줄.
struct ChartHeader: View {
    @Binding var period: ChartPeriod
    let loading: Bool
    let loadedAt: Date?
    let refreshHelp: String
    let onRefresh: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Picker("기간", selection: $period) {
                ForEach(ChartPeriod.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Spacer()

            if loading {
                ProgressView().controlSize(.small)
            }
            if let at = loadedAt {
                Text("갱신 \(at, style: .time)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help(refreshHelp)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

struct ChartSection<Content: View>: View {
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

struct ChartNotice: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 80)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// 그래프 위 호버 값 줄 — 높이 고정이라 그래프가 흔들리지 않는다.
struct ChartHoverLine: View {
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

struct ChartTile: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
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

enum ChartDayAxis {
    static func marks(_ period: ChartPeriod) -> some AxisContent {
        AxisMarks(values: .stride(by: .day, count: ChartFormat.dayStride(period))) { _ in
            AxisGridLine()
            AxisValueLabel(format: .dateTime.month(.defaultDigits).day(), centered: true)
        }
    }
}

// MARK: - 계정 사용률 창

struct AccountUsageView: View {
    let key: String
    @EnvironmentObject var poller: Poller
    @StateObject private var model = ChartLoadModel<AccountUsageData>()
    @State private var period = ChartPeriod.default

    /// 지금 팝오버에 보이는 이 계정의 행 (현재 값·리셋 표시용).
    private var liveState: AccountState? {
        poller.visibleStates.first { $0.usageKey == key }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ChartHeader(period: $period, loading: model.loading, loadedAt: model.loadedAt,
                        refreshHelp: "지금 새로고침 — 사용률 이력과 교체 기록을 다시 읽습니다",
                        onRefresh: reload)
            Divider()
            if let data = model.value {
                ScrollView {
                    AccountUsageContent(data: data, snapshot: liveState?.snapshot,
                                        hasLiveRow: liveState != nil)
                        .padding(16)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: ChartWindowController.accountMinimum.width,
               minHeight: ChartWindowController.accountMinimum.height)
        // 기간이 바뀌면 루프가 다시 시작돼 즉시 다시 읽는다. 창이 닫히면 취소.
        .task(id: period) {
            while !Task.isCancelled {
                reload()
                try? await Task.sleep(nanoseconds: chartRefreshInterval)
            }
        }
        // 폴링 결과가 이력에 쌓인 뒤 다시 읽는다.
        .onChange(of: poller.lastRefresh) { reload() }
    }

    private func reload() {
        let key = key, period = period
        let activeNow = poller.states.contains {
            $0.account.kind == .localClaudeCLI && $0.usageKey == key
        }
        model.reload {
            AccountUsageLoader.load(key: key, period: period, now: Date(), activeNow: activeNow)
        }
    }
}

/// 계정 사용률 창 본문 — `AccountUsageData`의 순수 렌더 (스크린샷에도 쓴다).
struct AccountUsageContent: View {
    let data: AccountUsageData
    /// 팝오버 행의 실시간 스냅샷 (현재 7d·5h·리셋).
    let snapshot: UsageSnapshot?
    let hasLiveRow: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AccountUsageSummary(data: data, snapshot: snapshot, hasLiveRow: hasLiveRow)
            AccountUsageChart(data: data).equatable()
            Text("토큰·비용은 계정별로 나누지 않습니다 — 팝오버의 『이 맥 사용량』에서 볼 수 있습니다")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AccountUsageSummary: View {
    let data: AccountUsageData
    let snapshot: UsageSnapshot?
    let hasLiveRow: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            if let seven = snapshot?.sevenDay { window("7d", seven) }
            if let five = snapshot?.fiveHour { window("5h", five) }
            if snapshot?.sevenDay == nil && snapshot?.fiveHour == nil {
                Text(hasLiveRow ? "현재 값 불러오는 중…" : "팝오버에 이 계정 행이 없어 현재 값이 없습니다 — 기록만 표시합니다")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let peak = data.peakSevenDay {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(data.period.label) 7d 최고").font(.caption).foregroundStyle(.secondary)
                    Text(ChartFormat.percent(peak.percent))
                        .font(.system(size: 15, weight: .semibold).monospacedDigit())
                        .help(ChartFormat.timeLabel(peak.ts, timeZone: data.timeZone))
                }
            }
        }
    }

    private func window(_ name: String, _ usage: WindowUsage) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(name)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(ChartFormat.percent(usage.percent))
                .font(.system(size: 22, weight: .semibold).monospacedDigit())
            if let resets = usage.resetsAt {
                Text("리셋까지 \(UsageGauge.countdown(to: resets))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// 그래프 호버 값 — 그래프 본체는 이것을 관찰하지 않고(`@State`로 참조만 쥔다),
/// 호버 줄·선택 표시 같은 작은 뷰만 관찰한다. 마우스가 움직여도 수백 개의 선
/// 마크를 다시 만들지 않는다.
@MainActor
final class ChartHoverState<Value: Equatable>: ObservableObject {
    @Published private(set) var value: Value?

    /// 값이 바뀔 때만 알린다 — 같은 구간 안의 마우스 이동은 아무것도 다시 그리지 않는다.
    func set(_ new: Value?) {
        if new != value { value = new }
    }
}

struct AccountUsageChart: View, Equatable {
    let data: AccountUsageData
    @State private var hover = ChartHoverState<AccountUsageData.Hover>()

    private static let rolledIn = "이 계정으로 교체"
    private static let rolledOut = "다른 계정으로 교체"

    /// 데이터가 같으면 다시 그리지 않는다 — 창은 폴링 결과마다(계정별 3분) 다시
    /// 그려지는데, 그래프 데이터는 1분 갱신 때만 바뀐다.
    nonisolated static func == (a: Self, b: Self) -> Bool { a.data == b.data }

    /// 범례 계열 — 있는 것만 (없는 계열이 범례에 남지 않게).
    private var series: [(String, Color)] {
        var out: [(String, Color)] = [("7d", ChartPalette.slot(0))]
        if data.hasFiveHour { out.append(("5h", ChartPalette.slot(1))) }
        if data.rollEvents.contains(where: { $0.direction == .rolledIn }) {
            out.append((Self.rolledIn, ChartPalette.slot(2)))
        }
        if data.rollEvents.contains(where: { $0.direction == .rolledOut }) {
            out.append((Self.rolledOut, ChartPalette.slot(6)))
        }
        return out
    }

    var body: some View {
        ChartSection(title: "사용률 추이") {
            if let notice = data.emptyNotice {
                ChartNotice(text: notice)
            } else {
                AccountUsageHoverLine(timeZone: data.timeZone, hover: hover)
                chart
                    .frame(minHeight: 220)
                legendNotes
            }
        }
        // 기간이 바뀌면 이전 기간의 호버 값을 버린다.
        .onChange(of: data.period) { hover.set(nil) }
    }

    private var chart: some View {
        Chart {
            ForEach(Array(data.activeIntervals.enumerated()), id: \.offset) { _, span in
                RectangleMark(
                    xStart: .value("시작", span.start), xEnd: .value("끝", span.end),
                    yStart: .value("하단", 0), yEnd: .value("상단", 100))
                    .foregroundStyle(Color.primary.opacity(0.06))
            }
            ForEach(data.rollEvents) { e in
                RuleMark(x: .value("교체", e.ts))
                    .foregroundStyle(by: .value("구분", e.direction == .rolledIn ? Self.rolledIn : Self.rolledOut))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
            }
            ForEach(data.usage) { p in
                LineMark(x: .value("시각", p.ts), y: .value("사용률", p.percent),
                         series: .value("조각", p.series))
                    .foregroundStyle(by: .value("구분", p.window.rawValue))
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            ForEach(data.isolated) { p in
                PointMark(x: .value("시각", p.ts), y: .value("사용률", p.percent))
                    .foregroundStyle(by: .value("구분", p.window.rawValue))
                    .symbolSize(16)
            }
            RuleMark(y: .value("롤링 임계", RollingEngine.threshold))
                .foregroundStyle(ChartPalette.threshold.opacity(0.8))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .annotation(position: .bottom, alignment: .leading) {
                    Text("롤링 \(Int(RollingEngine.threshold))%").font(.caption2).foregroundStyle(.secondary)
                }
        }
        .chartForegroundStyleScale(domain: series.map(\.0), range: series.map(\.1))
        .chartLegend(series.count > 1 ? .visible : .hidden)
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(values: [0, 25, 50, 75, 100]) { v in
                AxisGridLine()
                AxisValueLabel { Text("\(v.as(Int.self) ?? 0)%") }
            }
        }
        .chartXScale(domain: data.rangeStart...data.rangeEnd)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: ChartFormat.dayStride(data.period))) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
            }
        }
        // 호버는 그래프 위 별도 층 — `chartXSelection`은 선택 표시를 같은 `Chart`
        // 안에 그려야 해서 마우스 이동마다 모든 마크를 다시 만든다.
        .chartOverlay { proxy in
            GeometryReader { geo in
                AccountUsageHoverLayer(data: data, proxy: proxy,
                                       plot: proxy.plotFrame.map { geo[$0] } ?? .zero, hover: hover)
            }
        }
    }

    @ViewBuilder
    private var legendNotes: some View {
        Text(ChartFormat.bucketNote(data.period))
            .font(.caption2).foregroundStyle(.secondary)
        if !data.activeIntervals.isEmpty {
            Text("옅은 띠 = 교체 기록으로 확인된 이 계정의 활성 구간")
                .font(.caption2).foregroundStyle(.secondary)
        }
        if !data.rollEvents.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("교체 시점 (\(data.period.label))").font(.caption).foregroundStyle(.secondary)
                ForEach(data.rollEvents.suffix(8).reversed()) { e in
                    Text(ChartFormat.rollEvent(e, timeZone: data.timeZone))
                        .font(.caption2.monospacedDigit())
                        .lineLimit(1).truncationMode(.middle)
                }
                if data.rollEvents.count > 8 {
                    Text("… 외 \(data.rollEvents.count - 8)건").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
        }
    }
}

/// 계정 사용률 호버 줄 — 호버 값만 관찰한다.
private struct AccountUsageHoverLine: View {
    let timeZone: TimeZone
    @ObservedObject var hover: ChartHoverState<AccountUsageData.Hover>

    var body: some View {
        ChartHoverLine(text: hover.value.map { ChartFormat.usageHover($0, timeZone: timeZone) })
    }
}

/// 계정 사용률 그래프 위 호버 층: 마우스 위치 → 호버 값, 선택 세로선·점 표시.
private struct AccountUsageHoverLayer: View {
    let data: AccountUsageData
    let proxy: ChartProxy
    /// 그래프 영역 (이 층의 좌표계).
    let plot: CGRect
    @ObservedObject var hover: ChartHoverState<AccountUsageData.Hover>

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let at):
                        guard at.x >= plot.minX, at.x <= plot.maxX,
                              let date = proxy.value(atX: at.x - plot.minX, as: Date.self)
                        else { return hover.set(nil) }
                        hover.set(data.hover(at: date))
                    case .ended:
                        hover.set(nil)
                    }
                }
            if let h = hover.value {
                marker(h).allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func marker(_ h: AccountUsageData.Hover) -> some View {
        if let x = proxy.position(forX: h.anchor) {
            Path { p in
                p.move(to: CGPoint(x: plot.minX + x, y: plot.minY))
                p.addLine(to: CGPoint(x: plot.minX + x, y: plot.maxY))
            }
            .stroke(Color.secondary.opacity(0.5), lineWidth: 1)
        }
        ForEach(h.points) { p in
            if let x = proxy.position(forX: p.ts), let y = proxy.position(forY: p.percent) {
                Circle()
                    .fill(Color.primary)
                    .frame(width: 8, height: 8)
                    .position(x: plot.minX + x, y: plot.minY + y)
            }
        }
    }
}

// MARK: - 이 맥 사용량 창

struct MacUsageView: View {
    @ObservedObject private var scanner = LedgerScanner.shared
    @StateObject private var model = ChartLoadModel<MacUsageLoader.Loaded>()
    @State private var period = ChartPeriod.default
    @State private var includeCacheRead = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ChartHeader(period: $period, loading: model.loading, loadedAt: model.loadedAt,
                        refreshHelp: "지금 새로고침 — 세션 기록을 바로 집계하고 다시 읽습니다") {
                // 새 줄이 집계되면 `updatedAt`이 바뀌어 한 번 더 다시 읽는다.
                scanner.scanIfDue(force: true)
                reload()
            }
            Divider()
            if let loaded = model.value {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if let error = loaded.error {
                            Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        }
                        MacUsageContent(data: loaded.data, includeCacheRead: $includeCacheRead)
                    }
                    .padding(16)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: ChartWindowController.macMinimum.width,
               minHeight: ChartWindowController.macMinimum.height)
        .task(id: period) {
            while !Task.isCancelled {
                reload()
                try? await Task.sleep(nanoseconds: chartRefreshInterval)
            }
        }
        .onChange(of: scanner.updatedAt) { reload() }
    }

    private func reload() {
        let period = period
        model.reload { MacUsageLoader.load(period: period, now: Date()) }
    }
}

/// 이 맥 사용량 창 본문 — `MacUsageData`의 순수 렌더 (스크린샷에도 쓴다).
struct MacUsageContent: View {
    let data: MacUsageData
    @Binding var includeCacheRead: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            MacUsageSummary(data: data)
            if data.hasLedgerHistory {
                MacTokenChart(data: data, includeCacheRead: $includeCacheRead)
                MacCostChart(data: data)
                MacModelList(data: data)
            } else {
                ChartNotice(text: ChartFormat.noLedgerNotice(
                    trackingStartedAt: data.trackingStartedAt, timeZone: data.timeZone))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MacUsageSummary: View {
    let data: MacUsageData

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("이 맥에서 실행된 claude 전체(계정 구분 없음)")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Text(data.trackingStartedAt.map { "집계 시작 \(DayFormatter(timeZone: data.timeZone).string($0))" }
                     ?? "집계 시작 전")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("사용량 장부가 처음 켜진 시각 — 그 이전 세션 기록은 집계하지 않습니다")
            }
            HStack(alignment: .top, spacing: 12) {
                ChartTile(title: "\(data.period.label) 합계 토큰",
                          value: LedgerFormat.count(data.periodTotal.tokens.totalTokens),
                          detail: ChartFormat.breakdown(data.periodTotal.tokens))
                ChartTile(title: "\(data.period.label) 합계 API 환산 비용",
                          value: LedgerFormat.cost(data.periodTotal),
                          detail: "같은 토큰을 API 정가로 계산한 값 — 구독 청구액이 아닙니다")
                ChartTile(title: "오늘",
                          value: "\(LedgerFormat.count(data.today.tokens.totalTokens)) 토큰",
                          detail: "API 환산 비용 \(LedgerFormat.cost(data.today))")
            }
        }
    }
}

struct MacTokenChart: View {
    let data: MacUsageData
    @Binding var includeCacheRead: Bool
    @State private var selected: Date?

    private static func color(_ kind: TokenKind) -> Color {
        ChartPalette.slot(TokenKind.allCases.firstIndex(of: kind) ?? 0)
    }

    var body: some View {
        let kinds = TokenKind.visible(includeCacheRead: includeCacheRead)
        ChartSection(title: "일별 토큰", trailing: AnyView(
            Toggle("캐시 읽기 포함", isOn: $includeCacheRead)
                .toggleStyle(.checkbox)
                .font(.caption)
                .help("캐시 읽기는 다른 구분보다 수십 배 큰 경우가 많아 기본으로 막대에서 뺍니다"))
        ) {
            ChartHoverLine(text: hoverText)
            Chart {
                ForEach(data.tokenBars(includeCacheRead: includeCacheRead)) { b in
                    BarMark(x: .value("날짜", b.day.start, unit: .day), y: .value("토큰", b.value))
                        .foregroundStyle(by: .value("구분", b.kind.label))
                }
                if let d = selectedDay {
                    RuleMark(x: .value("선택", d.day.start, unit: .day))
                        .foregroundStyle(Color.secondary.opacity(0.2))
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
            .chartXAxis { ChartDayAxis.marks(data.period) }
            .chartXScale(domain: data.rangeStart...data.rangeEnd)
            .chartXSelection(value: $selected)
            .frame(height: 190)
        }
    }

    private var selectedDay: MacUsageData.DayTotal? { selected.flatMap { data.dayTotal(at: $0) } }

    private var hoverText: String? {
        guard let d = selectedDay else { return nil }
        let t = d.total.tokens
        let shown = TokenKind.sum(t, includeCacheRead: includeCacheRead)
        return "\(ChartFormat.dayLabel(d.day, timeZone: data.timeZone)) — 막대 \(LedgerFormat.count(shown)) (\(ChartFormat.breakdown(t)))"
    }
}

struct MacCostChart: View {
    let data: MacUsageData
    @State private var selected: Date?

    /// 색은 모델 이름순 슬롯 — 비용 순위가 바뀌어도 같은 모델은 같은 색.
    private var colors: [Color] {
        let named = data.chartModels.filter { $0 != MacUsageData.otherModels }.sorted()
        return data.chartModels.map { m in
            m == MacUsageData.otherModels ? ChartPalette.other : ChartPalette.slot(named.firstIndex(of: m) ?? 0)
        }
    }

    var body: some View {
        ChartSection(title: "일별 API 환산 비용") {
            if data.chartModels.isEmpty {
                ChartNotice(text: data.isEmptyPeriod
                            ? "이 기간에 집계된 기록이 없습니다"
                            : "이 기간의 기록은 모두 단가 미상 모델입니다 — 토큰만 집계됩니다")
            } else {
                ChartHoverLine(text: hoverText)
                Chart {
                    ForEach(data.costBars) { b in
                        BarMark(x: .value("날짜", b.day.start, unit: .day), y: .value("API 환산 비용", b.cost))
                            .foregroundStyle(by: .value("모델", b.model))
                    }
                    if let d = selectedDay {
                        RuleMark(x: .value("선택", d.day.start, unit: .day))
                            .foregroundStyle(Color.secondary.opacity(0.2))
                            .lineStyle(StrokeStyle(lineWidth: 8))
                    }
                }
                .chartForegroundStyleScale(domain: data.chartModels, range: colors)
                .chartYAxis {
                    AxisMarks { v in
                        AxisGridLine()
                        AxisValueLabel { Text(ChartFormat.axisDollars(v.as(Double.self) ?? 0)) }
                    }
                }
                .chartXAxis { ChartDayAxis.marks(data.period) }
                .chartXScale(domain: data.rangeStart...data.rangeEnd)
                .chartXSelection(value: $selected)
                .frame(height: 190)
            }
            if !data.periodTotal.isFullyPriced {
                Text("단가 미상 모델(\(data.periodTotal.unpricedModels.sorted().joined(separator: ", ")))은 금액에서 빠져 있습니다 — 토큰은 집계됩니다")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var selectedDay: MacUsageData.DayTotal? { selected.flatMap { data.dayTotal(at: $0) } }

    private var hoverText: String? {
        guard let d = selectedDay else { return nil }
        let parts = data.chartModels.compactMap { m -> String? in
            guard let c = d.modelCosts[m], c > 0 else { return nil }
            return "\(m) \(LedgerFormat.dollars(c))"
        }
        let detail = parts.isEmpty ? "" : " (\(parts.joined(separator: " · ")))"
        return "\(ChartFormat.dayLabel(d.day, timeZone: data.timeZone)) — API 환산 비용 \(LedgerFormat.cost(d.total))\(detail)"
    }
}

struct MacModelList: View {
    let data: MacUsageData

    var body: some View {
        ChartSection(title: "모델 비중 (\(data.period.label))") {
            if data.models.isEmpty {
                ChartNotice(text: "이 기간에 집계된 기록이 없습니다")
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
                            Text(m.total.isFullyPriced ? ChartFormat.share(m.costShare) : "단가 미상")
                                .foregroundStyle(m.total.isFullyPriced ? .primary : .secondary)
                            Text(LedgerFormat.count(m.total.tokens.totalTokens))
                            Text(ChartFormat.share(m.tokenShare))
                        }
                        .font(.system(size: 12).monospacedDigit())
                    }
                }
            }
        }
    }
}

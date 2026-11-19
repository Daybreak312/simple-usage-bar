import Foundation
import SwiftUI

@MainActor
final class Poller: ObservableObject {
    static let shared = Poller()

    @Published var states: [AccountState] = []
    @Published var lastRefresh: Date?
    /// Claude account in the active-account file (the one usagebar-claude
    /// launches with). Re-read every tick so CLI `roll` shows up quickly.
    @Published var activeAccountId: UUID?

    /// Per-account poll interval, flat regardless of utilization (default 3 minutes).
    var normalInterval: TimeInterval {
        let v = UserDefaults.standard.double(forKey: "pollIntervalSeconds")
        return v >= 30 ? v : 180
    }

    private let store = AccountStore.shared
    private let active = ActiveAccountStore.shared
    private let history = UsageHistoryStore.shared
    private let feed = ClaudeEventFeed.shared
    private let ledger = UsageLedger.shared
    /// Last time the usage ledger scan started (once a minute at most).
    private var lastLedgerScan: Date?
    private var ledgerScanRunning = false
    /// When the usage ledger last finished a scan that added something —
    /// views showing ledger data refresh on change.
    @Published var ledgerUpdatedAt: Date?
    /// Last daily rotation/retention pass over the wrapper logs.
    private var lastLogMaintenance: Date?
    private var loopTask: Task<Void, Never>?
    /// Last seen utilization per account, for threshold-crossing detection.
    /// nil entry = no baseline yet (first poll after launch never alerts).
    private var prevPercents: [UUID: (five: Double?, seven: Double?)] = [:]
    /// Per-account next poll time — each account runs its own cadence.
    private var nextDue: [UUID: Date] = [:]

    /// Account pinned to the menu bar label; nil = worst across all accounts.
    @Published var pinnedAccountId: UUID?
    /// Which window(s) the menu bar label shows.
    @Published var menuBarWindow: MenuBarWindow = .both

    func start() {
        reloadAccounts()
        let settings = SettingsStore.shared.load()
        pinnedAccountId = settings.menuBarAccountId.flatMap(UUID.init(uuidString:))
        menuBarWindow = settings.menuBarWindow.flatMap(MenuBarWindow.init(rawValue:)) ?? .both
        loopTask?.cancel()
        reloadActive()
        loopTask = Task { [weak self] in
            await self?.refreshAll()
            // 15s tick; each account fires when its own due time passes.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                self?.reloadActive()
                await self?.ingestWrapperEvents()
                self?.scanLedgerIfDue()
                await self?.refreshDue()
            }
        }
    }

    func reloadAccounts() {
        let accounts = store.loadAccounts()
        // Preserve existing snapshots when the account list changes.
        var existing = Dictionary(uniqueKeysWithValues: states.map { ($0.account.id, $0) })
        states = accounts.map { account in
            if var state = existing.removeValue(forKey: account.id) {
                state.account = account
                return state
            }
            return AccountState(account: account)
        }
    }

    func reloadActive() {
        let id = active.read()?.accountId
        if id != activeAccountId { activeAccountId = id }
    }

    /// Legacy Claude rows (OAuth / local CLI) are listed but never polled —
    /// they show "1년 토큰으로 재등록 필요" instead.
    private func isPolled(_ state: AccountState) -> Bool {
        !state.account.needsReregistration
    }

    func refreshAll() async {
        await refresh(states.filter(isPolled))
    }

    /// Refresh accounts whose individual due time has passed.
    private func refreshDue() async {
        let now = Date()
        let due = states.filter {
            isPolled($0) && (nextDue[$0.account.id] ?? .distantPast) <= now
        }
        guard !due.isEmpty else { return }
        await refresh(due)
    }

    private func refresh(_ targets: [AccountState]) async {
        let snapshot = targets
        await withTaskGroup(of: (UUID, Result<UsageSnapshot, Error>).self) { group in
            for state in snapshot {
                group.addTask {
                    do {
                        let usage = try await provider(for: state.account.provider)
                            .fetchUsage(account: state.account, store: AccountStore.shared)
                        return (state.account.id, .success(usage))
                    } catch {
                        return (state.account.id, .failure(error))
                    }
                }
            }
            for await (id, result) in group {
                guard let idx = states.firstIndex(where: { $0.account.id == id }) else { continue }
                var delay = normalInterval
                switch result {
                case .success(let usage):
                    states[idx].snapshot = usage
                    states[idx].lastError = nil
                    states[idx].staleNote = nil
                    if states[idx].account.isClaudeToken {
                        history.record(UsageSample(accountId: id, snapshot: usage))
                        if let org = usage.organizationId,
                           org != states[idx].account.organizationId {
                            states[idx].account.organizationId = org
                            try? store.updateOrganizationId(for: id, org)
                        }
                    }
                case .failure(let error):
                    // 429는 일시 스로틀 — 이전 스냅샷이 있으면 그대로 두고
                    // 라벨 옆에 지연 표시만 한다. 서버가 Retry-After를 주면
                    // 그 계정의 다음 조회를 그만큼 미룬다 (최소 3분, 30분 캡).
                    if case UsageBarError.rateLimited(let after) = error {
                        if let after {
                            delay = min(max(after, normalInterval), 1800)
                        }
                        if states[idx].snapshot != nil {
                            states[idx].staleNote = delay > normalInterval
                                ? "429로 인해 지연됨 · 재시도 \(Int((delay / 60).rounded()))분 뒤"
                                : "429로 인해 지연됨"
                            states[idx].lastError = nil
                        } else {
                            states[idx].lastError = error.localizedDescription
                            states[idx].staleNote = nil
                        }
                    } else {
                        states[idx].lastError = error.localizedDescription
                        states[idx].staleNote = nil
                    }
                }
                nextDue[id] = Date().addingTimeInterval(delay)
            }
        }
        lastRefresh = Date()
        fireThresholdAlerts()

        // Rolling only swaps the active-account file; every account keeps its
        // own poll, so no follow-up refresh is needed.
        _ = await RollingEngine.evaluate(states: states, store: store)
        reloadActive()
    }

    // MARK: - Wrapper events (usagebar-claude → events.jsonl)

    /// Fold new wrapper events into the board: each `rate_limit` is a usage
    /// sample (and refreshes the snapshot when newer than the last probe); a
    /// refusal on the active account (`rejected` / limit text) rolls at once.
    /// Also runs the daily rotation of the wrapper logs.
    func ingestWrapperEvents(now: Date = Date()) async {
        let feed = self.feed
        let maintain = lastLogMaintenance.map { now.timeIntervalSince($0) >= 86_400 } ?? true
        if maintain { lastLogMaintenance = now }
        let events = await Task.detached(priority: .utility) { () -> [WrapperEvent] in
            var out = feed.readNew()
            if maintain {
                out += feed.maintain(now: now)
                JSONLinesRotation.maintain(AppPaths.launchesURL, now: now)
            }
            return out
        }.value
        guard !events.isEmpty else { return }

        let accounts = states.map(\.account)
        var hashes: [String: UUID]?
        let activeId = active.read()?.accountId
        var changed = false
        var refusal: WrapperEvent?
        for event in events {
            if event.accountId == nil || !accounts.contains(where: { $0.id == event.accountId }) {
                hashes = hashes ?? tokenHashes(accounts)
            }
            guard let id = WrapperEventRules.resolve(event, accounts: accounts, hashes: hashes ?? [:]),
                  let idx = states.firstIndex(where: { $0.account.id == id }) else { continue }
            if case .rateLimit(let status, _, _, let five, let seven) = event.kind, five != nil || seven != nil {
                history.record(UsageSample(accountId: id, ts: event.ts, sevenDay: seven?.percent,
                                           fiveHour: five?.percent, status: status))
            }
            if let snap = WrapperEventRules.apply(event, to: states[idx].snapshot) {
                states[idx].snapshot = snap
                states[idx].staleNote = nil
                changed = true
            }
            if WrapperEventRules.triggersImmediateRoll(event, accountId: id, activeId: activeId, now: now) {
                refusal = event
            }
        }
        var rolled = false
        if let refusal {
            let why: String
            if case .limitText = refusal.kind { why = "한도 문구" } else { why = "한도 거절" }
            rolled = await RollingEngine.evaluateImmediate(
                states: states, store: store, reason: "\(why) — 실행 중 claude 관측")
        }
        if !rolled, changed {
            // 이벤트로 갱신된 지표에도 정기 규칙(임계 95%·쿨다운)을 그대로 적용.
            _ = await RollingEngine.evaluate(states: states, store: store)
        }
        if changed { fireThresholdAlerts() }
        reloadActive()
    }

    // MARK: - Usage ledger (session logs → tokens / API 환산 비용)

    /// Minimum gap between scan starts. With the 15 s tick this lands on a
    /// scan every 60 s (PRD: 1분 이내).
    static let ledgerInterval: TimeInterval = 45

    /// Kick off one background ledger scan (and the daily price-table
    /// refresh) when due. The scan does blocking file and SQLite I/O, so it
    /// runs on a GCD utility queue — never on the main thread or the Swift
    /// concurrency pool; the tick never waits on it.
    func scanLedgerIfDue(now: Date = Date()) {
        guard !ledgerScanRunning,
              lastLedgerScan.map({ now.timeIntervalSince($0) >= Self.ledgerInterval }) ?? true else { return }
        lastLedgerScan = now
        ledgerScanRunning = true
        let hashes = tokenHashes(states.map(\.account))
        let ledger = self.ledger
        Task { [weak self] in
            let added: Bool = await withCheckedContinuation { done in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        done.resume(returning: try ledger.ingest(hashes: hashes).counted > 0)
                    } catch {
                        FileHandle.standardError.write(Data("사용량 장부 집계 실패: \(error.localizedDescription)\n".utf8))
                        done.resume(returning: false)
                    }
                }
            }
            let repriced = await ModelPriceSource.shared.refreshIfStale()
            self?.ledgerScanFinished(changed: added || repriced)
        }
    }

    private func ledgerScanFinished(changed: Bool) {
        ledgerScanRunning = false
        if changed || ledgerUpdatedAt == nil { ledgerUpdatedAt = Date() }
    }

    /// tokenHash → 1-year-token account, for launches that ran with a
    /// caller-supplied token instead of the active file.
    private func tokenHashes(_ accounts: [Account]) -> [String: UUID] {
        var out: [String: UUID] = [:]
        for a in accounts where a.isClaudeToken {
            if let token = store.secrets(for: a.id)?.accessToken, !token.isEmpty {
                out[ClaudeProvider.tokenHash(token)] = a.id
            }
        }
        return out
    }

    /// Compare against the previous poll and push webhook alerts for every
    /// 50/70/80/90% upward crossing. Window resets lower the baseline, so the
    /// next climb re-alerts naturally.
    private func fireThresholdAlerts() {
        var alerts: [(header: String, state: AccountState)] = []
        for state in states where isPolled(state) {
            guard state.lastError == nil, let snap = state.snapshot else { continue }
            let newFive = snap.fiveHour?.percent
            let newSeven = snap.sevenDay?.percent
            if let prev = prevPercents[state.account.id] {
                if let t = AlertThresholds.crossed(old: prev.five, new: newFive) {
                    alerts.append(("[!] 5h 사용량 \(Int(t))% - \(state.account.label)", state))
                }
                if let t = AlertThresholds.crossed(old: prev.seven, new: newSeven) {
                    alerts.append(("[!] 7d 사용량 \(Int(t))% - \(state.account.label)", state))
                }
            }
            prevPercents[state.account.id] = (newFive, newSeven)
        }
        guard !alerts.isEmpty else { return }

        // Native notification: always, webhook과 동일 시점.
        for (header, state) in alerts {
            // Claude Ultra plans have no 5h window — skip the empty gauge.
            let five = state.account.provider == .claude && state.snapshot?.fiveHour == nil
                ? nil : TUIFormat.gauge("5h", state.snapshot?.fiveHour)
            let summary = [five, TUIFormat.gauge("7d", state.snapshot?.sevenDay)]
                .compactMap { $0 }.joined(separator: "  ")
            LocalNotifier.send(title: header, body: summary)
        }

        // Webhook: only when configured.
        guard !SettingsStore.shared.load().isEmpty else { return }
        let board = states
        let headers = alerts.map(\.header)
        Task.detached(priority: .utility) {
            for header in headers {
                _ = await AlertSender.send(header: header, states: board)
            }
        }
    }

    /// Per-window values for the menu bar: pinned account if set (and still
    /// registered), otherwise the worst across all accounts per window.
    private var displayValues: (five: Double?, seven: Double?) {
        if let pinned = pinnedAccountId,
           let state = states.first(where: { $0.account.id == pinned }) {
            return (state.snapshot?.fiveHour?.percent, state.snapshot?.sevenDay?.percent)
        }
        let visible = states.filter(isPolled)
        return (
            visible.compactMap { $0.snapshot?.fiveHour?.percent }.max(),
            visible.compactMap { $0.snapshot?.sevenDay?.percent }.max()
        )
    }

    /// Menu bar label text per the configured window mode. "둘 다" is 5h/7d.
    var menuBarText: String? {
        func fmt(_ v: Double?) -> String { v.map { "\(Int($0))%" } ?? "—" }
        let v = displayValues
        switch menuBarWindow {
        case .five: return v.five.map { "\(Int($0))%" }
        case .seven: return v.seven.map { "\(Int($0))%" }
        case .both:
            if v.five == nil && v.seven == nil { return nil }
            return "\(fmt(v.five)) \(fmt(v.seven))"
        }
    }

    /// Severity driving the menu bar icon: worst of the displayed values.
    var menuBarSeverity: Double? {
        let v = displayValues
        switch menuBarWindow {
        case .five: return v.five
        case .seven: return v.seven
        case .both: return [v.five, v.seven].compactMap { $0 }.max()
        }
    }

    /// Pin/unpin an account to the menu bar label (persisted).
    func setPinned(_ id: UUID?) {
        pinnedAccountId = id
        var settings = SettingsStore.shared.load()
        settings.menuBarAccountId = id?.uuidString
        try? SettingsStore.shared.save(settings)
    }

    /// Choose which window(s) the menu bar shows (persisted).
    func setMenuBarWindow(_ window: MenuBarWindow) {
        menuBarWindow = window
        var settings = SettingsStore.shared.load()
        settings.menuBarWindow = window.rawValue
        try? SettingsStore.shared.save(settings)
    }
}

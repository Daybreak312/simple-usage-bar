import Foundation
import SwiftUI

@MainActor
final class Poller: ObservableObject {
    static let shared = Poller()

    @Published var states: [AccountState] = []
    @Published var lastRefresh: Date?

    /// Per-account poll interval, flat regardless of utilization (default 3 minutes).
    var normalInterval: TimeInterval {
        let v = UserDefaults.standard.double(forKey: "pollIntervalSeconds")
        return v >= 30 ? v : 180
    }

    private let store = AccountStore.shared
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
        loopTask = Task { [weak self] in
            await self?.refreshAll()
            // 15s tick; each account fires when its own due time passes.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
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

    /// A Claude storedToken row duplicating the current local login is
    /// "shadowed": hidden and never polled. The local row already covers that
    /// account, and skipping its own refresh keeps the app from racing Claude
    /// Code over the token lineage (rolling ownership protocol).
    func isShadowed(_ state: AccountState) -> Bool {
        guard state.account.provider == .claude, state.account.kind == .storedToken,
              let local = states.first(where: {
                  $0.account.provider == .claude && $0.account.kind == .localClaudeCLI
              }) else { return false }
        return state.account.email.caseInsensitiveCompare(local.account.email) == .orderedSame
    }

    /// Rows shown in the popover / boards — shadowed duplicates excluded.
    var visibleStates: [AccountState] { states.filter { !isShadowed($0) } }

    func refreshAll() async {
        await refresh(states.filter { !isShadowed($0) })
    }

    /// Refresh accounts whose individual due time has passed.
    private func refreshDue() async {
        let now = Date()
        let due = states.filter {
            !isShadowed($0) && (nextDue[$0.account.id] ?? .distantPast) <= now
        }
        guard !due.isEmpty else { return }
        await refresh(due)
    }

    private func refresh(_ targets: [AccountState]) async {
        let snapshot = targets
        var identityChanged = false
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
                    // Follow the identity seen on this fetch (local-CLI login
                    // can switch accounts anytime). Re-baseline alerts so the
                    // switch itself never reads as a threshold crossing.
                    if let resolved = usage.resolvedLabel,
                       resolved != states[idx].account.label {
                        states[idx].account.label = resolved
                        try? store.updateLabel(for: id, resolved)
                        prevPercents[id] = nil
                        identityChanged = true
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
        // Identity switch (manual /login or a roll) may have created/retired
        // rows on disk (e.g. CLI-side harvest) — resync from the store.
        if identityChanged { reloadAccounts() }
        lastRefresh = Date()
        fireThresholdAlerts()

        if await RollingEngine.evaluate(states: visibleStates, store: store) {
            // Rolled: pick up harvested rows and re-read the keychain identity
            // right away. The follow-up refresh can't roll again (cooldown).
            reloadAccounts()
            let locals = states.filter {
                $0.account.provider == .claude && $0.account.kind == .localClaudeCLI
            }
            if !locals.isEmpty { await refresh(locals) }
        }
    }

    /// Compare against the previous poll and push webhook alerts for every
    /// 50/70/80/90% upward crossing. Window resets lower the baseline, so the
    /// next climb re-alerts naturally.
    private func fireThresholdAlerts() {
        var alerts: [(header: String, state: AccountState)] = []
        for state in states where isShadowed(state) {
            // Drop stale baselines so un-shadowing later starts fresh instead
            // of "crossing" thresholds against months-old numbers.
            prevPercents.removeValue(forKey: state.account.id)
        }
        for state in states where !isShadowed(state) {
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
            let summary = [
                TUIFormat.gauge("5h", state.snapshot?.fiveHour),
                TUIFormat.gauge("7d", state.snapshot?.sevenDay),
            ].joined(separator: "  ")
            LocalNotifier.send(title: header, body: summary)
        }

        // Webhook: only when configured.
        guard !SettingsStore.shared.load().isEmpty else { return }
        let board = visibleStates
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
        let visible = visibleStates
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

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

    func refreshAll() async {
        await refresh(states)
    }

    /// Refresh accounts whose individual due time has passed.
    private func refreshDue() async {
        let now = Date()
        let due = states.filter { (nextDue[$0.account.id] ?? .distantPast) <= now }
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
                switch result {
                case .success(let usage):
                    states[idx].snapshot = usage
                    states[idx].lastError = nil
                    // Follow the identity seen on this fetch (local-CLI login
                    // can switch accounts anytime). Re-baseline alerts so the
                    // switch itself never reads as a threshold crossing.
                    if let resolved = usage.resolvedLabel,
                       resolved != states[idx].account.label {
                        states[idx].account.label = resolved
                        try? store.updateLabel(for: id, resolved)
                        prevPercents[id] = nil
                    }
                case .failure(let error):
                    states[idx].lastError = error.localizedDescription
                }
                nextDue[id] = Date().addingTimeInterval(normalInterval)
            }
        }
        lastRefresh = Date()
        fireThresholdAlerts()
    }

    /// Compare against the previous poll and push webhook alerts for every
    /// 50/70/80/90% upward crossing. Window resets lower the baseline, so the
    /// next climb re-alerts naturally.
    private func fireThresholdAlerts() {
        var alerts: [(header: String, state: AccountState)] = []
        for state in states {
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
        return (
            states.compactMap { $0.snapshot?.fiveHour?.percent }.max(),
            states.compactMap { $0.snapshot?.sevenDay?.percent }.max()
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

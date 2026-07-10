import Foundation
import SwiftUI

@MainActor
final class Poller: ObservableObject {
    static let shared = Poller()

    @Published var states: [AccountState] = []
    @Published var lastRefresh: Date?

    /// Poll interval in seconds (default 10 minutes).
    var interval: TimeInterval {
        let v = UserDefaults.standard.double(forKey: "pollIntervalSeconds")
        return v >= 60 ? v : 600
    }

    private let store = AccountStore.shared
    private var loopTask: Task<Void, Never>?

    func start() {
        reloadAccounts()
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshAll()
                let interval = self?.interval ?? 600
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
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
        let snapshot = states
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
                case .failure(let error):
                    states[idx].lastError = error.localizedDescription
                }
            }
        }
        lastRefresh = Date()
    }

    /// Menu bar summary: the worst (highest) utilization across all accounts.
    var worstPercent: Double? {
        states.compactMap(\.maxPercent).max()
    }
}

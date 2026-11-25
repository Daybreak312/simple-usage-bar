import Foundation

/// App-side schedule of the usage ledger: one background scan of the session
/// logs (plus the daily price-table refresh) about once a minute, driven by
/// the poller's 15 s tick. Views showing ledger data observe `updatedAt`.
@MainActor
final class LedgerScanner: ObservableObject {
    static let shared = LedgerScanner()

    /// Minimum gap between scan starts. With the 15 s tick this lands on a
    /// scan every 60 s (PRD: 1분 이내).
    static let interval: TimeInterval = 45

    /// When a scan last finished that added something (or the price table
    /// changed) — set once after the first scan too, so views load.
    @Published private(set) var updatedAt: Date?

    private let ledger: UsageLedger
    private let prices: ModelPriceSource
    private var lastStart: Date?
    private var running = false

    init(ledger: UsageLedger = .shared, prices: ModelPriceSource = .shared) {
        self.ledger = ledger
        self.prices = prices
    }

    /// Kick off one scan when due. The scan does blocking file and SQLite
    /// I/O, so it runs on a GCD utility queue — never on the main thread or
    /// the Swift concurrency pool; the caller never waits on it. `force` (a
    /// window's refresh button) skips the interval, never a running scan.
    func scanIfDue(now: Date = Date(), force: Bool = false) {
        guard !running,
              force || lastStart.map({ now.timeIntervalSince($0) >= Self.interval }) ?? true else { return }
        lastStart = now
        running = true
        let ledger = self.ledger
        let prices = self.prices
        Task { [weak self] in
            let added: Bool = await withCheckedContinuation { done in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        done.resume(returning: try ledger.ingest().counted > 0)
                    } catch {
                        JSONLines.log("사용량 장부 집계 실패: \(error.localizedDescription)")
                        done.resume(returning: false)
                    }
                }
            }
            let repriced = await prices.refreshIfStale()
            self?.finished(changed: added || repriced)
        }
    }

    private func finished(changed: Bool) {
        running = false
        if changed || updatedAt == nil { updatedAt = Date() }
    }
}

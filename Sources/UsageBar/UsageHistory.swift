import Foundation

/// One utilization reading for a Claude account (probe or, from Phase 2,
/// wrapper stream event). Percent values are 0…100.
struct UsageSample: Equatable {
    var accountId: UUID
    var ts: Date
    var sevenDay: Double?
    var fiveHour: Double?
    /// Raw unified limit status (`allowed` / `allowed_warning` / `rejected`).
    var status: String?

    init(accountId: UUID, ts: Date, sevenDay: Double?, fiveHour: Double?, status: String?) {
        self.accountId = accountId
        self.ts = ts
        self.sevenDay = sevenDay
        self.fiveHour = fiveHour
        self.status = status
    }

    init(accountId: UUID, snapshot: UsageSnapshot) {
        self.init(
            accountId: accountId, ts: snapshot.fetchedAt,
            sevenDay: snapshot.sevenDay?.percent, fiveHour: snapshot.fiveHour?.percent,
            status: snapshot.limitStatus)
    }

    /// `{"v":1,"ts":<ms>,"accountId":…,"sevenDay":…,"fiveHour":…,"status":…}`
    func jsonLine() -> Data {
        var obj: [String: Any] = [
            "v": 1,
            "ts": Int64((ts.timeIntervalSince1970 * 1000).rounded()),
            "accountId": accountId.uuidString,
        ]
        obj["sevenDay"] = sevenDay ?? NSNull()
        obj["fiveHour"] = fiveHour ?? NSNull()
        obj["status"] = status ?? NSNull()
        var data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
        data.append(0x0A)
        return data
    }

    init?(json obj: [String: Any]) {
        guard let ms = (obj["ts"] as? NSNumber)?.doubleValue,
              let id = (obj["accountId"] as? String).flatMap(UUID.init(uuidString:)) else { return nil }
        self.init(
            accountId: id, ts: Date(timeIntervalSince1970: ms / 1000),
            sevenDay: (obj["sevenDay"] as? NSNumber)?.doubleValue,
            fiveHour: (obj["fiveHour"] as? NSNumber)?.doubleValue,
            status: obj["status"] as? String)
    }
}

/// Per-account utilization history — the source of the Phase 4 trend chart.
///
/// Rules:
/// - **3-minute merge:** samples of one account falling in the same 3-minute
///   bucket (epoch / 180 s) collapse into one — the latest reading wins. Fixed
///   buckets make the result independent of arrival order and keep at most one
///   point per 3 minutes even under a stream of wrapper events.
/// - **90-day retention:** older samples are dropped on load and compaction.
///
/// Storage is append-only (`claude/usage-history.jsonl`); duplicates are
/// merged in memory and the file is compacted (rewritten) on load and once
/// enough raw lines accumulate. Single writer: the GUI app's poller.
final class UsageHistoryStore {
    static let shared = UsageHistoryStore()

    static let mergeWindow: TimeInterval = 180
    static let retention: TimeInterval = 90 * 86_400
    /// Raw lines beyond the merged count that trigger a rewrite.
    static let compactionSlack = 2_000

    let url: URL
    private let now: () -> Date
    private let queue = DispatchQueue(label: "dev.daybreak.usagebar.usage-history")
    private var cache: [UUID: [UsageSample]]?
    private var rawLines = 0

    init(directory: URL = AppPaths.claudeDirectory, now: @escaping () -> Date = Date.init) {
        self.url = directory.appendingPathComponent("usage-history.jsonl")
        self.now = now
    }

    func record(_ sample: UsageSample) {
        queue.sync {
            var all = loadLocked()
            var series = all[sample.accountId] ?? []
            Self.insert(sample, into: &series)
            all[sample.accountId] = series
            cache = all
            do {
                try AppPaths.ensurePrivateDirectory(url.deletingLastPathComponent())
                try JSONLines.append(sample.jsonLine(), to: url)
                rawLines += 1
            } catch {
                FileHandle.standardError.write(Data("사용률 이력 기록 실패: \(error.localizedDescription)\n".utf8))
            }
            let kept = all.values.reduce(0) { $0 + $1.count }
            if rawLines > kept + Self.compactionSlack { compactLocked() }
        }
    }

    /// Samples of one account, oldest first, within retention.
    func samples(for accountId: UUID, since: Date? = nil) -> [UsageSample] {
        queue.sync {
            let cutoff = max(since ?? .distantPast, now().addingTimeInterval(-Self.retention))
            return (loadLocked()[accountId] ?? []).filter { $0.ts >= cutoff }
        }
    }

    /// Rewrite the file with merged, retained samples only.
    func compact() {
        queue.sync {
            _ = loadLocked()
            compactLocked()
        }
    }

    // MARK: - Pure rules (tested)

    static func bucket(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 / mergeWindow).rounded(.down))
    }

    /// Merge one sample into a series sorted by time.
    static func insert(_ sample: UsageSample, into series: inout [UsageSample]) {
        let b = bucket(sample.ts)
        if let last = series.last, last.ts <= sample.ts {
            // Fast path: in-order arrival.
            if bucket(last.ts) == b {
                series[series.count - 1] = sample
            } else {
                series.append(sample)
            }
            return
        }
        if let i = series.firstIndex(where: { bucket($0.ts) == b }) {
            if series[i].ts <= sample.ts { series[i] = sample }
            return
        }
        let i = series.firstIndex(where: { $0.ts > sample.ts }) ?? series.count
        series.insert(sample, at: i)
    }

    /// Group by account, merge per bucket, drop samples older than `cutoff`.
    static func merge(_ samples: [UsageSample], cutoff: Date) -> [UUID: [UsageSample]] {
        var out: [UUID: [UsageSample]] = [:]
        for s in samples where s.ts >= cutoff {
            insert(s, into: &out[s.accountId, default: []])
        }
        return out
    }

    // MARK: - Plumbing (call on queue)

    private func loadLocked() -> [UUID: [UsageSample]] {
        if let cache { return cache }
        let raw = JSONLines.objects(at: url).compactMap(UsageSample.init(json:))
        let merged = Self.merge(raw, cutoff: now().addingTimeInterval(-Self.retention))
        cache = merged
        rawLines = raw.count
        let kept = merged.values.reduce(0) { $0 + $1.count }
        if raw.count != kept || hasUnparsedLines(rawCount: raw.count) { compactLocked() }
        return merged
    }

    private func hasUnparsedLines(rawCount: Int) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        return data.split(separator: 0x0A).count != rawCount
    }

    private func compactLocked() {
        let cutoff = now().addingTimeInterval(-Self.retention)
        var all = cache ?? [:]
        for (id, series) in all { all[id] = series.filter { $0.ts >= cutoff } }
        cache = all
        let lines = all.values.flatMap { $0 }.sorted { $0.ts < $1.ts }
        var data = Data()
        for s in lines { data.append(s.jsonLine()) }
        do {
            try AppPaths.ensurePrivateDirectory(url.deletingLastPathComponent())
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            rawLines = lines.count
        } catch {
            FileHandle.standardError.write(Data("사용률 이력 정리 실패: \(error.localizedDescription)\n".utf8))
        }
    }
}

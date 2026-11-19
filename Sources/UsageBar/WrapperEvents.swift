import CryptoKit
import Foundation

/// An `events.jsonl` line the app acts on (written by `usagebar observe-claude`).
/// `session` / `result` lines are left to the usage ledger.
struct WrapperEvent: Equatable {
    enum Kind: Equatable {
        /// stream-json `rate_limit_event`. Windows from `unifiedWindows`
        /// (`seven_day` — F4 실측; `five_hour` — 5h 한도 플랜만, Ultra엔 없음).
        case rateLimit(status: String?, rateLimitType: String?, overageStatus: String?,
                       fiveHour: WindowUsage?, sevenDay: WindowUsage?)
        /// claude reported a usage-limit refusal in its output.
        case limitText(match: String)
    }

    var ts: Date
    var accountId: UUID?
    var tokenHash: String?
    var kind: Kind

    var isLimitRefusal: Bool {
        switch kind {
        case .rateLimit(let status, _, _, _, _): return status == "rejected"
        case .limitText: return true
        }
    }

    init(ts: Date, accountId: UUID?, tokenHash: String?, kind: Kind) {
        self.ts = ts
        self.accountId = accountId
        self.tokenHash = tokenHash
        self.kind = kind
    }

    init?(json obj: [String: Any]) {
        guard let ms = (obj["ts"] as? NSNumber)?.doubleValue else { return nil }
        let ts = Date(timeIntervalSince1970: ms / 1000)
        let accountId = (obj["accountId"] as? String).flatMap(UUID.init(uuidString:))
        let tokenHash = obj["tokenHash"] as? String
        switch obj["type"] as? String {
        case "rate_limit":
            let windows = obj["windows"] as? [String: Any] ?? [:]
            func window(_ name: String) -> WindowUsage? {
                guard let w = windows[name] as? [String: Any],
                      let u = (w["utilization"] as? NSNumber)?.doubleValue, u.isFinite else { return nil }
                let reset = (w["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                return WindowUsage(percent: u * 100, resetsAt: reset)
            }
            self.init(ts: ts, accountId: accountId, tokenHash: tokenHash, kind: .rateLimit(
                status: obj["status"] as? String,
                rateLimitType: obj["rateLimitType"] as? String,
                overageStatus: obj["overageStatus"] as? String,
                fiveHour: window("five_hour"), sevenDay: window("seven_day")))
        case "limit_text":
            self.init(ts: ts, accountId: accountId, tokenHash: tokenHash,
                      kind: .limitText(match: obj["match"] as? String ?? ""))
        default:
            return nil
        }
    }
}

/// Pure rules for folding wrapper events into account state (tested).
enum WrapperEventRules {
    /// Refusals older than this don't trigger an immediate roll (e.g. events
    /// replayed after the app was down or the read cursor was lost).
    static let immediateMaxAge: TimeInterval = 10 * 60

    /// The snapshot after `event`, or nil when the event is not newer than
    /// what we have (or carries nothing to show).
    static func apply(_ event: WrapperEvent, to old: UsageSnapshot?) -> UsageSnapshot? {
        if let old, event.ts <= old.fetchedAt { return nil }
        switch event.kind {
        case .rateLimit(let status, let type, let overage, let five, let seven):
            guard old != nil || five != nil || seven != nil || status == "rejected" else { return nil }
            var snap = old ?? UsageSnapshot(fetchedAt: event.ts)
            if let five { snap.fiveHour = five }
            if let seven { snap.sevenDay = seven }
            if let status { snap.limitStatus = status }
            snap.fetchedAt = event.ts
            snap.details = details(status: snap.limitStatus, rateLimitType: type, overageStatus: overage)
            return snap
        case .limitText:
            guard var snap = old else { return nil }
            snap.limitStatus = "rejected"
            snap.fetchedAt = event.ts
            snap.details = details(status: "rejected", rateLimitType: nil, overageStatus: nil)
            return snap
        }
    }

    /// Same phrasing as the probe's header details.
    static func details(status: String?, rateLimitType: String?, overageStatus: String?) -> [String] {
        typealias H = ClaudeProvider.RateLimitHeaders
        var out: [String] = []
        if let status { out.append(H.statusPhrase(status)) }
        if let rateLimitType { out.append("기준 \(H.claimName(rateLimitType))") }
        if let overageStatus { out.append("초과 사용 \(H.overagePhrase(overageStatus))") }
        return out
    }

    /// Account the event belongs to: the wrapper's account id when it names a
    /// registered 1-year-token account, else the token hash.
    static func resolve(_ event: WrapperEvent, accounts: [Account], hashes: [String: UUID]) -> UUID? {
        if let id = event.accountId, accounts.contains(where: { $0.id == id && $0.isClaudeToken }) {
            return id
        }
        return event.tokenHash.flatMap { hashes[$0] }
    }

    /// Should this event roll the active account away right now?
    static func triggersImmediateRoll(_ event: WrapperEvent, accountId: UUID, activeId: UUID?, now: Date) -> Bool {
        event.isLimitRefusal && accountId == activeId
            && now.timeIntervalSince(event.ts) <= immediateMaxAge
    }
}

extension ClaudeProvider {
    /// First 16 hex digits of SHA-256(token) — the wrapper's `tokenHash`
    /// (`printf %s "$token" | openssl dgst -sha256`).
    static func tokenHash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }
}

/// Incremental reader of `claude/events.jsonl`.
///
/// The read position (`events.cursor`: file inode + byte offset) survives app
/// restarts. A different inode or a shorter file means the file was replaced →
/// read it from the start. Only complete lines are consumed; a line still being
/// written is picked up next time.
final class ClaudeEventFeed {
    static let shared = ClaudeEventFeed()

    let url: URL
    let cursorURL: URL
    private let lock = NSLock()
    private var cursor: Cursor?

    struct Cursor: Codable, Equatable {
        var inode: UInt64
        var offset: UInt64
    }

    init(directory: URL = AppPaths.claudeDirectory) {
        url = directory.appendingPathComponent("events.jsonl")
        cursorURL = directory.appendingPathComponent("events.cursor")
    }

    func readNew() -> [WrapperEvent] {
        lock.lock()
        defer { lock.unlock() }
        return readLocked(url)
    }

    /// Daily upkeep: rotation + 90-day retention (see `JSONLinesRotation`).
    /// Events still unread in the rotated-out file are returned.
    func maintain(now: Date = Date(), settle: TimeInterval = 1) -> [WrapperEvent] {
        lock.lock()
        defer { lock.unlock() }
        var drained: [WrapperEvent] = []
        JSONLinesRotation.maintain(url, now: now, settle: settle) { rotating in
            drained = readLocked(rotating)
            saveCursor(Cursor(inode: 0, offset: 0))  // next read: the fresh file from 0
        }
        return drained
    }

    // MARK: - Plumbing (call with lock held)

    private func readLocked(_ file: URL) -> [WrapperEvent] {
        let fd = open(file.path, O_RDONLY)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { return [] }
        let inode = UInt64(st.st_ino)
        let size = UInt64(st.st_size)
        let current = loadCursor()
        var start: UInt64 = 0
        if let current, current.inode == inode, current.offset <= size { start = current.offset }
        guard size > start else {
            if current?.inode != inode { saveCursor(Cursor(inode: inode, offset: start)) }
            return []
        }
        guard lseek(fd, off_t(start), SEEK_SET) >= 0 else { return [] }
        let data = Self.readAll(fd, count: Int(size - start))
        guard let lastNL = data.lastIndex(of: 0x0A) else {
            if current?.inode != inode { saveCursor(Cursor(inode: inode, offset: start)) }
            return []
        }
        let complete = data[data.startIndex...lastNL]
        saveCursor(Cursor(inode: inode, offset: start + UInt64(complete.count)))
        return complete.split(separator: 0x0A).compactMap {
            ((try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any])
                .flatMap(WrapperEvent.init(json:))
        }
    }

    private static func readAll(_ fd: Int32, count: Int) -> Data {
        var data = Data(count: count)
        var got = 0
        data.withUnsafeMutableBytes { buf in
            while got < count {
                let n = read(fd, buf.baseAddress! + got, count - got)
                if n < 0, errno == EINTR { continue }
                if n <= 0 { break }
                got += n
            }
        }
        return data.prefix(got)
    }

    private func loadCursor() -> Cursor? {
        if let cursor { return cursor }
        cursor = (try? Data(contentsOf: cursorURL)).flatMap { try? JSONDecoder().decode(Cursor.self, from: $0) }
        return cursor
    }

    private func saveCursor(_ c: Cursor) {
        guard c != cursor else { return }
        cursor = c
        guard let data = try? JSONEncoder().encode(c) else { return }
        try? data.write(to: cursorURL, options: .atomic)
    }
}

/// Retention for append-only `claude/*.jsonl` logs that other processes keep
/// appending to (launches, events).
///
/// Lines can't be removed in place without racing those appenders, so a log
/// is kept as two files:
///
/// - `X.jsonl` — the live file every writer appends to (O_APPEND).
/// - `X.1.jsonl` — older lines; only the app writes it, always filtered to
///   the last 90 days.
///
/// Once the live file's oldest line is a week old it is renamed to
/// `X.rotating.jsonl` (the next append recreates `X.jsonl`), writers that
/// opened it just before the rename get `settle` seconds to finish, then its
/// lines are merged into `X.1.jsonl` and it is deleted. A crash in between
/// leaves `X.rotating.jsonl`, which the next run merges first.
/// Readers wanting full history read `X.1.jsonl`, `X.rotating.jsonl`, `X.jsonl`
/// in that order (`files(for:)`).
enum JSONLinesRotation {
    static let retention: TimeInterval = 90 * 86_400
    static let rotateAfter: TimeInterval = 7 * 86_400

    static func archiveURL(for url: URL) -> URL { sibling(url, "1") }
    static func rotatingURL(for url: URL) -> URL { sibling(url, "rotating") }

    /// Oldest → newest.
    static func files(for url: URL) -> [URL] { [archiveURL(for: url), rotatingURL(for: url), url] }

    private static func sibling(_ url: URL, _ tag: String) -> URL {
        let base = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent().appendingPathComponent("\(base).\(tag).jsonl")
    }

    /// - Parameter drain: called with the rotated-out file before it is
    ///   merged and deleted (the event feed reads what it hadn't yet).
    static func maintain(_ url: URL, now: Date, settle: TimeInterval = 1,
                         drain: (URL) -> Void = { _ in }) {
        let fm = FileManager.default
        let archive = archiveURL(for: url)
        let rotating = rotatingURL(for: url)
        let cutoff = now.addingTimeInterval(-retention)

        if !fm.fileExists(atPath: rotating.path),
           let first = firstTimestamp(url), now.timeIntervalSince(first) >= rotateAfter {
            if rename(url.path, rotating.path) == 0, settle > 0 {
                Thread.sleep(forTimeInterval: settle)
            }
        }

        if fm.fileExists(atPath: rotating.path) {
            drain(rotating)
            var merged = keptLines(archive, cutoff: cutoff)
            merged.append(keptLines(rotating, cutoff: cutoff))
            if write(merged, to: archive) { unlink(rotating.path) }
        } else if let first = firstTimestamp(archive), first < cutoff {
            _ = write(keptLines(archive, cutoff: cutoff), to: archive)
        }
    }

    /// `ts` (epoch ms) of the first parseable line in the file's first 64 KB.
    static func firstTimestamp(_ url: URL) -> Date? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 64 * 1024) else { return nil }
        for line in head.split(separator: 0x0A) {
            if let ts = timestamp(Data(line)) { return ts }
        }
        return nil
    }

    private static func timestamp(_ line: Data) -> Date? {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let ms = (obj["ts"] as? NSNumber)?.doubleValue else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    /// Lines at or after `cutoff`, each with its newline. Unparseable lines go.
    private static func keptLines(_ url: URL, cutoff: Date) -> Data {
        guard let data = try? Data(contentsOf: url) else { return Data() }
        var out = Data()
        for line in data.split(separator: 0x0A) {
            let d = Data(line)
            guard let ts = timestamp(d), ts >= cutoff else { continue }
            out.append(d)
            out.append(0x0A)
        }
        return out
    }

    private static func write(_ data: Data, to url: URL) -> Bool {
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            FileHandle.standardError.write(Data("\(url.lastPathComponent) 정리 실패: \(error.localizedDescription)\n".utf8))
            return false
        }
    }
}

import Foundation

/// One ledger cell: tokens of one local day, model and pricing variant — the
/// whole Mac, no account split. Cost is not stored — it is computed when
/// shown, from the current price table (a price update re-prices the past
/// with the same table).
struct LedgerRow: Equatable {
    /// Local calendar day `yyyy-MM-dd` (the Mac's time zone, midnight boundary).
    var day: String
    var model: String
    /// `usage.speed == "fast"` responses (price multiplier `fast`).
    var fast: Bool
    /// `usage.inference_geo == "us"` responses (price multiplier `us`).
    var us: Bool
    /// Long-context tier the responses were judged in at ingest
    /// (`ModelPrice.tierThreshold`, tokens; 0 = base prices). Judged per
    /// response, so a day's long and normal requests are separate rows.
    var tier: Int64 = 0
    var tokens: TokenCounts
}

/// Usage ledger: Claude Code session logs (`~/.claude/projects/**.jsonl`),
/// read incrementally and summed per local day × model for the whole Mac.
/// Which account a response used is not tracked — per-account numbers are
/// the server's utilization (`UsageHistoryStore`), never token estimates.
///
/// Storage: SQLite `claude/ledger.sqlite` (WAL, 0600). One scan = one
/// `BEGIN IMMEDIATE` transaction holding the file offsets, the dedup keys and
/// the sums together, so a crash mid-scan never leaves offsets ahead of the
/// sums (lost usage) or sums ahead of the keys (double count), and the app and
/// `usagebar stats --refresh` scanning at once just take turns.
///
/// Rules:
/// - **Tracking start** = when the ledger was first opened for a scan, stored
///   once and never moved. Earlier messages are dropped; files last modified
///   before it are never opened (no backfill of old history).
/// - **Window** = messages younger than `keyRetention`. Dedup keys live that
///   long, so a re-read file can't count a message twice; anything older is
///   ignored.
/// - **Long-context tier** is judged per response, with the price table
///   current at ingest, and kept as a row key (`LedgerRow.tier`) — summing
///   first would lose which request crossed the threshold. A later change of
///   the table's thresholds doesn't re-judge stored rows.
final class UsageLedger: @unchecked Sendable {  // state behind writeLock / readLock
    static let shared = UsageLedger()

    /// Ledger rows older than this many days are deleted.
    static let retentionDays = 400
    /// Dedup-key lifetime = the oldest message a scan still accepts.
    static let keyRetention: TimeInterval = 90 * 86_400

    let dbURL: URL
    let projectsRoot: URL
    let timeZone: TimeZone
    private let now: () -> Date
    private let prices: () -> ModelPriceTable

    private let writeLock = NSLock()
    private var writer: SQLiteDB?
    private let readLock = NSLock()
    private var reader: SQLiteDB?

    init(directory: URL = AppPaths.claudeDirectory,
         projectsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true),
         timeZone: TimeZone = .current,
         now: @escaping () -> Date = Date.init,
         prices: @escaping () -> ModelPriceTable = { ModelPriceSource.shared.current().table }) {
        dbURL = directory.appendingPathComponent("ledger.sqlite")
        self.projectsRoot = projectsRoot
        self.timeZone = timeZone
        self.now = now
        self.prices = prices
    }

    struct IngestReport: Equatable {
        var trackingStartedAt: Date?
        /// Session files read this scan (new bytes or re-read).
        var filesRead = 0
        /// Distinct responses newly added to the ledger.
        var counted = 0
        /// Already-counted responses seen again (content-block repeats, re-reads).
        var duplicates = 0
        /// Responses before the tracking start or outside the key window.
        var outOfWindow = 0
    }

    // MARK: - Ingest

    /// One incremental scan. Blocking — call off the main thread.
    @discardableResult
    func ingest() throws -> IngestReport {
        writeLock.lock()
        defer { writeLock.unlock() }
        let db = try openWriter()
        let now = self.now()
        return try db.immediateTransaction {
            var report = IngestReport()
            let start = try trackingStart(db, now: now)
            report.trackingStartedAt = start
            let windowStart = max(start, now.addingTimeInterval(-Self.keyRetention))

            // 1. New lines of session files. Lines whose timestamp is outside
            //    the window are dropped before the JSON parse.
            var records: [SessionUsageRecord] = []
            let scanned = try scanFiles(db, since: windowStart, records: &records) { line in
                guard SessionLogParser.isCandidate(line) else { return .skip }
                if let ts = SessionLogParser.quickTimestamp(line), ts < windowStart { return .outOfWindow }
                return SessionLogParser.parse(line).map(LineVerdict.record) ?? .skip
            }
            report.filesRead = scanned.files
            report.outOfWindow += scanned.outOfWindow

            // 2. Dedup + per-cell sums.
            let insertKey = try db.prepare("INSERT OR IGNORE INTO seen(key, day) VALUES(?, ?)")
            var sums: [CellKey: TokenCounts] = [:]
            let dayOf = DayFormatter(timeZone: timeZone)
            let table = prices()
            for r in records {
                guard r.timestamp >= windowStart else { report.outOfWindow += 1; continue }
                let day = dayOf.string(r.timestamp)
                try insertKey.run([.text(r.dedupKey), .text(day)])
                guard db.changes == 1 else { report.duplicates += 1; continue }
                // Unknown model → base tier (it is unpriced anyway).
                let tier = table.lookup(r.model)?.price.tierThreshold(promptTokens: r.tokens.promptTokens) ?? 0
                sums[CellKey(day: day, model: r.model, fast: r.fast, us: r.us, tier: tier),
                     default: TokenCounts()] += r.tokens
                report.counted += 1
            }

            // 3. Sums.
            let upsert = try db.prepare("""
                INSERT INTO usage(day, model, fast, us, tier, input, output, cache_5m, cache_1h, cache_read, web_search, messages)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(day, model, fast, us, tier) DO UPDATE SET
                  input = input + excluded.input, output = output + excluded.output,
                  cache_5m = cache_5m + excluded.cache_5m, cache_1h = cache_1h + excluded.cache_1h,
                  cache_read = cache_read + excluded.cache_read, web_search = web_search + excluded.web_search,
                  messages = messages + excluded.messages
                """)
            for (k, t) in sums {
                try upsert.run([
                    .text(k.day), .text(k.model),
                    .int(k.fast ? 1 : 0), .int(k.us ? 1 : 0), .int(k.tier),
                    .int(t.input), .int(t.output), .int(t.cacheWrite5m), .int(t.cacheWrite1h),
                    .int(t.cacheRead), .int(t.webSearches), .int(t.messages),
                ])
            }

            // 4. Retention.
            let keyCutoff = dayOf.string(now.addingTimeInterval(-Self.keyRetention - 86_400))
            try db.prepare("DELETE FROM seen WHERE day < ?").run([.text(keyCutoff)])
            let rowCutoff = dayOf.string(now.addingTimeInterval(-Double(Self.retentionDays) * 86_400))
            try db.prepare("DELETE FROM usage WHERE day < ?").run([.text(rowCutoff)])
            return report
        }
    }

    private struct CellKey: Hashable {
        var day: String
        var model: String
        var fast: Bool
        var us: Bool
        var tier: Int64
    }

    /// Stored tracking start, or `now` stored as the start (first scan ever).
    /// Never moved afterwards.
    private func trackingStart(_ db: SQLiteDB, now: Date) throws -> Date {
        if let stored = try Self.storedTrackingStart(db) { return stored }
        let ms = Int64((now.timeIntervalSince1970 * 1000).rounded(.down))
        try db.prepare("INSERT INTO meta(key, value) VALUES('trackingStartedAt', ?)").run([.text(String(ms))])
        return Date(timeIntervalSince1970: Double(ms) / 1000)
    }

    private static func storedTrackingStart(_ db: SQLiteDB) throws -> Date? {
        try db.prepare("SELECT value FROM meta WHERE key = 'trackingStartedAt'")
            .query { $0.text(0).flatMap(Int64.init) }.first
            .map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }

    private struct FileState {
        var inode: UInt64
        var offset: UInt64
    }

    enum LineVerdict {
        case record(SessionUsageRecord)
        case skip
        case outOfWindow
    }

    private struct ScanCounts {
        var files = 0
        var outOfWindow = 0
    }

    /// Reads new complete lines of every session file modified since
    /// `since`, appending usage records. Updates the stored offsets and drops
    /// offsets of files that are gone or out of the window.
    private func scanFiles(_ db: SQLiteDB, since: Date, records: inout [SessionUsageRecord],
                           classify: (Data) -> LineVerdict) throws -> ScanCounts {
        var states: [String: FileState] = [:]
        for (path, st) in try db.prepare("SELECT path, inode, offset FROM files").query([], { row -> (String, FileState)? in
            guard let p = row.text(0) else { return nil }
            return (p, FileState(inode: UInt64(bitPattern: row.int(1)), offset: UInt64(bitPattern: row.int(2))))
        }) { states[path] = st }

        let save = try db.prepare("""
            INSERT INTO files(path, inode, offset, mtime) VALUES(?, ?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET inode = excluded.inode, offset = excluded.offset, mtime = excluded.mtime
            """)
        var live = Set<String>()
        var counts = ScanCounts()
        for path in sessionFiles() {
            var st = stat()
            guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
            let mtime = Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec)
                + Double(st.st_mtimespec.tv_nsec) / 1e9)
            guard mtime >= since else { continue }  // untouched since before the window: never opened
            live.insert(path)
            let inode = UInt64(st.st_ino)
            let size = UInt64(st.st_size)
            let old = states[path]
            if let old, old.inode == inode, old.offset == size { continue }
            // Same file grown → continue; replaced or shrunk → from the start
            // (dedup keys stop the re-read lines from counting twice).
            let start = (old?.inode == inode && (old?.offset ?? 0) <= size) ? old!.offset : 0

            let fd = open(path, O_RDONLY)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            var fst = stat()
            guard fstat(fd, &fst) == 0 else { continue }
            let end = UInt64(fst.st_size)
            let fdInode = UInt64(fst.st_ino)
            let from = fdInode == inode ? start : 0  // replaced between stat and open
            var outOfWindow = 0
            guard let next = LineReader.forEachLine(fd, from: from, to: end, { line in
                switch classify(line) {
                case .record(let r): records.append(r)
                case .skip: break
                case .outOfWindow: outOfWindow += 1
                }
            }) else { continue }
            counts.files += 1
            counts.outOfWindow += outOfWindow
            try save.run([.text(path), .int(Int64(bitPattern: fdInode)), .int(Int64(bitPattern: next)),
                          .double(mtime.timeIntervalSince1970)])
        }
        // Offsets of files that vanished or fell out of the window. If such a
        // file is touched again it is read from 0, and its old lines are
        // outside the window by then.
        let drop = try db.prepare("DELETE FROM files WHERE path = ?")
        for path in states.keys where !live.contains(path) { try drop.run([.text(path)]) }
        return counts
    }

    /// Every `*.jsonl` under the projects root (subagent logs included).
    private func sessionFiles() -> [String] {
        guard let e = FileManager.default.enumerator(
            at: projectsRoot, includingPropertiesForKeys: nil, options: [.skipsPackageDescendants]) else { return [] }
        var out: [String] = []
        for case let url as URL in e where url.pathExtension == "jsonl" {
            out.append(url.path)
        }
        return out
    }

    // MARK: - Read

    /// When tracking started (nil = no scan yet / no ledger).
    func trackingStartedAt() -> Date? {
        (try? withReader { try Self.storedTrackingStart($0) }).flatMap { $0 }
    }

    /// Rows with `fromDay ≤ day ≤ toDay` (local `yyyy-MM-dd`). Empty when the
    /// ledger doesn't exist yet.
    func rows(fromDay: String, toDay: String) throws -> [LedgerRow] {
        try withReader { db in
            try db.prepare("""
                SELECT day, model, fast, us, input, output, cache_5m, cache_1h, cache_read, web_search, messages, tier
                FROM usage WHERE day >= ? AND day <= ?
                ORDER BY day, model, fast, us, tier
                """).query([.text(fromDay), .text(toDay)]) { r -> LedgerRow? in
                guard let day = r.text(0), let model = r.text(1) else { return nil }
                let t = TokenCounts(input: r.int(4), output: r.int(5), cacheWrite5m: r.int(6),
                                    cacheWrite1h: r.int(7), cacheRead: r.int(8),
                                    webSearches: r.int(9), messages: r.int(10))
                return LedgerRow(day: day, model: model, fast: r.int(2) != 0, us: r.int(3) != 0,
                                 tier: r.int(11), tokens: t)
            }
        } ?? []
    }

    /// Earliest ledger day (nil = nothing counted, or no ledger yet) — tells
    /// "no record ever" apart from "none this period".
    func firstDay() throws -> String? {
        try withReader { db in
            try db.prepare("SELECT MIN(day) FROM usage").query { $0.text(0) }.first
        } ?? nil
    }

    /// Local day string of `date` in the ledger's time zone.
    func day(_ date: Date) -> String { DayFormatter(timeZone: timeZone).string(date) }

    // MARK: - Connections

    /// Schema 3 = Mac-wide sums (no account column). 1·2 were the per-account
    /// ledgers of unmerged development builds (PR #1).
    static let schemaVersion = "3"

    private static let usageTable = """
        CREATE TABLE IF NOT EXISTS usage(day TEXT NOT NULL, model TEXT NOT NULL,
            fast INTEGER NOT NULL, us INTEGER NOT NULL, tier INTEGER NOT NULL,
            input INTEGER NOT NULL, output INTEGER NOT NULL, cache_5m INTEGER NOT NULL,
            cache_1h INTEGER NOT NULL, cache_read INTEGER NOT NULL, web_search INTEGER NOT NULL,
            messages INTEGER NOT NULL,
            PRIMARY KEY(day, model, fast, us, tier)) WITHOUT ROWID;
        """

    private static let schema = """
        PRAGMA journal_mode = WAL;
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY, inode INTEGER NOT NULL,
            offset INTEGER NOT NULL, mtime REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS seen(key TEXT PRIMARY KEY, day TEXT NOT NULL) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS seen_day ON seen(day);
        \(usageTable)
        INSERT OR IGNORE INTO meta(key, value) VALUES('schema', '\(schemaVersion)');
        """

    /// Create the tables, or reset a ledger of another schema (a per-account
    /// ledger of a PR #1 development build at the same path): its sums cover
    /// only wrapper-attributed sessions and its tracking start is the first
    /// wrapper launch — neither means the same here. Everything (sums, dedup
    /// keys, offsets, tracking start) is dropped; the next scan starts
    /// tracking afresh. Checked inside a write transaction so two processes
    /// opening an old file reset it once.
    private static func prepareSchema(_ db: SQLiteDB) throws {
        try db.exec(schema)
        func isCurrent() throws -> Bool {
            let version = try db.prepare("SELECT value FROM meta WHERE key = 'schema'").query { $0.text(0) }.first
            let hasAccount = try db.prepare("SELECT 1 FROM pragma_table_info('usage') WHERE name = 'account'")
                .query { _ in true }.first ?? false
            return version == schemaVersion && !hasAccount
        }
        guard try !isCurrent() else { return }
        try db.immediateTransaction {
            guard try !isCurrent() else { return }
            try db.exec("""
                DROP TABLE IF EXISTS usage;
                DELETE FROM seen;
                DELETE FROM files;
                DELETE FROM meta;
                \(usageTable)
                INSERT INTO meta(key, value) VALUES('schema', '\(schemaVersion)');
                """)
        }
    }

    private func openWriter() throws -> SQLiteDB {
        if let writer { return writer }
        try AppPaths.ensurePrivateDirectory(dbURL.deletingLastPathComponent())
        let db = try SQLiteDB(path: dbURL.path, busyTimeoutMs: 30_000)
        try Self.prepareSchema(db)
        for suffix in ["", "-wal", "-shm"] {
            chmod(dbURL.path + suffix, 0o600)
        }
        writer = db
        return db
    }

    /// nil when the ledger file doesn't exist (nothing ingested yet).
    private func withReader<T>(_ body: (SQLiteDB) throws -> T) throws -> T? {
        readLock.lock()
        defer { readLock.unlock() }
        if reader == nil {
            guard FileManager.default.fileExists(atPath: dbURL.path) else { return nil }
            // Read-write without CREATE: WAL readers need the -shm file.
            let db = try SQLiteDB(path: dbURL.path, readOnly: false, create: false)
            try Self.prepareSchema(db)  // same process may read before its first ingest
            reader = db
        }
        return try body(reader!)
    }
}

/// `yyyy-MM-dd` in a fixed time zone (Gregorian, POSIX locale).
struct DayFormatter {
    private let formatter: DateFormatter

    init(timeZone: TimeZone) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        formatter = f
    }

    func string(_ date: Date) -> String { formatter.string(from: date) }
}

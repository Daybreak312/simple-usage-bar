import Foundation

/// One ledger cell: tokens of one account, local day, model and pricing
/// variant. Cost is not stored — it is computed when shown, from the current
/// price table (a price update re-prices the past with the same table).
struct LedgerRow: Equatable {
    var accountId: UUID
    /// Local calendar day `yyyy-MM-dd` (the Mac's time zone, midnight boundary).
    var day: String
    var model: String
    /// `usage.speed == "fast"` responses (price multiplier `fast`).
    var fast: Bool
    /// `usage.inference_geo == "us"` responses (price multiplier `us`).
    var us: Bool
    var tokens: TokenCounts
}

/// Usage ledger: Claude Code session logs, read incrementally, attributed to
/// accounts through the wrapper's launch log, summed per account × local day
/// × model.
///
/// Storage: SQLite `claude/ledger.sqlite` (WAL). One scan = one
/// `BEGIN IMMEDIATE` transaction holding the file offsets, the dedup keys and
/// the sums together, so a crash mid-scan never leaves offsets ahead of the
/// sums (lost usage) or sums ahead of the keys (double count), and the app and
/// `usagebar stats --refresh` scanning at once just take turns.
///
/// Rules (PRD Phase 3):
/// - **Tracking start** = the earliest `launches.jsonl` ts, fixed on first
///   sight. Earlier messages are dropped; files last modified before it are
///   never opened (no backfill of old history).
/// - **Window** = messages younger than `keyRetention`. Dedup keys live that
///   long, so a re-read file can't count a message twice; anything older is
///   ignored (its launch records are gone by then too).
/// - Only messages attributable to an account are counted; their keys are
///   the only ones kept.
final class UsageLedger: @unchecked Sendable {  // state behind writeLock / readLock
    static let shared = UsageLedger()

    /// Ledger rows older than this many days are deleted.
    static let retentionDays = 400
    /// Dedup-key lifetime = the oldest message a scan still accepts.
    static let keyRetention: TimeInterval = 90 * 86_400
    /// Slack between a launch line's append and its first message line.
    static let launchSettle: TimeInterval = 60

    let dbURL: URL
    let projectsRoot: URL
    let timeZone: TimeZone
    private let now: () -> Date
    private let launchLog: LaunchLog

    private let writeLock = NSLock()
    private var writer: SQLiteDB?
    private let readLock = NSLock()
    private var reader: SQLiteDB?

    init(directory: URL = AppPaths.claudeDirectory,
         projectsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true),
         timeZone: TimeZone = .current,
         now: @escaping () -> Date = Date.init) {
        dbURL = directory.appendingPathComponent("ledger.sqlite")
        self.projectsRoot = projectsRoot
        self.timeZone = timeZone
        self.now = now
        launchLog = LaunchLog(
            launches: directory.appendingPathComponent("launches.jsonl"),
            events: directory.appendingPathComponent("events.jsonl"))
    }

    struct IngestReport: Equatable {
        var trackingStartedAt: Date?
        /// Session files read this scan (new bytes or re-read).
        var filesRead = 0
        /// Distinct responses newly added to the ledger.
        var counted = 0
        /// Already-counted responses seen again (content-block repeats, re-reads).
        var duplicates = 0
        /// Responses with no launch record / no resolvable account (not counted).
        var unattributed = 0
        /// Responses before the tracking start or outside the key window.
        var outOfWindow = 0
    }

    // MARK: - Ingest

    /// One incremental scan. `hashes`: tokenHash → registered 1-year-token
    /// account, for launches that carried a caller token instead of the
    /// active file. Blocking — call off the main thread.
    @discardableResult
    func ingest(hashes: [String: UUID]) throws -> IngestReport {
        writeLock.lock()
        defer { writeLock.unlock() }
        let db = try openWriter()
        let now = self.now()
        return try db.immediateTransaction {
            var report = IngestReport()
            guard let start = try trackingStart(db) else { return report }  // no launches yet
            report.trackingStartedAt = start
            let windowStart = max(start, now.addingTimeInterval(-Self.keyRetention))

            // 1. New lines of session files. A line is parsed only if it can
            //    count: inside the window, and its session either has a launch
            //    already (`before`) or is young enough that its launch may have
            //    been appended while we read. Launch lines are written when
            //    claude starts — before any of its messages — so a message
            //    older than `settle` whose session is unknown now never gets
            //    a launch: it is skipped unparsed.
            let before = launchLog.index()
            let settled = now.addingTimeInterval(-Self.launchSettle)
            var records: [SessionUsageRecord] = []
            let scanned = try scanFiles(db, since: windowStart, records: &records) { line in
                guard SessionLogParser.isCandidate(line) else { return .skip }
                if let q = SessionLogParser.quickFields(line) {
                    if q.timestamp < windowStart { return .outOfWindow }
                    if q.timestamp < settled, !before.hasSession(q.sessionId) { return .unattributed }
                }
                return SessionLogParser.parse(line).map(LineVerdict.record) ?? .skip
            }
            report.filesRead = scanned.files
            report.outOfWindow += scanned.outOfWindow
            report.unattributed += scanned.unattributed

            // 2. Attribution — with the launch log re-read after the files, so
            //    every message read above finds its launch.
            let index = launchLog.index()
            let insertKey = try db.prepare("INSERT OR IGNORE INTO seen(key, day) VALUES(?, ?)")
            var sums: [CellKey: TokenCounts] = [:]
            let dayOf = DayFormatter(timeZone: timeZone)
            for r in records {
                guard r.timestamp >= windowStart else { report.outOfWindow += 1; continue }
                guard let account = index.account(session: r.sessionId, at: r.timestamp, hashes: hashes) else {
                    report.unattributed += 1
                    continue
                }
                let day = dayOf.string(r.timestamp)
                try insertKey.run([.text(r.dedupKey), .text(day)])
                guard db.changes == 1 else { report.duplicates += 1; continue }
                sums[CellKey(account: account, day: day, model: r.model, fast: r.fast, us: r.us), default: TokenCounts()] += r.tokens
                report.counted += 1
            }

            // 3. Sums.
            let upsert = try db.prepare("""
                INSERT INTO usage(account, day, model, fast, us, input, output, cache_5m, cache_1h, cache_read, web_search, messages)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(account, day, model, fast, us) DO UPDATE SET
                  input = input + excluded.input, output = output + excluded.output,
                  cache_5m = cache_5m + excluded.cache_5m, cache_1h = cache_1h + excluded.cache_1h,
                  cache_read = cache_read + excluded.cache_read, web_search = web_search + excluded.web_search,
                  messages = messages + excluded.messages
                """)
            for (k, t) in sums {
                try upsert.run([
                    .text(k.account.uuidString), .text(k.day), .text(k.model),
                    .int(k.fast ? 1 : 0), .int(k.us ? 1 : 0),
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
        var account: UUID
        var day: String
        var model: String
        var fast: Bool
        var us: Bool
    }

    /// Stored tracking start, or the earliest launch (stored now). nil = no
    /// launch recorded yet.
    private func trackingStart(_ db: SQLiteDB) throws -> Date? {
        let stored = try db.prepare("SELECT value FROM meta WHERE key = 'trackingStartedAt'")
            .query { $0.text(0).flatMap(Int64.init) }.first
        if let stored { return Date(timeIntervalSince1970: Double(stored) / 1000) }
        guard let first = launchLog.earliest() else { return nil }
        let ms = Int64((first.timeIntervalSince1970 * 1000).rounded(.down))
        try db.prepare("INSERT INTO meta(key, value) VALUES('trackingStartedAt', ?)").run([.text(String(ms))])
        return Date(timeIntervalSince1970: Double(ms) / 1000)
    }

    private struct FileState {
        var inode: UInt64
        var offset: UInt64
    }

    /// Reads new complete lines of every session file modified since
    /// `since`, appending usage records. Updates the stored offsets and drops
    /// offsets of files that are gone or out of the window. Returns the number
    /// of files read.
    enum LineVerdict {
        case record(SessionUsageRecord)
        case skip
        case outOfWindow
        case unattributed
    }

    private struct ScanCounts {
        var files = 0
        var outOfWindow = 0
        var unattributed = 0
    }

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
            var outOfWindow = 0, unattributed = 0
            guard let next = LineReader.forEachLine(fd, from: from, to: end, { line in
                switch classify(line) {
                case .record(let r): records.append(r)
                case .skip: break
                case .outOfWindow: outOfWindow += 1
                case .unattributed: unattributed += 1
                }
            }) else { continue }
            counts.files += 1
            counts.outOfWindow += outOfWindow
            counts.unattributed += unattributed
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

    /// When tracking started (nil = nothing tracked yet / no ledger).
    func trackingStartedAt() -> Date? {
        (try? withReader { db in
            try db.prepare("SELECT value FROM meta WHERE key = 'trackingStartedAt'")
                .query { $0.text(0).flatMap(Int64.init) }.first
        }).flatMap { $0 }.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }

    /// Rows with `fromDay ≤ day ≤ toDay` (local `yyyy-MM-dd`), optionally one
    /// account's. Empty when the ledger doesn't exist yet.
    func rows(fromDay: String, toDay: String, account: UUID? = nil) throws -> [LedgerRow] {
        try withReader { db in
            var sql = """
                SELECT account, day, model, fast, us, input, output, cache_5m, cache_1h, cache_read, web_search, messages
                FROM usage WHERE day >= ? AND day <= ?
                """
            var args: [SQLiteDB.Value] = [.text(fromDay), .text(toDay)]
            if let account {
                sql += " AND account = ?"
                args.append(.text(account.uuidString))
            }
            sql += " ORDER BY day, account, model, fast, us"
            return try db.prepare(sql).query(args) { r -> LedgerRow? in
                guard let a = r.text(0).flatMap(UUID.init(uuidString:)),
                      let day = r.text(1), let model = r.text(2) else { return nil }
                let t = TokenCounts(input: r.int(5), output: r.int(6), cacheWrite5m: r.int(7),
                                    cacheWrite1h: r.int(8), cacheRead: r.int(9),
                                    webSearches: r.int(10), messages: r.int(11))
                return LedgerRow(accountId: a, day: day, model: model,
                                 fast: r.int(3) != 0, us: r.int(4) != 0, tokens: t)
            }
        } ?? []
    }

    /// Earliest ledger day of one account (nil = nothing counted, or no
    /// ledger yet) — tells "no record ever" apart from "none this period".
    func firstDay(account: UUID) throws -> String? {
        try withReader { db in
            try db.prepare("SELECT MIN(day) FROM usage WHERE account = ?")
                .query([.text(account.uuidString)]) { $0.text(0) }.first
        } ?? nil
    }

    /// Local day string of `date` in the ledger's time zone.
    func day(_ date: Date) -> String { DayFormatter(timeZone: timeZone).string(date) }

    // MARK: - Connections

    private static let schema = """
        PRAGMA journal_mode = WAL;
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY, inode INTEGER NOT NULL,
            offset INTEGER NOT NULL, mtime REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS seen(key TEXT PRIMARY KEY, day TEXT NOT NULL) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS seen_day ON seen(day);
        CREATE TABLE IF NOT EXISTS usage(account TEXT NOT NULL, day TEXT NOT NULL, model TEXT NOT NULL,
            fast INTEGER NOT NULL, us INTEGER NOT NULL,
            input INTEGER NOT NULL, output INTEGER NOT NULL, cache_5m INTEGER NOT NULL,
            cache_1h INTEGER NOT NULL, cache_read INTEGER NOT NULL, web_search INTEGER NOT NULL,
            messages INTEGER NOT NULL,
            PRIMARY KEY(account, day, model, fast, us)) WITHOUT ROWID;
        INSERT OR IGNORE INTO meta(key, value) VALUES('schema', '1');
        """

    private func openWriter() throws -> SQLiteDB {
        if let writer { return writer }
        try AppPaths.ensurePrivateDirectory(dbURL.deletingLastPathComponent())
        let db = try SQLiteDB(path: dbURL.path, busyTimeoutMs: 30_000)
        try db.exec(Self.schema)
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
            try db.exec(Self.schema)  // same process may read before its first ingest
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

/// Incremental reader of the wrapper's launch log and observer events (all
/// rotation files, `JSONLinesRotation.files`), kept parsed in memory — only
/// the fields attribution needs — so a once-a-minute scan reads just what
/// was appended.
final class LaunchLog {
    private let launchesURL: URL
    private let eventsURL: URL
    private let lock = NSLock()

    /// launchId → session id seen by the observer (`isSession`: from a
    /// `session` event; else from a `rate_limit` / `result` line).
    private struct SessionNote {
        var launchId: String
        var sessionId: String
        var isSession: Bool
    }

    private struct Tail<T> {
        var inode: UInt64
        var offset: UInt64
        var items: [T]
    }
    private var launchTails: [String: Tail<LaunchRecord>] = [:]
    private var eventTails: [String: Tail<SessionNote>] = [:]
    private var cached: LaunchIndex?
    private var changed = true

    init(launches: URL, events: URL) {
        launchesURL = launches
        eventsURL = events
    }

    /// Earliest launch ts across the launch log files.
    func earliest() -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return loadLaunches().map(\.ts).min()
    }

    func index() -> LaunchIndex {
        lock.lock()
        defer { lock.unlock() }
        let launches = loadLaunches()
        var notes: [SessionNote] = []
        for url in JSONLinesRotation.files(for: eventsURL) {
            notes += load(url, tails: &eventTails) { obj -> SessionNote? in
                guard let launch = (obj["launchId"] as? String)?.nilIfEmpty,
                      let session = (obj["sessionId"] as? String)?.nilIfEmpty else { return nil }
                return SessionNote(launchId: launch, sessionId: session, isSession: obj["type"] as? String == "session")
            }
        }
        if let cached, !changed { return cached }
        var sessionOf: [String: String] = [:]
        var fallback: [String: String] = [:]
        for n in notes {
            if n.isSession {
                if sessionOf[n.launchId] == nil { sessionOf[n.launchId] = n.sessionId }
            } else if fallback[n.launchId] == nil {
                fallback[n.launchId] = n.sessionId
            }
        }
        for (k, v) in fallback where sessionOf[k] == nil { sessionOf[k] = v }
        let index = LaunchIndex(launches: launches, sessionOf: sessionOf)
        cached = index
        changed = false
        return index
    }

    private func loadLaunches() -> [LaunchRecord] {
        JSONLinesRotation.files(for: launchesURL).flatMap {
            load($0, tails: &launchTails, LaunchRecord.init(json:))
        }
    }

    /// Parsed items of one file, reading only the appended part when the file
    /// is the same (inode) and not shorter than last time.
    private func load<T>(_ url: URL, tails: inout [String: Tail<T>],
                         _ parse: ([String: Any]) -> T?) -> [T] {
        let path = url.path
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else {
            if tails.removeValue(forKey: path) != nil { changed = true }
            return []
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { return tails[path]?.items ?? [] }
        let inode = UInt64(st.st_ino)
        let size = UInt64(st.st_size)
        var tail: Tail<T>
        if let old = tails[path], old.inode == inode, old.offset <= size {
            tail = old
        } else {
            tail = Tail(inode: inode, offset: 0, items: [])
            if tails[path] != nil { changed = true }
        }
        if size > tail.offset {
            var added: [T] = []
            if let next = LineReader.forEachLine(fd, from: tail.offset, to: size, chunkSize: 256 * 1024, { line in
                if let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let v = parse(o) {
                    added.append(v)
                }
            }) {
                if !added.isEmpty { changed = true }
                tail.items += added
                tail.offset = next
            }
        }
        tails[path] = tail
        return tail.items
    }
}

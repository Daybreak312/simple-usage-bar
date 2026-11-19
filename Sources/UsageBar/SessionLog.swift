import Foundation

/// One API response as Claude Code logged it in a session file
/// (`~/.claude/projects/<cwd-slug>/<sessionId>.jsonl`, subagents under
/// `<sessionId>/subagents/agent-*.jsonl` — F6).
struct SessionUsageRecord: Equatable {
    /// Top-level `sessionId` — the parent session for subagent lines (F6).
    var sessionId: String
    var timestamp: Date
    /// `message.id` + `requestId` (ccusage's key); `uuid` when either is
    /// missing. A response logged once per content block repeats this key
    /// with the same usage (F6) — it counts once.
    var dedupKey: String
    var model: String
    /// `usage.speed == "fast"`
    var fast: Bool
    /// `usage.inference_geo == "us"`
    var us: Bool
    /// One response's counts (`messages == 1`).
    var tokens: TokenCounts
}

/// Session-log line → usage record (pure, tested against recorded lines).
enum SessionLogParser {
    /// Claude Code writes compact JSON; lines without these bytes can't be
    /// assistant usage lines and skip the JSON parse.
    private static let markers = [Data(#""type":"assistant""#.utf8), Data(#""usage""#.utf8)]

    /// Local error placeholders claude writes without calling the API.
    static let syntheticModel = "<synthetic>"

    /// Could this line be an assistant usage line? (byte check, no parse)
    static func isCandidate(_ raw: Data) -> Bool {
        markers.allSatisfy { raw.range(of: $0) != nil }
    }

    private static let sessionKey = Data(#""sessionId":""#.utf8)
    private static let timestampKey = Data(#""timestamp":""#.utf8)

    /// `sessionId` and `timestamp` read straight from the bytes, so lines that
    /// can't count (unknown session, outside the window) skip the JSON parse —
    /// most lines of a busy machine belong to sessions that never went through
    /// the wrapper. nil when either key is missing or appears more than once
    /// (a nested object could carry the same key — then only a full parse is
    /// trustworthy). Inside JSON strings the quotes are escaped, so text that
    /// merely mentions these keys never matches.
    static func quickFields(_ raw: Data) -> (sessionId: String, timestamp: Date)? {
        guard let sid = uniqueStringValue(raw, key: sessionKey),
              let ts = uniqueStringValue(raw, key: timestampKey).flatMap(parseTimestamp) else { return nil }
        return (sid, ts)
    }

    private static func uniqueStringValue(_ raw: Data, key: Data) -> String? {
        guard let r = raw.range(of: key),
              raw.range(of: key, in: r.upperBound..<raw.endIndex) == nil,
              let end = raw[r.upperBound...].firstIndex(where: { $0 == 0x22 || $0 == 0x5C }),
              raw[end] == 0x22 else { return nil }  // escapes → let the full parse decide
        return String(data: raw[r.upperBound..<end], encoding: .utf8)?.nilIfEmpty
    }

    static func parse(_ raw: Data) -> SessionUsageRecord? {
        guard isCandidate(raw),
              let obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else { return nil }
        return parse(obj)
    }

    static func parse(_ obj: [String: Any]) -> SessionUsageRecord? {
        guard obj["type"] as? String == "assistant",
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let sessionId = (obj["sessionId"] as? String)?.nilIfEmpty,
              let timestamp = parseTimestamp(obj["timestamp"] as? String),
              let model = (message["model"] as? String)?.nilIfEmpty,
              model != syntheticModel else { return nil }
        let key: String
        if let mid = (message["id"] as? String)?.nilIfEmpty, let rid = (obj["requestId"] as? String)?.nilIfEmpty {
            key = "\(mid):\(rid)"
        } else if let uuid = (obj["uuid"] as? String)?.nilIfEmpty {
            key = "uuid:\(uuid)"
        } else {
            return nil  // no stable identity → can't be counted exactly once
        }

        var t = TokenCounts()
        t.input = count(usage["input_tokens"])
        t.output = count(usage["output_tokens"])
        t.cacheRead = count(usage["cache_read_input_tokens"])
        if let breakdown = usage["cache_creation"] as? [String: Any] {
            t.cacheWrite5m = count(breakdown["ephemeral_5m_input_tokens"])
            t.cacheWrite1h = count(breakdown["ephemeral_1h_input_tokens"])
        } else {
            // No 5m/1h breakdown logged → the whole cache write is 5-minute.
            t.cacheWrite5m = count(usage["cache_creation_input_tokens"])
        }
        t.webSearches = count((usage["server_tool_use"] as? [String: Any])?["web_search_requests"])
        t.messages = 1

        return SessionUsageRecord(
            sessionId: sessionId, timestamp: timestamp, dedupKey: key, model: model,
            fast: usage["speed"] as? String == "fast",
            us: usage["inference_geo"] as? String == "us",
            tokens: t)
    }

    /// Non-negative integer field; anything else counts 0.
    private static func count(_ v: Any?) -> Int64 {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return 0 }
        let d = n.doubleValue
        return d.isFinite && d >= 0 && d < 9e15 ? Int64(d) : 0
    }

    /// `2026-11-19T03:21:58.214Z` (F6: UTC, 3 fractional digits) parsed by
    /// hand — this runs for every usage line — with ISO8601 as the fallback.
    static func parseTimestamp(_ s: String?) -> Date? {
        guard let s else { return nil }
        let b = Array(s.utf8)
        if b.count == 24, b[4] == 0x2D, b[7] == 0x2D, b[10] == 0x54, b[13] == 0x3A,
           b[16] == 0x3A, b[19] == 0x2E, b[23] == 0x5A {
            func num(_ r: Range<Int>) -> Int? {
                var v = 0
                for i in r {
                    let d = Int(b[i]) - 48
                    guard (0...9).contains(d) else { return nil }
                    v = v * 10 + d
                }
                return v
            }
            if let y = num(0..<4), let mo = num(5..<7), let d = num(8..<10),
               let h = num(11..<13), let mi = num(14..<16), let sec = num(17..<19),
               let ms = num(20..<23), (1...12).contains(mo), (1...31).contains(d),
               h < 24, mi < 60, sec < 61 {
                let days = daysFromCivil(y, mo, d)
                let secs = Double(days) * 86_400 + Double(h * 3600 + mi * 60 + sec)
                return Date(timeIntervalSince1970: secs + Double(ms) / 1000)
            }
        }
        return Dates.fromISO(s)
    }

    /// Days since 1970-01-01 of a proleptic Gregorian date (H. Hinnant).
    private static func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}

/// Line-at-a-time reader for append-only files read in increments.
enum LineReader {
    /// Lines longer than this are skipped (still consumed): usage lines are
    /// small, and a runaway line must not pin memory.
    static let maxLine = 64 * 1024 * 1024

    /// Calls `body` with each complete (newline-terminated) line from byte
    /// `start` up to `end`, and returns the offset just past the last
    /// complete line — an unterminated tail is left for the next read.
    /// nil = the file couldn't be read at that offset.
    static func forEachLine(_ fd: Int32, from start: UInt64, to end: UInt64,
                            chunkSize: Int = 1 << 20, _ body: (Data) -> Void) -> UInt64? {
        guard end > start else { return start }
        guard lseek(fd, off_t(start), SEEK_SET) >= 0 else { return nil }
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        var pending = Data()
        var overflow = false
        var position = start
        var consumed = start
        while position < end {
            let want = Int(min(UInt64(chunkSize), end - position))
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress!, want) }
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if n == 0 { break }
            chunk.withUnsafeBytes { raw in
                let base = raw.baseAddress!
                var lineStart = 0
                // memchr: newline search at C speed, also in debug builds.
                while lineStart < n, let hit = memchr(base + lineStart, 0x0A, n - lineStart) {
                    let i = base.distance(to: UnsafeRawPointer(hit))
                    if !overflow {
                        if pending.isEmpty {
                            body(Data(bytes: base + lineStart, count: i - lineStart))
                        } else {
                            pending.append(base.assumingMemoryBound(to: UInt8.self) + lineStart, count: i - lineStart)
                            body(pending)
                        }
                    }
                    pending.removeAll(keepingCapacity: pending.count <= 1 << 20)
                    overflow = false
                    lineStart = i + 1
                    consumed = position + UInt64(i + 1)
                }
                if lineStart < n, !overflow {
                    if pending.count + (n - lineStart) > maxLine {
                        overflow = true
                        pending.removeAll()
                    } else {
                        pending.append(base.assumingMemoryBound(to: UInt8.self) + lineStart, count: n - lineStart)
                    }
                }
            }
            position += UInt64(n)
        }
        return consumed
    }
}

/// A `usagebar-claude` launch, as needed for attribution.
struct LaunchRecord: Equatable {
    var launchId: String?
    var ts: Date
    var accountId: UUID?
    var tokenHash: String?
    var sessionId: String?

    /// A `launches.jsonl` line (Phase 2 format).
    init?(json obj: [String: Any]) {
        guard let ms = (obj["ts"] as? NSNumber)?.doubleValue else { return nil }
        ts = Date(timeIntervalSince1970: ms / 1000)
        launchId = (obj["launchId"] as? String)?.nilIfEmpty
        accountId = (obj["accountId"] as? String).flatMap(UUID.init(uuidString:))
        tokenHash = (obj["tokenHash"] as? String)?.nilIfEmpty
        sessionId = (obj["sessionId"] as? String)?.nilIfEmpty
    }

    init(launchId: String?, ts: Date, accountId: UUID?, tokenHash: String?, sessionId: String?) {
        self.launchId = launchId
        self.ts = ts
        self.accountId = accountId
        self.tokenHash = tokenHash
        self.sessionId = sessionId
    }
}

/// sessionId → launches of that session, for the attribution rule:
/// a message belongs to the account of the **latest launch of its session
/// that started at or before the message** (OpenClaw resumes one session in a
/// new process every turn, so a roll between turns moves later turns to the
/// new account). Launches only have a start time — `exec` leaves no end.
struct LaunchIndex {
    private var bySession: [String: [LaunchRecord]] = [:]

    /// - Parameter sessionOf: launchId → session id the observer saw claude
    ///   start with (`session` events). It fills a launch whose session id the
    ///   wrapper couldn't know (`--fork-session`, bare `--resume` picker) and
    ///   wins when the wrapper's guess (`--continue` = newest file in the
    ///   project) differs from what claude actually used.
    init(launches: [LaunchRecord], sessionOf: [String: String] = [:]) {
        var seen = Set<String>()
        for var l in launches {
            if let id = l.launchId {
                guard seen.insert(id).inserted else { continue }  // same line read twice
                if let s = sessionOf[id] { l.sessionId = s }
            }
            guard let s = l.sessionId else { continue }
            bySession[s, default: []].append(l)
        }
        for k in bySession.keys { bySession[k]!.sort { $0.ts < $1.ts } }
    }

    var isEmpty: Bool { bySession.isEmpty }

    func hasSession(_ id: String) -> Bool { bySession[id] != nil }

    func launch(session: String, at time: Date) -> LaunchRecord? {
        guard let list = bySession[session] else { return nil }
        // Binary search: last element with ts <= time.
        var lo = 0, hi = list.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if list[mid].ts <= time { lo = mid + 1 } else { hi = mid }
        }
        return lo == 0 ? nil : list[lo - 1]
    }

    /// The account a message is counted under, or nil (= not counted): the
    /// launch's account id, else its token hash matched against registered
    /// 1-year-token accounts.
    func account(session: String, at time: Date, hashes: [String: UUID]) -> UUID? {
        guard let l = launch(session: session, at: time) else { return nil }
        if let id = l.accountId { return id }
        return l.tokenHash.flatMap { hashes[$0] }
    }
}

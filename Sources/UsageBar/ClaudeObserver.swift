import Foundation

/// `usagebar observe-claude --launch <id> --dir <claude data dir>` — the
/// stdout tap `usagebar-claude` puts behind `claude -p`.
///
/// stdin (claude's stdout) goes to stdout **byte for byte, as it arrives** —
/// every read is written before anything is parsed, so the consumer never
/// waits on us. Afterwards each complete line is inspected and noteworthy ones
/// become one line in `<dir>/events.jsonl`:
///
///     {"v":1,"ts":<ms>,"launchId":…,"accountId":<uuid|null>,"tokenHash":<hex16|null>,"type":…,…}
///
/// `accountId` / `tokenHash` come from the wrapper via `USAGEBAR_ACCOUNT_ID` /
/// `USAGEBAR_TOKEN_HASH` (set on the observer command only, never on claude).
///
/// The observer must never break the stream: parse/write failures are
/// swallowed, SIGPIPE/SIGINT are ignored (Ctrl-C reaches the whole foreground
/// group; claude decides how to stop, we keep relaying until EOF), and a closed
/// stdout (EPIPE) ends the process quietly with status 0. It touches no GUI
/// state — `Entry` dispatches here before anything else.
enum ClaudeObserver {
    static let command = "observe-claude"

    struct Context {
        var launchId: String?
        var accountId: String?
        var tokenHash: String?
        var eventsURL: URL?
    }

    static func main(_ args: [String]) -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let env = ProcessInfo.processInfo.environment
        let dir = value(of: "--dir", in: args).flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        let context = Context(
            launchId: value(of: "--launch", in: args)?.nilIfEmpty,
            accountId: env["USAGEBAR_ACCOUNT_ID"]?.nilIfEmpty,
            tokenHash: env["USAGEBAR_TOKEN_HASH"]?.nilIfEmpty,
            eventsURL: dir?.appendingPathComponent("events.jsonl"))
        let sink = EventSink(context: context)
        pump(input: STDIN_FILENO, output: STDOUT_FILENO) { line in
            for event in ClaudeStreamParser.parse(line: line) { sink.write(event) }
        }
        return 0
    }

    private static func value(of flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    // MARK: - Passthrough

    /// Longest line kept for inspection. Longer lines still pass through
    /// untouched; they just aren't parsed (the events we care about are small).
    static let maxInspectedLine = 32 * 1024 * 1024

    /// Copy `input` → `output` until EOF, calling `onLine` with every complete
    /// line (without the `\n`) and with an unterminated final fragment.
    /// Returns when input hits EOF/error or output is closed (EPIPE etc.).
    static func pump(input: Int32, output: Int32, chunkSize: Int = 64 * 1024,
                     onLine: (Data) -> Void) {
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        var pending = Data()
        var overflow = false

        while true {
            let n = chunk.withUnsafeMutableBytes { read(input, $0.baseAddress!, chunkSize) }
            if n < 0 {
                if errno == EINTR { continue }
                break
            }
            if n == 0 { break }

            let forwarded = chunk.withUnsafeBytes { writeAll(output, $0.baseAddress!, n) }
            guard forwarded else { return }  // consumer gone — nothing left to relay

            chunk.withUnsafeBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                var start = 0
                for i in 0..<n where bytes[i] == 0x0A {
                    if !overflow {
                        pending.append(bytes.baseAddress! + start, count: i - start)
                        onLine(pending)
                    }
                    pending.removeAll(keepingCapacity: pending.count <= 1 << 20)
                    overflow = false
                    start = i + 1
                }
                if start < n, !overflow {
                    if pending.count + (n - start) > maxInspectedLine {
                        overflow = true
                        pending.removeAll()
                    } else {
                        pending.append(bytes.baseAddress! + start, count: n - start)
                    }
                }
            }
        }
        if !pending.isEmpty, !overflow { onLine(pending) }
    }

    /// Write everything, riding out EINTR and a non-blocking descriptor
    /// (EAGAIN → wait for POLLOUT). false = the descriptor can't take more.
    static func writeAll(_ fd: Int32, _ base: UnsafeRawPointer, _ count: Int) -> Bool {
        var offset = 0
        while offset < count {
            let w = write(fd, base + offset, count - offset)
            if w >= 0 {
                offset += w
                continue
            }
            switch errno {
            case EINTR:
                continue
            case EAGAIN:
                var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                if poll(&p, 1, -1) < 0, errno != EINTR { return false }
            default:
                return false
            }
        }
        return true
    }

    // MARK: - Event file

    /// Appends observed events. Each line is one O_APPEND write kept under
    /// 4 KB so concurrent observers never interleave.
    final class EventSink {
        let context: Context
        private var directoryReady = false

        init(context: Context) {
            self.context = context
        }

        func write(_ event: ObservedEvent, now: Date = Date()) {
            guard let url = context.eventsURL,
                  let line = ClaudeObserver.encode(event, context: context, now: now) else { return }
            if !directoryReady {
                directoryReady = (try? AppPaths.ensurePrivateDirectory(url.deletingLastPathComponent())) != nil
            }
            try? JSONLines.append(line, to: url)
        }
    }

    static let maxEventLine = 4000

    /// One `events.jsonl` line (with trailing newline), or nil if it can't be
    /// kept atomic-sized even after dropping the per-model breakdown.
    static func encode(_ event: ObservedEvent, context: Context, now: Date) -> Data? {
        var obj: [String: Any] = [
            "v": 1,
            "ts": Int64((now.timeIntervalSince1970 * 1000).rounded()),
        ]
        obj["launchId"] = context.launchId ?? NSNull()
        obj["accountId"] = context.accountId ?? NSNull()
        obj["tokenHash"] = context.tokenHash ?? NSNull()
        for (k, v) in event.fields { obj[k] = v }
        func serialize(_ o: [String: Any]) -> Data? {
            guard JSONSerialization.isValidJSONObject(o),
                  var data = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
            else { return nil }
            data.append(0x0A)
            return data
        }
        guard var line = serialize(obj) else { return nil }
        if line.count > maxEventLine, obj["modelUsage"] != nil {
            obj["modelUsage"] = nil
            obj["modelUsageDropped"] = true
            guard let shorter = serialize(obj) else { return nil }
            line = shorter
        }
        return line.count > maxEventLine ? nil : line
    }
}

/// What the observer records. `fields` = the type-specific part of the line.
enum ObservedEvent: Equatable {
    /// `{"type":"system","subtype":"init","session_id":…}`
    case session(sessionId: String)
    /// `{"type":"rate_limit_event","rate_limit_info":{…},"session_id":…}`
    case rateLimit(RateLimitInfo)
    /// `{"type":"result",…}` — token counts only, no content.
    case result(ResultSummary)
    /// Limit phrase in plain text output or in an error result.
    case limitText(source: String, match: String, sessionId: String?)

    struct RateLimitInfo: Equatable {
        var sessionId: String?
        var status: String?
        var rateLimitType: String?
        var resetsAt: Double?
        var overageStatus: String?
        /// `unifiedWindows` as sent: window name → (utilization 0~1, resetsAt epoch s).
        var windows: [String: Window]

        struct Window: Equatable {
            var utilization: Double?
            var resetsAt: Double?
        }
    }

    struct ResultSummary: Equatable {
        var sessionId: String?
        var subtype: String?
        var isError: Bool
        var totalCostUsd: Double?
        var modelUsage: [String: ModelTokens]

        struct ModelTokens: Equatable {
            var inputTokens: Int64?
            var outputTokens: Int64?
            var cacheReadInputTokens: Int64?
            var cacheCreationInputTokens: Int64?
        }
    }

    var type: String {
        switch self {
        case .session: return "session"
        case .rateLimit: return "rate_limit"
        case .result: return "result"
        case .limitText: return "limit_text"
        }
    }

    var fields: [String: Any] {
        func opt(_ v: Any?) -> Any { v ?? NSNull() }
        var f: [String: Any] = ["type": type]
        switch self {
        case .session(let id):
            f["sessionId"] = id
        case .rateLimit(let info):
            f["sessionId"] = opt(info.sessionId)
            f["status"] = opt(info.status)
            f["rateLimitType"] = opt(info.rateLimitType)
            f["resetsAt"] = opt(info.resetsAt)
            f["overageStatus"] = opt(info.overageStatus)
            var windows: [String: Any] = [:]
            for (name, w) in info.windows {
                windows[name] = ["utilization": opt(w.utilization), "resetsAt": opt(w.resetsAt)]
            }
            f["windows"] = windows
        case .result(let r):
            f["sessionId"] = opt(r.sessionId)
            f["subtype"] = opt(r.subtype)
            f["isError"] = r.isError
            f["totalCostUsd"] = opt(r.totalCostUsd)
            var usage: [String: Any] = [:]
            for (model, t) in r.modelUsage {
                usage[model] = [
                    "inputTokens": opt(t.inputTokens),
                    "outputTokens": opt(t.outputTokens),
                    "cacheReadInputTokens": opt(t.cacheReadInputTokens),
                    "cacheCreationInputTokens": opt(t.cacheCreationInputTokens),
                ]
            }
            f["modelUsage"] = usage
        case .limitText(let source, let match, let sessionId):
            f["source"] = source
            f["match"] = match
            f["sessionId"] = opt(sessionId)
        }
        return f
    }
}

/// Pure line → events rules for claude's `-p` output (text / json /
/// stream-json). Shapes per F4 (2026-11-19 recorded stream, claude 2.1.293).
enum ClaudeStreamParser {
    /// Same phrase set as claude-failover's `LIMIT_TEXT_RE` (case-insensitive).
    static let limitRegex: NSRegularExpression = {
        let pattern = #"hit your (session |weekly |monthly spend |fast |usage )?limit"#
            + #"|You've reached your [^.\n]{0,40}limit"#
            + #"|usage limit reached"#
            + #"|out of (extra )?usage"#
            + #"|requires usage credits"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// Plain-text lines longer than this are model output, not claude's own
    /// limit error (a one-liner) — skipping them keeps answers that merely
    /// discuss limits from triggering a roll.
    static let maxTextLineForLimit = 512

    /// Lines worth a JSON parse: claude's `-p` JSON output is compact, so the
    /// three record types we read always contain one of these byte strings.
    private static let markers: [Data] = [
        Data(#""subtype":"init""#.utf8),
        Data(#""type":"rate_limit_event""#.utf8),
        Data(#""type":"result""#.utf8),
    ]

    static func parse(line raw: Data) -> [ObservedEvent] {
        var line = raw
        if line.last == 0x0D { line.removeLast() }  // CRLF
        guard let first = line.first(where: { $0 != 0x20 && $0 != 0x09 }) else { return [] }

        if first != UInt8(ascii: "{") {
            return textEvents(line)
        }
        guard markers.contains(where: { line.range(of: $0) != nil }) else { return [] }
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            return textEvents(line)
        }
        return jsonEvents(obj)
    }

    static func jsonEvents(_ obj: [String: Any]) -> [ObservedEvent] {
        let sessionId = obj["session_id"] as? String
        switch obj["type"] as? String {
        case "system":
            guard obj["subtype"] as? String == "init", let sessionId else { return [] }
            return [.session(sessionId: sessionId)]

        case "rate_limit_event":
            let info = obj["rate_limit_info"] as? [String: Any] ?? [:]
            var windows: [String: ObservedEvent.RateLimitInfo.Window] = [:]
            for (name, value) in info["unifiedWindows"] as? [String: Any] ?? [:] {
                guard let w = value as? [String: Any] else { continue }
                windows[name] = .init(utilization: number(w["utilization"]), resetsAt: number(w["resetsAt"]))
            }
            return [.rateLimit(.init(
                sessionId: sessionId,
                status: info["status"] as? String,
                rateLimitType: info["rateLimitType"] as? String,
                resetsAt: number(info["resetsAt"]),
                overageStatus: info["overageStatus"] as? String,
                windows: windows))]

        case "result":
            let isError = (obj["is_error"] as? Bool) ?? false
            var usage: [String: ObservedEvent.ResultSummary.ModelTokens] = [:]
            for (model, value) in obj["modelUsage"] as? [String: Any] ?? [:] {
                guard let m = value as? [String: Any] else { continue }
                usage[model] = .init(
                    inputTokens: integer(m["inputTokens"]),
                    outputTokens: integer(m["outputTokens"]),
                    cacheReadInputTokens: integer(m["cacheReadInputTokens"]),
                    cacheCreationInputTokens: integer(m["cacheCreationInputTokens"]))
            }
            var out: [ObservedEvent] = [.result(.init(
                sessionId: sessionId,
                subtype: obj["subtype"] as? String,
                isError: isError,
                totalCostUsd: number(obj["total_cost_usd"]),
                modelUsage: usage))]
            if isError, let text = obj["result"] as? String, let match = limitMatch(text) {
                out.append(.limitText(source: "result", match: match, sessionId: sessionId))
            }
            return out

        default:
            return []
        }
    }

    private static func textEvents(_ line: Data) -> [ObservedEvent] {
        guard line.count <= maxTextLineForLimit,
              let text = String(data: line, encoding: .utf8),
              let match = limitMatch(text) else { return [] }
        return [.limitText(source: "text", match: match, sessionId: nil)]
    }

    static func limitMatch(_ text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let m = limitRegex.firstMatch(in: text, range: range),
              let r = Range(m.range, in: text) else { return nil }
        return String(text[r])
    }

    /// JSON numbers only (a Bool is also an NSNumber — rejected).
    private static func number(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }

    private static func integer(_ v: Any?) -> Int64? {
        number(v).flatMap { $0.rounded() == $0 && abs($0) < 9e15 ? Int64($0) : nil }
    }
}

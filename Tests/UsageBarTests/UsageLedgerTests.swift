import Foundation
import XCTest
@testable import usagebar

/// Fixture session logs in a temp dir; real files, real SQLite. No launch
/// records — every session on the Mac counts (계정 구분 없이 이 맥 전체 합계).
final class UsageLedgerTests: XCTestCase {
    var claudeDir: URL!
    var projects: URL!
    var project: URL!
    let kst = TimeZone(identifier: "Asia/Seoul")!
    /// 집계 시작(장부를 처음 연 시각) — 2026-11-19 09:00 KST
    let start = ISO8601DateFormatter().date(from: "2026-11-19T00:00:00Z")!
    /// 2026-11-19 15:00 KST
    let now = ISO8601DateFormatter().date(from: "2026-11-19T06:00:00Z")!

    override func setUp() {
        let root = makeTempDir()
        claudeDir = root.appendingPathComponent("claude", isDirectory: true)
        projects = root.appendingPathComponent("projects", isDirectory: true)
        project = projects.appendingPathComponent("-Users-me-repo", isDirectory: true)
        try! FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    func makeLedger(at time: Date? = nil, table: ModelPriceTable = ModelPriceSource.bundledTable) -> UsageLedger {
        let t = time ?? now
        return UsageLedger(directory: claudeDir, projectsRoot: projects, timeZone: kst, now: { t },
                           prices: { table })
    }

    /// 장부를 `at` 시각에 처음 열어 집계 시작을 고정한다(파일이 없을 때 호출).
    func startTracking(at time: Date? = nil) throws {
        try makeLedger(at: time ?? start).ingest()
    }

    // MARK: - Fixtures

    func ms(_ iso: String) -> Int64 {
        Int64((ISO8601DateFormatter.fractional.date(from: iso)!.timeIntervalSince1970 * 1000).rounded())
    }

    func appendRaw(_ data: Data, to url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let h = try! FileHandle(forWritingTo: url)
        h.seekToEndOfFile()
        h.write(data)
        try! h.close()
    }

    /// Claude Code's assistant line (compact JSON, F6/F7 shape).
    func assistant(session: String, ts: String, mid: String, rid: String? = "req_1",
                   model: String = "claude-haiku-4-5-20251001",
                   input: Int = 10, output: Int = 891, cacheRead: Int = 17_957,
                   c5: Int = 0, c1: Int = 44_247, web: Int = 0,
                   speed: String = "standard", geo: String = "global",
                   breakdown: Bool = true, sidechain: Bool = false) -> String {
        var usage: [String: Any] = [
            "input_tokens": input, "output_tokens": output, "cache_read_input_tokens": cacheRead,
            "cache_creation_input_tokens": c5 + c1, "service_tier": "standard",
            "server_tool_use": ["web_search_requests": web, "web_fetch_requests": 0],
            "speed": speed, "inference_geo": geo,
        ]
        if breakdown {
            usage["cache_creation"] = ["ephemeral_5m_input_tokens": c5, "ephemeral_1h_input_tokens": c1]
        }
        var obj: [String: Any] = [
            "type": "assistant", "sessionId": session, "timestamp": ts, "uuid": UUID().uuidString,
            "isSidechain": sidechain, "cwd": "/Users/me/repo",
            "message": ["id": mid, "model": model, "role": "assistant", "type": "message", "usage": usage,
                        "content": [["type": "text", "text": "hi"]]],
        ]
        obj["requestId"] = rid ?? NSNull()
        if rid == nil { obj.removeValue(forKey: "requestId") }
        let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    func write(_ lines: [String], file: URL, terminated: Bool = true) {
        var text = lines.joined(separator: "\n")
        if terminated, !lines.isEmpty { text += "\n" }
        appendRaw(Data(text.utf8), to: file)
    }


    func sessionFile(_ id: String, in dir: URL? = nil) -> URL {
        (dir ?? project).appendingPathComponent("\(id).jsonl")
    }

    func rows(_ ledger: UsageLedger, from: String = "2026-01-01", to: String = "2026-12-31") -> [LedgerRow] {
        try! ledger.rows(fromDay: from, toDay: to)
    }

    func total(_ rows: [LedgerRow]) -> TokenCounts { rows.reduce(TokenCounts()) { $0 + $1.tokens } }

    let s1 = "11111111-1111-4111-8111-111111111111"
    let s2 = "22222222-2222-4222-8222-222222222222"

    // MARK: - 집계 시작

    func testFirstScanFixesTrackingStartOnce() throws {
        let ledger = makeLedger(at: start)
        XCTAssertNil(ledger.trackingStartedAt(), "장부 파일이 없으면 시작 시각도 없음")
        XCTAssertEqual(try ledger.ingest().trackingStartedAt, start)
        XCTAssertEqual(ledger.trackingStartedAt(), start)
        // 이후 스캔·재시작에도 바뀌지 않는다.
        let later = makeLedger(at: now)
        XCTAssertEqual(try later.ingest().trackingStartedAt, start)
        XCTAssertEqual(makeLedger(at: now.addingTimeInterval(86_400)).trackingStartedAt(), start)
    }

    /// 처음 켜진 순간 이미 있던 기록은 넣지 않는다 — 열려 있던 파일의 옛 줄도 버린다.
    func testFirstScanDoesNotBackfillExistingHistory() throws {
        let f = sessionFile(s1)
        write([assistant(session: s1, ts: "2026-11-18T23:00:00.000Z", mid: "old1"),
               assistant(session: s1, ts: "2026-11-18T23:59:59.999Z", mid: "old2")], file: f)
        let first = try makeLedger(at: start).ingest()
        XCTAssertEqual(first.counted, 0)
        XCTAssertEqual(first.outOfWindow, 2)
        // 같은 세션이 이어서 쓴 줄부터 집계된다.
        write([assistant(session: s1, ts: "2026-11-19T00:00:00.000Z", mid: "new")], file: f)
        let ledger = makeLedger()
        let r = try ledger.ingest()
        XCTAssertEqual(r.counted, 1)
        XCTAssertEqual(r.outOfWindow, 0, "옛 줄은 오프셋 뒤라 다시 읽지 않음")
        XCTAssertEqual(total(rows(ledger)).messages, 1)
    }

    func testMessagesBeforeTrackingStartAreDropped() throws {
        try startTracking()
        write([assistant(session: s1, ts: "2026-11-18T23:59:59.999Z", mid: "old"),
               assistant(session: s1, ts: "2026-11-19T00:00:00.500Z", mid: "new")], file: sessionFile(s1))
        let ledger = makeLedger()
        let r = try ledger.ingest()
        XCTAssertEqual(r.counted, 1)
        XCTAssertEqual(r.outOfWindow, 1)
    }

    func testFilesLastModifiedBeforeTrackingStartAreNotOpened() throws {
        try startTracking()
        // Content says "after start" but the file wasn't touched since before
        // tracking began → not opened at all.
        let f = sessionFile(s1)
        write([assistant(session: s1, ts: "2026-11-19T01:00:00.000Z", mid: "m1")], file: f)
        let old = ISO8601DateFormatter().date(from: "2026-11-18T23:00:00Z")!
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: f.path)
        let ledger = makeLedger()
        let r = try ledger.ingest()
        XCTAssertEqual(r.filesRead, 0)
        XCTAssertTrue(rows(ledger).isEmpty)
    }

    // MARK: - 대상 줄·중복 제거·귀속 없음

    func testCountsAllTokenKindsOncePerMessageId() throws {
        try startTracking()
        let line = assistant(session: s1, ts: "2026-11-19T01:00:00.000Z", mid: "m1", web: 2)
        // One response logged once per content block (F6): same id + requestId.
        write([line, line, line, assistant(session: s1, ts: "2026-11-19T01:00:01.000Z", mid: "m1")], file: sessionFile(s1))
        let ledger = makeLedger()
        let r = try ledger.ingest()
        XCTAssertEqual(r.counted, 1)
        XCTAssertEqual(r.duplicates, 3)
        let got = rows(ledger)
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got[0].day, "2026-11-19")
        XCTAssertEqual(got[0].model, "claude-haiku-4-5-20251001")
        XCTAssertEqual(got[0].tokens, TokenCounts(input: 10, output: 891, cacheWrite5m: 0, cacheWrite1h: 44_247,
                                                  cacheRead: 17_957, webSearches: 2, messages: 1))
        // F9 through the whole pipeline (dated model id → undated price).
        let report = LedgerReport(rows: got, table: ModelPriceSource.bundledTable)
        XCTAssertEqual(report.total.cost, 0.0947547, accuracy: 1e-9)  // haiku has no web-search price
        XCTAssertTrue(report.total.isFullyPriced)
    }

    func testDedupFallsBackToUUIDAndSkipsSynthetic() throws {
        try startTracking()
        let noReq = assistant(session: s1, ts: "2026-11-19T01:00:00.000Z", mid: "m1", rid: nil)
        write([noReq, noReq,  // same uuid twice (identical line) → once
               assistant(session: s1, ts: "2026-11-19T01:00:00.000Z", mid: "m1", rid: nil),  // new uuid → counted
               assistant(session: s1, ts: "2026-11-19T01:00:00.000Z", mid: "x", model: "<synthetic>")],
              file: sessionFile(s1))
        let ledger = makeLedger()
        let r = try ledger.ingest()
        XCTAssertEqual(r.counted, 2)
        XCTAssertEqual(total(rows(ledger)).messages, 2)
    }

    func testSubagentFilesAreCounted() throws {
        try startTracking()
        write([assistant(session: s1, ts: "2026-11-19T01:00:00.000Z", mid: "m1")], file: sessionFile(s1))
        let sub = project.appendingPathComponent("\(s1)/subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        write([assistant(session: s1, ts: "2026-11-19T01:00:05.000Z", mid: "m2", model: "claude-opus-5-5", sidechain: true)],
              file: sub.appendingPathComponent("agent-abc.jsonl"))
        let ledger = makeLedger()
        XCTAssertEqual(try ledger.ingest().counted, 2)
        XCTAssertEqual(Set(rows(ledger).map(\.model)), ["claude-haiku-4-5-20251001", "claude-opus-5-5"])
    }

    /// 래퍼 실행 기록 없이 모든 세션·모든 프로젝트를 센다. 실행 기록 파일이
    /// 있어도(PR #1 개발 빌드 잔재) 읽지 않는다.
    func testAllSessionsCountedWithoutAttribution() throws {
        try startTracking()
        let other = projects.appendingPathComponent("-Users-me-other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        write([assistant(session: s1, ts: "2026-11-19T01:00:00.000Z", mid: "a")], file: sessionFile(s1))
        write([assistant(session: s2, ts: "2026-11-19T02:00:00.000Z", mid: "b")], file: sessionFile(s2, in: other))
        try Data(#"{"v":1,"ts":0,"sessionId":"11111111-1111-4111-8111-111111111111","accountId":null}"#.utf8 + [0x0A])
            .write(to: claudeDir.appendingPathComponent("launches.jsonl"))
        let ledger = makeLedger()
        let r = try ledger.ingest()
        XCTAssertEqual(r.counted, 2)
        let got = rows(ledger)
        XCTAssertEqual(got.count, 1, "같은 날·같은 모델은 한 칸")
        XCTAssertEqual(got.first?.tokens.messages, 2)
    }

    // MARK: Incremental reading

    func testAppendedLinesAreReadIncrementally() throws {
        try startTracking()
        let f = sessionFile(s1)
        write([assistant(session: s1, ts: "2026-11-19T01:00:00.000Z", mid: "m1")], file: f)
        let ledger = makeLedger()
        XCTAssertEqual(try ledger.ingest().counted, 1)
        // Nothing new → file not even read.
        XCTAssertEqual(try ledger.ingest().filesRead, 0)

        write([assistant(session: s1, ts: "2026-11-19T01:01:00.000Z", mid: "m2")], file: f)
        let r = try ledger.ingest()
        XCTAssertEqual(r.counted, 1)
        XCTAssertEqual(r.duplicates, 0)  // m1 wasn't re-read
        XCTAssertEqual(total(rows(ledger)).messages, 2)
    }

    func testUnterminatedLastLineWaitsForItsNewline() throws {
        try startTracking()
        let f = sessionFile(s1)
        let line = assistant(session: s1, ts: "2026-11-19T01:00:00.000Z", mid: "m1")
        let cut = line.utf8.count / 2
        appendRaw(Data(line.utf8.prefix(cut)), to: f)
        let ledger = makeLedger()
        XCTAssertEqual(try ledger.ingest().counted, 0)
        appendRaw(Data(line.utf8.dropFirst(cut)), to: f)
        XCTAssertEqual(try ledger.ingest().counted, 0)  // complete JSON but still no newline
        appendRaw(Data("\n".utf8), to: f)
        XCTAssertEqual(try ledger.ingest().counted, 1)
        XCTAssertEqual(total(rows(ledger)).messages, 1)
    }

    func testReplacedOrShrunkFileIsReReadWithoutDoubleCounting() throws {
        try startTracking()
        let f = sessionFile(s1)
        let l1 = assistant(session: s1, ts: "2026-11-19T01:00:00.000Z", mid: "m1")
        let l2 = assistant(session: s1, ts: "2026-11-19T01:01:00.000Z", mid: "m2")
        let l3 = assistant(session: s1, ts: "2026-11-19T01:02:00.000Z", mid: "m3")
        write([l1, l2], file: f)
        let ledger = makeLedger()
        XCTAssertEqual(try ledger.ingest().counted, 2)

        // Replaced (new inode): same history + one more line.
        let tmp = project.appendingPathComponent("tmp.swap")
        write([l1, l2, l3], file: tmp)
        XCTAssertEqual(rename(tmp.path, f.path), 0)
        let r = try ledger.ingest()
        XCTAssertEqual(r.counted, 1)
        XCTAssertEqual(r.duplicates, 2)

        // Shrunk in place: re-read from 0, nothing new.
        let h = try FileHandle(forWritingTo: f)
        try h.truncate(atOffset: UInt64((l1 + "\n").utf8.count))
        try h.close()
        let s = try ledger.ingest()
        XCTAssertEqual(s.counted, 0)
        XCTAssertEqual(s.duplicates, 1)
        XCTAssertEqual(total(rows(ledger)).messages, 3)
    }

    func testLedgerSurvivesRestart() throws {
        try startTracking()
        let f = sessionFile(s1)
        write([assistant(session: s1, ts: "2026-11-19T01:00:00.000Z", mid: "m1")], file: f)
        try makeLedger().ingest()
        write([assistant(session: s1, ts: "2026-11-19T01:01:00.000Z", mid: "m2")], file: f)
        let restarted = makeLedger()
        let r = try restarted.ingest()
        XCTAssertEqual(r.counted, 1)
        XCTAssertEqual(r.duplicates, 0)
        XCTAssertEqual(total(rows(restarted)).messages, 2)
        XCTAssertEqual(posixMode(restarted.dbURL), 0o600)
        XCTAssertEqual(posixMode(claudeDir), 0o700)
    }

    // MARK: Days, variants, windows

    func testLocalMidnightBoundaryKST() throws {
        try startTracking(at: ISO8601DateFormatter().date(from: "2026-11-18T00:00:00Z")!)
        write([assistant(session: s1, ts: "2026-11-18T14:59:59.999Z", mid: "before"),  // 23:59:59.999 KST
               assistant(session: s1, ts: "2026-11-18T15:00:00.000Z", mid: "after")],  // 00:00 KST 11-19
              file: sessionFile(s1))
        let ledger = makeLedger()
        try ledger.ingest()
        XCTAssertEqual(rows(ledger).map(\.day), ["2026-11-18", "2026-11-19"])
        XCTAssertEqual(rows(ledger, from: "2026-11-19", to: "2026-11-19").count, 1)
        XCTAssertEqual(try ledger.firstDay(), "2026-11-18")
    }

    func testCacheWriteWithoutBreakdownIsFiveMinute() throws {
        try startTracking()
        write([assistant(session: s1, ts: "2026-11-19T01:00:00.000Z", mid: "m1", c5: 700, c1: 0, breakdown: false)],
              file: sessionFile(s1))
        let ledger = makeLedger()
        try ledger.ingest()
        XCTAssertEqual(rows(ledger).first?.tokens.cacheWrite5m, 700)
        XCTAssertEqual(rows(ledger).first?.tokens.cacheWrite1h, 0)
    }

    func testFastAndUSResponsesAreSeparateCellsPricedWithMultipliers() throws {
        try startTracking()
        func opus(_ mid: String, speed: String, geo: String) -> String {
            assistant(session: s1, ts: "2026-11-19T01:00:00.000Z", mid: mid, model: "claude-opus-5-5",
                      input: 1_000_000, output: 0, cacheRead: 0, c5: 0, c1: 0, speed: speed, geo: geo)
        }
        write([opus("a", speed: "standard", geo: "global"), opus("b", speed: "fast", geo: "global"),
               opus("c", speed: "standard", geo: "us"), opus("d", speed: "fast", geo: "us")], file: sessionFile(s1))
        let ledger = makeLedger()
        try ledger.ingest()
        let got = rows(ledger)
        XCTAssertEqual(got.count, 4)
        let report = LedgerReport(rows: got, table: ModelPriceSource.bundledTable)
        XCTAssertEqual(report.total.cost, 4 + 8 + 4.4 + 8.8, accuracy: 1e-9)
        XCTAssertEqual(report.models.count, 1)  // one model line despite 4 cells
    }

    func testUnknownModelCountsTokensButIsUnpriced() throws {
        try startTracking()
        write([assistant(session: s1, ts: "2026-11-19T01:00:00.000Z", mid: "m1"),
               assistant(session: s1, ts: "2026-11-19T01:01:00.000Z", mid: "m2", model: "claude-mystery-9")],
              file: sessionFile(s1))
        let ledger = makeLedger()
        XCTAssertEqual(try ledger.ingest().counted, 2)
        let report = LedgerReport(rows: rows(ledger), table: ModelPriceSource.bundledTable)
        XCTAssertEqual(report.total.tokens.messages, 2)
        XCTAssertEqual(report.total.unpricedModels, ["claude-mystery-9"])
        XCTAssertEqual(report.total.cost, 0.0947547, accuracy: 1e-9, "미상 모델은 0으로 위장하지 않고 금액에서 빠짐")
        XCTAssertEqual(LedgerFormat.cost(report.total), "$0.09 + 단가 미상")
    }

    func testMessagesOlderThanKeyWindowAreIgnored() throws {
        try startTracking(at: ISO8601DateFormatter().date(from: "2026-07-01T00:00:00Z")!)
        write([assistant(session: s1, ts: "2026-08-01T00:00:00.000Z", mid: "ancient"),  // > 90 days before now
               assistant(session: s1, ts: "2026-11-19T01:00:00.000Z", mid: "recent")], file: sessionFile(s1))
        let ledger = makeLedger()
        let r = try ledger.ingest()
        XCTAssertEqual(r.counted, 1)
        XCTAssertEqual(r.outOfWindow, 1)
    }

    func testRetentionDropsOldRows() throws {
        try startTracking()
        write([assistant(session: s1, ts: "2026-11-19T01:00:00.000Z", mid: "m1")], file: sessionFile(s1))
        try makeLedger().ingest()
        XCTAssertEqual(rows(makeLedger()).count, 1)
        // 400일 안은 남고, 401일 뒤에는 지워진다.
        let within = makeLedger(at: now.addingTimeInterval(399 * 86_400))
        try within.ingest()
        XCTAssertEqual(rows(within, from: "2000-01-01", to: "2100-01-01").count, 1)
        let future = makeLedger(at: now.addingTimeInterval(401 * 86_400))
        try future.ingest()
        XCTAssertTrue(rows(future, from: "2000-01-01", to: "2100-01-01").isEmpty)
    }

    // MARK: Parser

    func testParserReadsRealLineShape() throws {
        // Recorded shape (2026-11-19, claude 2.1.293) incl. fields we ignore.
        let line = #"{"parentUuid":"p","isSidechain":false,"type":"assistant","message":{"model":"claude-sonnet-5-5","id":"msg_011","type":"message","role":"assistant","content":[],"usage":{"input_tokens":2,"cache_creation_input_tokens":11868,"cache_read_input_tokens":5768,"output_tokens":37,"output_tokens_details":{"thinking_tokens":0},"server_tool_use":{"web_search_requests":0,"web_fetch_requests":0},"service_tier":"standard","cache_creation":{"ephemeral_1h_input_tokens":11868,"ephemeral_5m_input_tokens":0},"inference_geo":"global","iterations":[],"speed":"standard","fallback_credit":null}},"requestId":"req_011","uuid":"u1","timestamp":"2026-11-19T03:21:58.214Z","sessionId":"f4a5cbeb-d733-5909-b89e-2a6f4e24705f"}"#
        let r = try XCTUnwrap(SessionLogParser.parse(Data(line.utf8)))
        XCTAssertEqual(r.dedupKey, "msg_011:req_011")
        XCTAssertEqual(r.model, "claude-sonnet-5-5")
        XCTAssertEqual(r.tokens, TokenCounts(input: 2, output: 37, cacheWrite5m: 0, cacheWrite1h: 11_868,
                                             cacheRead: 5_768, webSearches: 0, messages: 1))
        XCTAssertFalse(r.fast)
        XCTAssertFalse(r.us)
        XCTAssertEqual(r.timestamp.timeIntervalSince1970, 1_795_058_518.214, accuracy: 1e-6)
        XCTAssertEqual(SessionLogParser.quickTimestamp(Data(line.utf8)), r.timestamp)
        // User / other lines are ignored.
        XCTAssertNil(SessionLogParser.parse(Data(#"{"type":"user","message":{"usage":{}}}"#.utf8)))
        XCTAssertNil(SessionLogParser.parse(Data("not json".utf8)))
    }

    func testQuickTimestampDefersAmbiguousLinesToFullParse() {
        XCTAssertNil(SessionLogParser.quickTimestamp(Data(#"{"timestamp":"2026-11-19T03:21:58.214Z","x":{"timestamp":"2026-11-19T03:21:58.214Z"}}"#.utf8)))
        XCTAssertNil(SessionLogParser.quickTimestamp(Data(#"{"type":"assistant"}"#.utf8)))
    }

    func testTimestampFastPathMatchesISOParser() {
        for s in ["2026-11-19T03:21:58.214Z", "2024-02-29T23:59:59.999Z", "1970-01-01T00:00:00.000Z", "2026-01-01T00:00:00.001Z"] {
            XCTAssertEqual(SessionLogParser.parseTimestamp(s), Dates.fromISO(s), s)
        }
        XCTAssertEqual(SessionLogParser.parseTimestamp("2026-11-19T03:21:58Z"), Dates.fromISO("2026-11-19T03:21:58Z"))
        XCTAssertNil(SessionLogParser.parseTimestamp("yesterday"))
    }

    // MARK: - Long-context tier

    /// T1 (62,834 prompt) and T2 (342,655 prompt) on the same day and model:
    /// judged per request → two rows, cost = sum of the CLI values.
    func testLongContextJudgedPerRequestAndSummed() throws {
        try startTracking()
        write([
            assistant(session: s1, ts: "2026-11-19T01:00:00.000Z", mid: "t1", model: "claude-haiku-5-5",
                      input: 2, output: 4, cacheRead: 10_480, c1: 52_352),
            assistant(session: s1, ts: "2026-11-19T01:01:00.000Z", mid: "t2", model: "claude-haiku-5-5",
                      input: 2, output: 4, cacheRead: 13_049, c1: 329_604),
        ], file: sessionFile(s1))
        let ledger = makeLedger()
        XCTAssertEqual(try ledger.ingest().counted, 2)
        let got = rows(ledger)
        XCTAssertEqual(got.map(\.tier), [0, 100_000])
        XCTAssertEqual(Set(got.map(\.day)), ["2026-11-19"])
        let report = LedgerReport(rows: got, table: ModelPriceSource.bundledTable)
        XCTAssertEqual(report.total.cost, 0.0105774 + 0.33026745, accuracy: 1e-9)
        XCTAssertEqual(report.total.tokens.messages, 2)
        XCTAssertEqual(report.total.longContextTokens.messages, 1)
        XCTAssertEqual(report.total.longContextTokens.totalTokens, 2 + 4 + 13_049 + 329_604)
        XCTAssertEqual(report.models.count, 1)  // tiers merged per model on display
    }

    func testLongContextWithFastMultiplier() throws {
        var haiku = try XCTUnwrap(ModelPriceSource.bundledTable.lookup("claude-haiku-5-5")?.price)
        haiku.multipliers["fast"] = 2
        let table = ModelPriceTable(prices: ["claude-haiku-5-5": haiku])
        try makeLedger(at: start, table: table).ingest()
        write([
            assistant(session: s1, ts: "2026-11-19T01:00:00.000Z", mid: "t2", model: "claude-haiku-5-5",
                      input: 2, output: 4, cacheRead: 13_049, c1: 329_604, speed: "fast"),
            assistant(session: s1, ts: "2026-11-19T01:01:00.000Z", mid: "t2b", model: "claude-haiku-5-5",
                      input: 2, output: 4, cacheRead: 13_049, c1: 329_604),
        ], file: sessionFile(s1))
        let ledger = makeLedger(table: table)
        XCTAssertEqual(try ledger.ingest().counted, 2)
        let got = rows(ledger)
        XCTAssertEqual(got.count, 2)
        XCTAssertTrue(got.allSatisfy { $0.tier == 100_000 })
        XCTAssertEqual(LedgerReport(rows: got, table: table).total.cost, 0.33026745 * 3, accuracy: 1e-9)
    }

    /// 장부 합계 = 요청 하나하나를 따로 계산한 비용의 합 (구간·배수가 섞여도).
    func testLedgerTotalEqualsSumOfPerRequestCosts() throws {
        try startTracking()
        struct Req { var mid, model: String; var input, output, read, c5, c1: Int; var speed = "standard", geo = "global" }
        let reqs = [
            Req(mid: "f9", model: "claude-haiku-4-5-20251001", input: 10, output: 891, read: 17_957, c5: 0, c1: 44_247),
            Req(mid: "t1", model: "claude-haiku-5-5", input: 2, output: 4, read: 10_480, c5: 0, c1: 52_352),
            Req(mid: "t2", model: "claude-haiku-5-5", input: 2, output: 4, read: 13_049, c5: 0, c1: 329_604),
            Req(mid: "edge", model: "claude-haiku-5-5", input: 100_000, output: 7, read: 0, c5: 0, c1: 0),
            Req(mid: "over", model: "claude-haiku-5-5", input: 100_001, output: 7, read: 0, c5: 0, c1: 0),
            Req(mid: "o1", model: "claude-opus-5-5", input: 1_234, output: 5_678, read: 90_000, c5: 3_000, c1: 0,
                speed: "fast", geo: "us"),
        ]
        write(reqs.enumerated().map { i, q in
            assistant(session: s1, ts: "2026-11-19T01:0\(i):00.000Z", mid: q.mid, model: q.model,
                      input: q.input, output: q.output, cacheRead: q.read, c5: q.c5, c1: q.c1,
                      speed: q.speed, geo: q.geo)
        }, file: sessionFile(s1))
        let table = ModelPriceSource.bundledTable
        var expected = 0.0
        for q in reqs {
            let p = try XCTUnwrap(table.lookup(q.model)?.price)
            let t = TokenCounts(input: Int64(q.input), output: Int64(q.output), cacheWrite5m: Int64(q.c5),
                                cacheWrite1h: Int64(q.c1), cacheRead: Int64(q.read), webSearches: 0, messages: 1)
            expected += try XCTUnwrap(p.cost(t, fast: q.speed == "fast", us: q.geo == "us",
                                             tier: p.tierThreshold(promptTokens: t.promptTokens)))
        }
        let ledger = makeLedger()
        XCTAssertEqual(try ledger.ingest().counted, reqs.count)
        let report = LedgerReport(rows: rows(ledger), table: table)
        XCTAssertTrue(report.total.isFullyPriced)
        XCTAssertEqual(report.total.cost, expected, accuracy: 1e-9)
        XCTAssertEqual(report.days.map(\.day), ["2026-11-19"])
        XCTAssertEqual(report.days[0].total.cost, expected, accuracy: 1e-9)
        // 경계: 정확히 100,000은 기본, 100,001은 할증.
        let haikuRows = rows(ledger).filter { $0.model == "claude-haiku-5-5" }
        XCTAssertEqual(haikuRows.map(\.tier).sorted(), [0, 100_000])
        XCTAssertEqual(haikuRows.first { $0.tier == 0 }?.tokens.messages, 2)  // t1 + edge
    }

    /// PR #1 개발 빌드가 같은 경로에 남긴 계정별 장부(schema 2, account 열)는
    /// 읽기만 해도 깨지지 않고 통째로 비워지며, 다음 스캔이 집계를 새로 시작한다.
    func testPerAccountLedgerFromPR1IsReset() throws {
        let dbURL = claudeDir.appendingPathComponent("ledger.sqlite")
        do {
            let old = try SQLiteDB(path: dbURL.path)
            try old.exec("""
                PRAGMA journal_mode = WAL;
                CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE files(path TEXT PRIMARY KEY, inode INTEGER NOT NULL, offset INTEGER NOT NULL, mtime REAL NOT NULL);
                CREATE TABLE seen(key TEXT PRIMARY KEY, day TEXT NOT NULL) WITHOUT ROWID;
                CREATE TABLE usage(account TEXT NOT NULL, day TEXT NOT NULL, model TEXT NOT NULL,
                    fast INTEGER NOT NULL, us INTEGER NOT NULL, tier INTEGER NOT NULL,
                    input INTEGER NOT NULL, output INTEGER NOT NULL, cache_5m INTEGER NOT NULL,
                    cache_1h INTEGER NOT NULL, cache_read INTEGER NOT NULL, web_search INTEGER NOT NULL,
                    messages INTEGER NOT NULL,
                    PRIMARY KEY(account, day, model, fast, us, tier)) WITHOUT ROWID;
                INSERT INTO meta VALUES('schema', '2');
                INSERT INTO meta VALUES('trackingStartedAt', '\(ms("2026-11-01T00:00:00.000Z"))');
                INSERT INTO usage VALUES('\(UUID().uuidString)', '2026-11-19', 'claude-haiku-5-5', 0, 0, 0, 2, 4, 0, 1, 1, 0, 1);
                INSERT INTO seen VALUES('m1:req_1', '2026-11-19');
                INSERT INTO files VALUES('\(sessionFile(s1).path)', 1, 999999, 0);
                """)
        }
        // Reading first (the window may open before any scan): no crash, everything gone.
        let reader = makeLedger(at: start)
        XCTAssertEqual(rows(reader), [])
        XCTAssertNil(reader.trackingStartedAt())
        // The next scan starts tracking now; the old dedup key no longer blocks m1.
        XCTAssertEqual(try makeLedger(at: start).ingest().trackingStartedAt, start)
        write([assistant(session: s1, ts: "2026-11-19T01:00:00.000Z", mid: "m1")], file: sessionFile(s1))
        let ledger = makeLedger()
        XCTAssertEqual(try ledger.ingest().counted, 1)
        XCTAssertEqual(rows(ledger).count, 1)
        // Opening again is a no-op (already reset).
        XCTAssertEqual(makeLedger().trackingStartedAt(), start)
        XCTAssertEqual(rows(makeLedger()).count, 1)
    }
}

extension ISO8601DateFormatter {
    static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

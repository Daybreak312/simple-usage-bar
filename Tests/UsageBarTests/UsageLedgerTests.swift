import Foundation
import XCTest
@testable import usagebar

/// Fixture session logs + launch logs in a temp dir; real files, real SQLite.
final class UsageLedgerTests: XCTestCase {
    var claudeDir: URL!
    var projects: URL!
    var project: URL!
    let kst = TimeZone(identifier: "Asia/Seoul")!
    /// 2026-11-19 15:00 KST
    let now = ISO8601DateFormatter().date(from: "2026-11-19T06:00:00Z")!
    let accountA = UUID()
    let accountB = UUID()

    override func setUp() {
        let root = makeTempDir()
        claudeDir = root.appendingPathComponent("claude", isDirectory: true)
        projects = root.appendingPathComponent("projects", isDirectory: true)
        project = projects.appendingPathComponent("-Users-me-repo", isDirectory: true)
        try! FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    func makeLedger() -> UsageLedger {
        UsageLedger(directory: claudeDir, projectsRoot: projects, timeZone: kst, now: { [now] in now },
                    prices: { ModelPriceSource.bundledTable })
    }

    // MARK: - Fixtures

    func ms(_ iso: String) -> Int64 {
        Int64((ISO8601DateFormatter.fractional.date(from: iso)!.timeIntervalSince1970 * 1000).rounded())
    }

    func launch(_ ts: String, session: String?, account: UUID?, hash: String? = nil, launchId: String = UUID().uuidString) {
        var obj: [String: Any] = ["v": 1, "ts": ms(ts), "launchId": launchId, "sessionSource": "injected",
                                  "mode": "stream-json", "pid": 1, "cwd": "/Users/me/repo"]
        obj["accountId"] = account?.uuidString ?? NSNull()
        obj["tokenHash"] = hash ?? NSNull()
        obj["sessionId"] = session ?? NSNull()
        append(obj, to: claudeDir.appendingPathComponent("launches.jsonl"))
    }

    func event(_ ts: String, launchId: String, type: String, session: String) {
        append(["v": 1, "ts": ms(ts), "launchId": launchId, "type": type, "sessionId": session,
                "accountId": NSNull(), "tokenHash": NSNull()],
               to: claudeDir.appendingPathComponent("events.jsonl"))
    }

    func append(_ obj: [String: Any], to url: URL) {
        var data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        data.append(0x0A)
        appendRaw(data, to: url)
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

    func sessionFile(_ id: String) -> URL { project.appendingPathComponent("\(id).jsonl") }

    func rows(_ ledger: UsageLedger, from: String = "2026-01-01", to: String = "2026-12-31") -> [LedgerRow] {
        try! ledger.rows(fromDay: from, toDay: to)
    }

    func total(_ rows: [LedgerRow]) -> TokenCounts { rows.reduce(TokenCounts()) { $0 + $1.tokens } }

    let s1 = "11111111-1111-4111-8111-111111111111"
    let s2 = "22222222-2222-4222-8222-222222222222"

    // MARK: - Tests

    func testNoLaunchesMeansNothingTracked() throws {
        write([assistant(session: s1, ts: "2026-11-19T01:00:00.000Z", mid: "m1")], file: sessionFile(s1))
        let ledger = makeLedger()
        let r = try ledger.ingest(hashes: [:])
        XCTAssertNil(r.trackingStartedAt)
        XCTAssertTrue(rows(ledger).isEmpty)
        XCTAssertNil(ledger.trackingStartedAt())
    }

    func testCountsAllTokenKindsOncePerMessageId() throws {
        launch("2026-11-19T00:00:00.000Z", session: s1, account: accountA)
        let line = assistant(session: s1, ts: "2026-11-19T01:00:00.000Z", mid: "m1", web: 2)
        // One response logged once per content block (F6): same id + requestId.
        write([line, line, line, assistant(session: s1, ts: "2026-11-19T01:00:01.000Z", mid: "m1")], file: sessionFile(s1))
        let ledger = makeLedger()
        let r = try ledger.ingest(hashes: [:])
        XCTAssertEqual(r.counted, 1)
        XCTAssertEqual(r.duplicates, 3)
        let got = rows(ledger)
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got[0].accountId, accountA)
        XCTAssertEqual(got[0].day, "2026-11-19")
        XCTAssertEqual(got[0].model, "claude-haiku-4-5-20251001")
        XCTAssertEqual(got[0].tokens, TokenCounts(input: 10, output: 891, cacheWrite5m: 0, cacheWrite1h: 44_247,
                                                  cacheRead: 17_957, webSearches: 2, messages: 1))
        // F9 through the whole pipeline.
        let report = LedgerReport(rows: got, table: ModelPriceSource.bundledTable)
        XCTAssertEqual(report.total.cost, 0.0947547 + 2 * 0, accuracy: 1e-9)  // haiku has no web-search price
        XCTAssertTrue(report.total.isFullyPriced)
    }

    func testDedupFallsBackToUUIDAndSkipsSynthetic() throws {
        launch("2026-11-19T00:00:00.000Z", session: s1, account: accountA)
        let noReq = assistant(session: s1, ts: "2026-11-19T01:00:00.000Z", mid: "m1", rid: nil)
        write([noReq, noReq,  // same uuid twice (identical line) → once
               assistant(session: s1, ts: "2026-11-19T01:00:00.000Z", mid: "m1", rid: nil),  // new uuid → counted
               assistant(session: s1, ts: "2026-11-19T01:00:00.000Z", mid: "x", model: "<synthetic>")],
              file: sessionFile(s1))
        let ledger = makeLedger()
        let r = try ledger.ingest(hashes: [:])
        XCTAssertEqual(r.counted, 2)
        XCTAssertEqual(total(rows(ledger)).messages, 2)
    }

    func testSubagentFilesCountUnderParentSession() throws {
        launch("2026-11-19T00:00:00.000Z", session: s1, account: accountA)
        write([assistant(session: s1, ts: "2026-11-19T01:00:00.000Z", mid: "m1")], file: sessionFile(s1))
        let sub = project.appendingPathComponent("\(s1)/subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        write([assistant(session: s1, ts: "2026-11-19T01:00:05.000Z", mid: "m2", model: "claude-opus-5-5", sidechain: true)],
              file: sub.appendingPathComponent("agent-abc.jsonl"))
        let ledger = makeLedger()
        XCTAssertEqual(try ledger.ingest(hashes: [:]).counted, 2)
        XCTAssertEqual(Set(rows(ledger).map(\.model)), ["claude-haiku-4-5-20251001", "claude-opus-5-5"])
        XCTAssertTrue(rows(ledger).allSatisfy { $0.accountId == accountA })
    }

    func testMessagesBeforeTrackingStartAreDropped() throws {
        launch("2026-11-19T00:00:00.000Z", session: s1, account: accountA)
        write([assistant(session: s1, ts: "2026-11-18T23:59:59.999Z", mid: "old"),
               assistant(session: s1, ts: "2026-11-19T00:00:00.500Z", mid: "new")], file: sessionFile(s1))
        let ledger = makeLedger()
        let r = try ledger.ingest(hashes: [:])
        XCTAssertEqual(r.counted, 1)
        XCTAssertEqual(r.outOfWindow, 1)
        XCTAssertEqual(ledger.trackingStartedAt(), ISO8601DateFormatter.fractional.date(from: "2026-11-19T00:00:00.000Z"))
    }

    func testFilesLastModifiedBeforeTrackingStartAreNotOpened() throws {
        launch("2026-11-19T00:00:00.000Z", session: s1, account: accountA)
        // Content says "after start" but the file wasn't touched since before
        // tracking began → not opened at all.
        let f = sessionFile(s1)
        write([assistant(session: s1, ts: "2026-11-19T01:00:00.000Z", mid: "m1")], file: f)
        let old = ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z")!
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: f.path)
        let ledger = makeLedger()
        let r = try ledger.ingest(hashes: [:])
        XCTAssertEqual(r.filesRead, 0)
        XCTAssertTrue(rows(ledger).isEmpty)
    }

    func testTrackingStartIsFixedOnce() throws {
        launch("2026-11-19T00:00:00.000Z", session: s1, account: accountA)
        let ledger = makeLedger()
        try ledger.ingest(hashes: [:])
        let first = ledger.trackingStartedAt()
        // Launch log cleared and rewritten with later lines → start unchanged.
        try FileManager.default.removeItem(at: claudeDir.appendingPathComponent("launches.jsonl"))
        launch("2026-11-19T03:00:00.000Z", session: s1, account: accountA)
        let fresh = makeLedger()
        try fresh.ingest(hashes: [:])
        XCTAssertEqual(fresh.trackingStartedAt(), first)
    }

    func testSessionsWithoutLaunchRecordAreNotCounted() throws {
        launch("2026-11-19T00:00:00.000Z", session: s1, account: accountA)
        write([assistant(session: s2, ts: "2026-11-19T01:00:00.000Z", mid: "m1")], file: sessionFile(s2))
        // Keychain-login launch (no account, no hash) → not counted either.
        launch("2026-11-19T00:00:00.000Z", session: "33333333-3333-4333-8333-333333333333", account: nil)
        write([assistant(session: "33333333-3333-4333-8333-333333333333", ts: "2026-11-19T01:00:00.000Z", mid: "m2")],
              file: sessionFile("33333333-3333-4333-8333-333333333333"))
        let ledger = makeLedger()
        let r = try ledger.ingest(hashes: [:])
        XCTAssertEqual(r.counted, 0)
        XCTAssertEqual(r.unattributed, 2)
        XCTAssertTrue(rows(ledger).isEmpty)
    }

    /// OpenClaw resumes one session in a new process every turn; after a roll
    /// the next turns belong to the new account.
    func testResumeAfterRollMovesLaterTurnsToNewAccount() throws {
        launch("2026-11-19T00:00:00.000Z", session: s1, account: accountA)
        launch("2026-11-19T02:00:00.000Z", session: s1, account: accountB)
        write([assistant(session: s1, ts: "2026-11-19T01:00:00.000Z", mid: "t1"),
               assistant(session: s1, ts: "2026-11-19T01:59:59.999Z", mid: "t2"),
               assistant(session: s1, ts: "2026-11-19T02:00:00.000Z", mid: "t3"),
               assistant(session: s1, ts: "2026-11-19T03:00:00.000Z", mid: "t4")], file: sessionFile(s1))
        let ledger = makeLedger()
        try ledger.ingest(hashes: [:])
        let byAccount = Dictionary(grouping: rows(ledger), by: \.accountId).mapValues { total($0).messages }
        XCTAssertEqual(byAccount[accountA], 2)
        XCTAssertEqual(byAccount[accountB], 2)
    }

    func testTokenHashResolvesLaunchWithoutAccountId() throws {
        launch("2026-11-19T00:00:00.000Z", session: s1, account: nil, hash: "abcdef0123456789")
        write([assistant(session: s1, ts: "2026-11-19T01:00:00.000Z", mid: "m1")], file: sessionFile(s1))
        let ledger = makeLedger()
        XCTAssertEqual(try ledger.ingest(hashes: ["abcdef0123456789": accountB]).counted, 1)
        XCTAssertEqual(rows(ledger).first?.accountId, accountB)
    }

    func testSessionEventFillsLaunchWithoutSessionId() throws {
        let lid = UUID().uuidString
        launch("2026-11-19T00:00:00.000Z", session: nil, account: accountA, launchId: lid)  // --fork-session
        event("2026-11-19T00:00:01.000Z", launchId: lid, type: "session", session: s2)
        write([assistant(session: s2, ts: "2026-11-19T01:00:00.000Z", mid: "m1")], file: sessionFile(s2))
        let ledger = makeLedger()
        XCTAssertEqual(try ledger.ingest(hashes: [:]).counted, 1)
        XCTAssertEqual(rows(ledger).first?.accountId, accountA)
    }

    func testSessionEventOverridesWrongContinueGuess() {
        let lid = "L1"
        let start = Date(timeIntervalSince1970: 1000)
        let launch = LaunchRecord(launchId: lid, ts: start, accountId: accountA, tokenHash: nil, sessionId: s1)
        let index = LaunchIndex(launches: [launch, launch], sessionOf: [lid: s2])
        XCTAssertNil(index.launch(session: s1, at: start.addingTimeInterval(5)))
        XCTAssertEqual(index.account(session: s2, at: start.addingTimeInterval(5), hashes: [:]), accountA)
        XCTAssertNil(index.account(session: s2, at: start.addingTimeInterval(-1), hashes: [:]))
    }

    // MARK: Incremental reading

    func testAppendedLinesAreReadIncrementally() throws {
        launch("2026-11-19T00:00:00.000Z", session: s1, account: accountA)
        let f = sessionFile(s1)
        write([assistant(session: s1, ts: "2026-11-19T01:00:00.000Z", mid: "m1")], file: f)
        let ledger = makeLedger()
        XCTAssertEqual(try ledger.ingest(hashes: [:]).counted, 1)
        // Nothing new → file not even read.
        XCTAssertEqual(try ledger.ingest(hashes: [:]).filesRead, 0)

        write([assistant(session: s1, ts: "2026-11-19T01:01:00.000Z", mid: "m2")], file: f)
        let r = try ledger.ingest(hashes: [:])
        XCTAssertEqual(r.counted, 1)
        XCTAssertEqual(r.duplicates, 0)  // m1 wasn't re-read
        XCTAssertEqual(total(rows(ledger)).messages, 2)
    }

    func testUnterminatedLastLineWaitsForItsNewline() throws {
        launch("2026-11-19T00:00:00.000Z", session: s1, account: accountA)
        let f = sessionFile(s1)
        let line = assistant(session: s1, ts: "2026-11-19T01:00:00.000Z", mid: "m1")
        let cut = line.utf8.count / 2
        appendRaw(Data(line.utf8.prefix(cut)), to: f)
        let ledger = makeLedger()
        XCTAssertEqual(try ledger.ingest(hashes: [:]).counted, 0)
        appendRaw(Data(line.utf8.dropFirst(cut)), to: f)
        XCTAssertEqual(try ledger.ingest(hashes: [:]).counted, 0)  // complete JSON but still no newline
        appendRaw(Data("\n".utf8), to: f)
        XCTAssertEqual(try ledger.ingest(hashes: [:]).counted, 1)
        XCTAssertEqual(total(rows(ledger)).messages, 1)
    }

    func testReplacedOrShrunkFileIsReReadWithoutDoubleCounting() throws {
        launch("2026-11-19T00:00:00.000Z", session: s1, account: accountA)
        let f = sessionFile(s1)
        let l1 = assistant(session: s1, ts: "2026-11-19T01:00:00.000Z", mid: "m1")
        let l2 = assistant(session: s1, ts: "2026-11-19T01:01:00.000Z", mid: "m2")
        let l3 = assistant(session: s1, ts: "2026-11-19T01:02:00.000Z", mid: "m3")
        write([l1, l2], file: f)
        let ledger = makeLedger()
        XCTAssertEqual(try ledger.ingest(hashes: [:]).counted, 2)

        // Replaced (new inode): same history + one more line.
        let tmp = project.appendingPathComponent("tmp.swap")
        write([l1, l2, l3], file: tmp)
        XCTAssertEqual(rename(tmp.path, f.path), 0)
        let r = try ledger.ingest(hashes: [:])
        XCTAssertEqual(r.counted, 1)
        XCTAssertEqual(r.duplicates, 2)

        // Shrunk in place: re-read from 0, nothing new.
        let h = try FileHandle(forWritingTo: f)
        try h.truncate(atOffset: UInt64((l1 + "\n").utf8.count))
        try h.close()
        let s = try ledger.ingest(hashes: [:])
        XCTAssertEqual(s.counted, 0)
        XCTAssertEqual(s.duplicates, 1)
        XCTAssertEqual(total(rows(ledger)).messages, 3)
    }

    func testLedgerSurvivesRestart() throws {
        launch("2026-11-19T00:00:00.000Z", session: s1, account: accountA)
        let f = sessionFile(s1)
        write([assistant(session: s1, ts: "2026-11-19T01:00:00.000Z", mid: "m1")], file: f)
        try makeLedger().ingest(hashes: [:])
        write([assistant(session: s1, ts: "2026-11-19T01:01:00.000Z", mid: "m2")], file: f)
        let restarted = makeLedger()
        let r = try restarted.ingest(hashes: [:])
        XCTAssertEqual(r.counted, 1)
        XCTAssertEqual(r.duplicates, 0)
        XCTAssertEqual(total(rows(restarted)).messages, 2)
        XCTAssertEqual(posixMode(restarted.dbURL), 0o600)
    }

    // MARK: Days, buckets, variants

    func testLocalMidnightBoundaryKST() throws {
        launch("2026-11-18T00:00:00.000Z", session: s1, account: accountA)
        write([assistant(session: s1, ts: "2026-11-18T14:59:59.999Z", mid: "before"),  // 23:59:59.999 KST
               assistant(session: s1, ts: "2026-11-18T15:00:00.000Z", mid: "after")],  // 00:00 KST 11-19
              file: sessionFile(s1))
        let ledger = makeLedger()
        try ledger.ingest(hashes: [:])
        XCTAssertEqual(rows(ledger).map(\.day), ["2026-11-18", "2026-11-19"])
        XCTAssertEqual(rows(ledger, from: "2026-11-19", to: "2026-11-19").count, 1)
    }

    func testCacheWriteWithoutBreakdownIsFiveMinute() throws {
        launch("2026-11-19T00:00:00.000Z", session: s1, account: accountA)
        write([assistant(session: s1, ts: "2026-11-19T01:00:00.000Z", mid: "m1", c5: 700, c1: 0, breakdown: false)],
              file: sessionFile(s1))
        let ledger = makeLedger()
        try ledger.ingest(hashes: [:])
        XCTAssertEqual(rows(ledger).first?.tokens.cacheWrite5m, 700)
        XCTAssertEqual(rows(ledger).first?.tokens.cacheWrite1h, 0)
    }

    func testFastAndUSResponsesAreSeparateCellsPricedWithMultipliers() throws {
        launch("2026-11-19T00:00:00.000Z", session: s1, account: accountA)
        func opus(_ mid: String, speed: String, geo: String) -> String {
            assistant(session: s1, ts: "2026-11-19T01:00:00.000Z", mid: mid, model: "claude-opus-5-5",
                      input: 1_000_000, output: 0, cacheRead: 0, c5: 0, c1: 0, speed: speed, geo: geo)
        }
        write([opus("a", speed: "standard", geo: "global"), opus("b", speed: "fast", geo: "global"),
               opus("c", speed: "standard", geo: "us"), opus("d", speed: "fast", geo: "us")], file: sessionFile(s1))
        let ledger = makeLedger()
        try ledger.ingest(hashes: [:])
        let got = rows(ledger)
        XCTAssertEqual(got.count, 4)
        let report = LedgerReport(rows: got, table: ModelPriceSource.bundledTable)
        XCTAssertEqual(report.total.cost, 4 + 8 + 4.4 + 8.8, accuracy: 1e-9)
        XCTAssertEqual(report.accounts.first?.models.count, 1)  // one model line despite 4 cells
    }

    func testMessagesOlderThanKeyWindowAreIgnored() throws {
        launch("2026-07-01T00:00:00.000Z", session: s1, account: accountA)
        write([assistant(session: s1, ts: "2026-08-01T00:00:00.000Z", mid: "ancient"),  // > 90 days before now
               assistant(session: s1, ts: "2026-11-19T01:00:00.000Z", mid: "recent")], file: sessionFile(s1))
        let ledger = makeLedger()
        let r = try ledger.ingest(hashes: [:])
        XCTAssertEqual(r.counted, 1)
        XCTAssertEqual(r.outOfWindow, 1)
    }

    func testRetentionDropsOldRowsAndKeys() throws {
        launch("2026-11-19T00:00:00.000Z", session: s1, account: accountA)
        write([assistant(session: s1, ts: "2026-11-19T01:00:00.000Z", mid: "m1")], file: sessionFile(s1))
        try makeLedger().ingest(hashes: [:])
        // 401 days later the row is gone.
        let later = now.addingTimeInterval(401 * 86_400)
        let future = UsageLedger(directory: claudeDir, projectsRoot: projects, timeZone: kst, now: { later },
                                 prices: { ModelPriceSource.bundledTable })
        try future.ingest(hashes: [:])
        XCTAssertTrue(rows(future, from: "2000-01-01", to: "2100-01-01").isEmpty)
    }

    // MARK: Parser

    func testParserReadsRealLineShape() throws {
        // Recorded shape (2026-11-19, claude 2.1.293) incl. fields we ignore.
        let line = #"{"parentUuid":"p","isSidechain":false,"type":"assistant","message":{"model":"claude-sonnet-5-5","id":"msg_011","type":"message","role":"assistant","content":[],"usage":{"input_tokens":2,"cache_creation_input_tokens":11868,"cache_read_input_tokens":5768,"output_tokens":37,"output_tokens_details":{"thinking_tokens":0},"server_tool_use":{"web_search_requests":0,"web_fetch_requests":0},"service_tier":"standard","cache_creation":{"ephemeral_1h_input_tokens":11868,"ephemeral_5m_input_tokens":0},"inference_geo":"global","iterations":[],"speed":"standard","fallback_credit":null}},"requestId":"req_011","uuid":"u1","timestamp":"2026-11-19T03:21:58.214Z","sessionId":"f4a5cbeb-d733-5909-b89e-2a6f4e24705f"}"#
        let r = try XCTUnwrap(SessionLogParser.parse(Data(line.utf8)))
        XCTAssertEqual(r.dedupKey, "msg_011:req_011")
        XCTAssertEqual(r.sessionId, "f4a5cbeb-d733-5909-b89e-2a6f4e24705f")
        XCTAssertEqual(r.model, "claude-sonnet-5-5")
        XCTAssertEqual(r.tokens, TokenCounts(input: 2, output: 37, cacheWrite5m: 0, cacheWrite1h: 11_868,
                                             cacheRead: 5_768, webSearches: 0, messages: 1))
        XCTAssertFalse(r.fast)
        XCTAssertFalse(r.us)
        XCTAssertEqual(r.timestamp.timeIntervalSince1970, 1_795_058_518.214, accuracy: 1e-6)
        // User / other lines are ignored.
        XCTAssertNil(SessionLogParser.parse(Data(#"{"type":"user","message":{"usage":{}}}"#.utf8)))
        XCTAssertNil(SessionLogParser.parse(Data("not json".utf8)))
    }

    func testTimestampFastPathMatchesISOParser() {
        for s in ["2026-11-19T03:21:58.214Z", "2024-02-29T23:59:59.999Z", "1970-01-01T00:00:00.000Z", "2026-01-01T00:00:00.001Z"] {
            XCTAssertEqual(SessionLogParser.parseTimestamp(s), Dates.fromISO(s), s)
        }
        XCTAssertEqual(SessionLogParser.parseTimestamp("2026-11-19T03:21:58Z"), Dates.fromISO("2026-11-19T03:21:58Z"))
        XCTAssertNil(SessionLogParser.parseTimestamp("yesterday"))
    }

    // MARK: - Long-context tier (PRD Phase 5)

    /// T1 (62,834 prompt) and T2 (342,655 prompt) on the same day and model:
    /// judged per request → two rows, cost = sum of the CLI values.
    func testLongContextJudgedPerRequestAndSummed() throws {
        launch("2026-11-19T00:00:00.000Z", session: s1, account: accountA)
        write([
            assistant(session: s1, ts: "2026-11-19T01:00:00.000Z", mid: "t1", model: "claude-haiku-5-5",
                      input: 2, output: 4, cacheRead: 10_480, c1: 52_352),
            assistant(session: s1, ts: "2026-11-19T01:01:00.000Z", mid: "t2", model: "claude-haiku-5-5",
                      input: 2, output: 4, cacheRead: 13_049, c1: 329_604),
        ], file: sessionFile(s1))
        let ledger = makeLedger()
        XCTAssertEqual(try ledger.ingest(hashes: [:]).counted, 2)
        let got = rows(ledger)
        XCTAssertEqual(got.map(\.tier), [0, 100_000])
        XCTAssertEqual(Set(got.map(\.day)), ["2026-11-19"])
        let report = LedgerReport(rows: got, table: ModelPriceSource.bundledTable)
        XCTAssertEqual(report.total.cost, 0.0105774 + 0.33026745, accuracy: 1e-9)
        XCTAssertEqual(report.total.tokens.messages, 2)
        XCTAssertEqual(report.total.longContextTokens.messages, 1)
        XCTAssertEqual(report.total.longContextTokens.totalTokens, 2 + 4 + 13_049 + 329_604)
        XCTAssertEqual(report.accounts.first?.models.count, 1)  // tiers merged per model on display
    }

    func testLongContextWithFastMultiplier() throws {
        var haiku = try XCTUnwrap(ModelPriceSource.bundledTable.lookup("claude-haiku-5-5")?.price)
        haiku.multipliers["fast"] = 2
        let table = ModelPriceTable(prices: ["claude-haiku-5-5": haiku])
        launch("2026-11-19T00:00:00.000Z", session: s1, account: accountA)
        write([
            assistant(session: s1, ts: "2026-11-19T01:00:00.000Z", mid: "t2", model: "claude-haiku-5-5",
                      input: 2, output: 4, cacheRead: 13_049, c1: 329_604, speed: "fast"),
            assistant(session: s1, ts: "2026-11-19T01:01:00.000Z", mid: "t2b", model: "claude-haiku-5-5",
                      input: 2, output: 4, cacheRead: 13_049, c1: 329_604),
        ], file: sessionFile(s1))
        let ledger = UsageLedger(directory: claudeDir, projectsRoot: projects, timeZone: kst,
                                 now: { [now] in now }, prices: { table })
        XCTAssertEqual(try ledger.ingest(hashes: [:]).counted, 2)
        let got = rows(ledger)
        XCTAssertEqual(got.count, 2)
        XCTAssertTrue(got.allSatisfy { $0.tier == 100_000 })
        XCTAssertEqual(LedgerReport(rows: got, table: table).total.cost, 0.33026745 * 3, accuracy: 1e-9)
    }

    /// A ledger written by a development build before the tier column opens
    /// without crashing and is rebuilt from the session logs.
    func testPreTierLedgerFileIsRebuilt() throws {
        launch("2026-11-19T00:00:00.000Z", session: s1, account: accountA)
        write([assistant(session: s1, ts: "2026-11-19T01:00:00.000Z", mid: "t2", model: "claude-haiku-5-5",
                         input: 2, output: 4, cacheRead: 13_049, c1: 329_604)], file: sessionFile(s1))
        let dbURL = claudeDir.appendingPathComponent("ledger.sqlite")
        do {
            let old = try SQLiteDB(path: dbURL.path)
            try old.exec("""
                PRAGMA journal_mode = WAL;
                CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE files(path TEXT PRIMARY KEY, inode INTEGER NOT NULL, offset INTEGER NOT NULL, mtime REAL NOT NULL);
                CREATE TABLE seen(key TEXT PRIMARY KEY, day TEXT NOT NULL) WITHOUT ROWID;
                CREATE TABLE usage(account TEXT NOT NULL, day TEXT NOT NULL, model TEXT NOT NULL,
                    fast INTEGER NOT NULL, us INTEGER NOT NULL,
                    input INTEGER NOT NULL, output INTEGER NOT NULL, cache_5m INTEGER NOT NULL,
                    cache_1h INTEGER NOT NULL, cache_read INTEGER NOT NULL, web_search INTEGER NOT NULL,
                    messages INTEGER NOT NULL,
                    PRIMARY KEY(account, day, model, fast, us)) WITHOUT ROWID;
                INSERT INTO meta VALUES('schema', '1');
                INSERT INTO meta VALUES('trackingStartedAt', '\(ms("2026-11-19T00:00:00.000Z"))');
                INSERT INTO usage VALUES('\(accountA.uuidString)', '2026-11-19', 'claude-haiku-5-5', 0, 0, 2, 4, 0, 329604, 13049, 0, 1);
                INSERT INTO seen VALUES('t2:req_1', '2026-11-19');
                INSERT INTO files VALUES('\(sessionFile(s1).path)', 1, 999999, 0);
                """)
        }
        // Reading first (the detail window may open before any scan): no crash, old sums gone.
        let ledger = makeLedger()
        XCTAssertEqual(rows(ledger), [])
        XCTAssertEqual(ledger.trackingStartedAt(), ISO8601DateFormatter.fractional.date(from: "2026-11-19T00:00:00.000Z"))
        // The next scan re-reads the logs into the new schema.
        XCTAssertEqual(try ledger.ingest(hashes: [:]).counted, 1)
        XCTAssertEqual(rows(ledger).map(\.tier), [100_000])
        // Opening again is a no-op (already rebuilt).
        XCTAssertEqual(try makeLedger().ingest(hashes: [:]).counted, 0)
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

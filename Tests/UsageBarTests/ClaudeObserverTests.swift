import XCTest
@testable import usagebar

/// F4 녹화 줄 (2026-11-19 claude 2.1.293 `-p --output-format stream-json --verbose`).
/// init은 필드 일부만 남김, result는 실제 키 순서(`duration_api_ms`가 먼저) 유지.
enum StreamFixture {
    static let initLine =
        #"{"type":"system","subtype":"init","cwd":"/Users/fury/work","session_id":"289f7f57-3ee2-48b6-9eab-7594cf4cd2c6","tools":["Bash"],"model":"claude-haiku-4-5","uuid":"0b9e2b7c-1d1e-4d0f-9a3c-8f1c9d2e4b5a"}"#
    static let thinkingLine =
        #"{"type":"system","subtype":"thinking_tokens","estimated_tokens":50,"estimated_tokens_delta":50,"session_id":"289f7f57-3ee2-48b6-9eab-7594cf4cd2c6","uuid":"8577986c-cc8f-444a-bf80-4231a66ceca0"}"#
    static let rateLimitLine =
        #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1795143600,"rateLimitType":"seven_day","overageStatus":"rejected","overageDisabledReason":"org_level_disabled","isUsingOverage":false,"unifiedWindows":{"seven_day":{"utilization":0.62,"resetsAt":1795143600}}},"uuid":"b4356288-7cb0-4778-89bd-58ce793e309b","session_id":"289f7f57-3ee2-48b6-9eab-7594cf4cd2c6"}"#
    static let resultLine =
        #"{"duration_api_ms":8269,"stop_reason":"end_turn","session_id":"289f7f57-3ee2-48b6-9eab-7594cf4cd2c6","total_cost_usd":0.0947547,"usage":{"input_tokens":10,"output_tokens":891},"modelUsage":{"claude-haiku-4-5":{"inputTokens":10,"outputTokens":891,"cacheReadInputTokens":17957,"cacheCreationInputTokens":44247,"webSearchRequests":0,"costUSD":0.0947547,"contextWindow":200000,"maxOutputTokens":32000}},"permission_denials":[],"is_error":false,"subtype":"success","api_error_status":null,"result":"ok","type":"result"}"#
    static let assistantLine =
        #"{"type":"assistant","message":{"model":"claude-haiku-4-5-20251001","id":"msg_01","content":[{"type":"text","text":"the \"type\":\"result\" text and usage limit reached"}]},"session_id":"289f7f57-3ee2-48b6-9eab-7594cf4cd2c6"}"#
}

final class ClaudeStreamParserTests: XCTestCase {
    private func parse(_ s: String) -> [ObservedEvent] {
        ClaudeStreamParser.parse(line: Data(s.utf8))
    }

    func testInitBecomesSessionEvent() {
        XCTAssertEqual(parse(StreamFixture.initLine), [.session(sessionId: "289f7f57-3ee2-48b6-9eab-7594cf4cd2c6")])
        XCTAssertEqual(parse(StreamFixture.thinkingLine), [])
    }

    func testRateLimitEventFields() {
        XCTAssertEqual(parse(StreamFixture.rateLimitLine), [.rateLimit(.init(
            sessionId: "289f7f57-3ee2-48b6-9eab-7594cf4cd2c6",
            status: "allowed", rateLimitType: "seven_day", resetsAt: 1_795_143_600,
            overageStatus: "rejected",
            windows: ["seven_day": .init(utilization: 0.62, resetsAt: 1_795_143_600)]))])
    }

    func testResultSummaryKeepsTokenCountsOnly() {
        XCTAssertEqual(parse(StreamFixture.resultLine), [.result(.init(
            sessionId: "289f7f57-3ee2-48b6-9eab-7594cf4cd2c6", subtype: "success", isError: false,
            totalCostUsd: 0.0947547,
            modelUsage: ["claude-haiku-4-5": .init(
                inputTokens: 10, outputTokens: 891,
                cacheReadInputTokens: 17957, cacheCreationInputTokens: 44247)]))])
    }

    func testErrorResultWithLimitTextAddsLimitEvent() {
        let line = #"{"type":"result","subtype":"success","is_error":true,"result":"You've hit your weekly limit · resets 3pm (Asia/Seoul)","session_id":"s1","total_cost_usd":0}"#
        let events = parse(line)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.last, .limitText(source: "result", match: "hit your weekly limit", sessionId: "s1"))
        // is_error=false면 같은 문구라도 한도 이벤트 아님.
        let fine = line.replacingOccurrences(of: #""is_error":true"#, with: #""is_error":false"#)
        XCTAssertEqual(parse(fine).count, 1)
    }

    func testAssistantContentNeverTriggers() {
        // 본문에 이스케이프된 "type":"result"·한도 문구가 있어도 JSON 줄이면 무시.
        XCTAssertEqual(parse(StreamFixture.assistantLine), [])
    }

    func testPlainTextLimitPhrases() {
        let phrases = [
            ("Claude AI usage limit reached|1795143600", "usage limit reached"),
            ("You've hit your limit · resets 5pm", "hit your limit"),
            ("You've hit your session limit", "hit your session limit"),
            ("You have hit your monthly spend limit", "hit your monthly spend limit"),
            ("You've reached your Opus usage limit", "You've reached your Opus usage limit"),
            ("You're out of extra usage", "out of extra usage"),
            ("This model requires usage credits", "requires usage credits"),
            ("YOU'VE HIT YOUR FAST LIMIT", "HIT YOUR FAST LIMIT"),
        ]
        for (text, match) in phrases {
            XCTAssertEqual(parse(text), [.limitText(source: "text", match: match, sessionId: nil)], text)
        }
        XCTAssertEqual(parse("all good"), [])
        XCTAssertEqual(parse(""), [])
        // 긴 텍스트 줄(모델 답변)은 한도 판정에서 제외.
        let long = String(repeating: "설명 ", count: 200) + "usage limit reached"
        XCTAssertEqual(parse(long), [])
    }

    func testMalformedInputIsHarmless() {
        XCTAssertEqual(parse(#"{"type":"result", broken"#), [])
        XCTAssertEqual(ClaudeStreamParser.parse(line: Data([0xFF, 0xFE, 0x0A])), [])
        XCTAssertEqual(parse(#"{"type":"rate_limit_event"}"#),
                       [.rateLimit(.init(sessionId: nil, status: nil, rateLimitType: nil,
                                         resetsAt: nil, overageStatus: nil, windows: [:]))])
        // 타입이 틀린 값은 버린다 (Bool은 숫자 아님).
        let weird = #"{"type":"rate_limit_event","rate_limit_info":{"status":1,"resetsAt":true,"unifiedWindows":{"seven_day":"x","five_hour":{"utilization":"0.5"}}}}"#
        XCTAssertEqual(parse(weird), [.rateLimit(.init(
            sessionId: nil, status: nil, rateLimitType: nil, resetsAt: nil, overageStatus: nil,
            windows: ["five_hour": .init(utilization: nil, resetsAt: nil)]))])
        // CRLF 끝.
        XCTAssertEqual(parse(StreamFixture.initLine + "\r").count, 1)
    }

    func testEncodeEventLine() throws {
        let ctx = ClaudeObserver.Context(launchId: "L1", accountId: "A1", tokenHash: "0123456789abcdef", eventsURL: nil)
        let event = parse(StreamFixture.rateLimitLine)[0]
        let line = try XCTUnwrap(ClaudeObserver.encode(event, context: ctx, now: Date(timeIntervalSince1970: 1_795_000_000.123)))
        XCTAssertEqual(line.last, 0x0A)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: line) as? [String: Any])
        XCTAssertEqual(obj["v"] as? Int, 1)
        XCTAssertEqual(obj["ts"] as? Int64, 1_795_000_000_123)
        XCTAssertEqual(obj["type"] as? String, "rate_limit")
        XCTAssertEqual(obj["launchId"] as? String, "L1")
        XCTAssertEqual(obj["accountId"] as? String, "A1")
        XCTAssertEqual(obj["tokenHash"] as? String, "0123456789abcdef")
        XCTAssertEqual(obj["status"] as? String, "allowed")
        let windows = try XCTUnwrap(obj["windows"] as? [String: [String: Double]])
        XCTAssertEqual(windows["seven_day"]?["utilization"], 0.62)

        // 컨텍스트 없음 → null.
        let bare = try XCTUnwrap(ClaudeObserver.encode(.session(sessionId: "s"), context: .init(), now: Date()))
        let bareObj = try XCTUnwrap(try JSONSerialization.jsonObject(with: bare) as? [String: Any])
        XCTAssertTrue(bareObj["accountId"] is NSNull)
        XCTAssertTrue(bareObj["launchId"] is NSNull)
    }

    func testEncodeDropsModelUsageToStayAtomicSized() throws {
        var usage: [String: ObservedEvent.ResultSummary.ModelTokens] = [:]
        for i in 0..<200 { usage["model-\(i)-" + String(repeating: "x", count: 20)] = .init() }
        let event = ObservedEvent.result(.init(sessionId: "s", subtype: nil, isError: false, totalCostUsd: 1, modelUsage: usage))
        let line = try XCTUnwrap(ClaudeObserver.encode(event, context: .init(), now: Date()))
        XCTAssertLessThan(line.count, 4096)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: line) as? [String: Any])
        XCTAssertNil(obj["modelUsage"])
        XCTAssertEqual(obj["modelUsageDropped"] as? Bool, true)
    }
}

final class ClaudeObserverPumpTests: XCTestCase {
    /// Feed `chunks` through `pump` via real pipes; returns (forwarded bytes, inspected lines).
    private func run(_ chunks: [Data], chunkSize: Int = 64 * 1024) -> (Data, [Data]) {
        let inPipe = Pipe(), outPipe = Pipe()
        let writer = Thread {
            for c in chunks { inPipe.fileHandleForWriting.write(c) }
            try? inPipe.fileHandleForWriting.close()
        }
        var forwarded = Data()
        let reader = Thread {
            forwarded = outPipe.fileHandleForReading.readDataToEndOfFile()
        }
        let done = expectation(description: "reader")
        let readerDone = Thread {
            while !reader.isFinished { usleep(1000) }
            done.fulfill()
        }
        writer.start(); reader.start(); readerDone.start()
        var lines: [Data] = []
        ClaudeObserver.pump(input: inPipe.fileHandleForReading.fileDescriptor,
                            output: outPipe.fileHandleForWriting.fileDescriptor,
                            chunkSize: chunkSize) { lines.append($0) }
        try? outPipe.fileHandleForWriting.close()
        wait(for: [done], timeout: 10)
        return (forwarded, lines)
    }

    func testBytesPassUnchangedAndLinesSplit() {
        let big = Data(repeating: UInt8(ascii: "x"), count: 5 * 1024 * 1024)
        var all = Data("first\n".utf8)
        all.append(big); all.append(0x0A)
        all.append(Data([0xFF, 0x00, 0x0A]))
        all.append(Data("tail-no-newline".utf8))
        // 줄 경계와 무관하게 쪼개 보낸다.
        let chunks = stride(from: 0, to: all.count, by: 7919).map {
            all.subdata(in: $0..<min($0 + 7919, all.count))
        }
        let (out, lines) = run(chunks, chunkSize: 4096)
        XCTAssertEqual(out, all)
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[0], Data("first".utf8))
        XCTAssertEqual(lines[1].count, big.count)
        XCTAssertEqual(lines[2], Data([0xFF, 0x00]))
        XCTAssertEqual(lines[3], Data("tail-no-newline".utf8))
    }

    func testEmptyInput() {
        let (out, lines) = run([])
        XCTAssertEqual(out, Data())
        XCTAssertEqual(lines, [])
    }

    func testClosedOutputStopsQuietly() {
        signal(SIGPIPE, SIG_IGN)
        let inPipe = Pipe(), outPipe = Pipe()
        try? outPipe.fileHandleForReading.close()  // 소비자가 닫음 → EPIPE
        inPipe.fileHandleForWriting.write(Data("a\nb\n".utf8))
        try? inPipe.fileHandleForWriting.close()
        var lines: [Data] = []
        ClaudeObserver.pump(input: inPipe.fileHandleForReading.fileDescriptor,
                            output: outPipe.fileHandleForWriting.fileDescriptor) { lines.append($0) }
        XCTAssertEqual(lines, [])  // 넘기지 못한 줄은 검사도 안 함 — 그냥 끝난다
    }

    func testEventSinkAppendsAndSurvivesBadDirectory() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("claude/events.jsonl")
        let sink = ClaudeObserver.EventSink(context: .init(launchId: "L", accountId: nil, tokenHash: nil, eventsURL: url))
        sink.write(.session(sessionId: "s1"))
        sink.write(.session(sessionId: "s2"))
        let lines = JSONLines.objects(at: url)
        XCTAssertEqual(lines.map { $0["sessionId"] as? String }, ["s1", "s2"])
        XCTAssertEqual(posixMode(url), 0o600)
        XCTAssertEqual(posixMode(url.deletingLastPathComponent()), 0o700)

        // 디렉터리를 만들 수 없는 경로 → 조용히 무시.
        let file = dir.appendingPathComponent("plain")
        try Data().write(to: file)
        let broken = ClaudeObserver.EventSink(context: .init(eventsURL: file.appendingPathComponent("x/events.jsonl")))
        broken.write(.session(sessionId: "s"))
    }
}

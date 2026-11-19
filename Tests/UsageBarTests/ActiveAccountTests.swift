import XCTest
@testable import usagebar

final class ActiveAccountTests: XCTestCase {
    func testWriteReadLineFormatAndPermissions() throws {
        let dir = makeTempDir().appendingPathComponent("claude", isDirectory: true)
        let store = ActiveAccountStore(directory: dir)
        XCTAssertNil(store.read())

        let id = UUID()
        try store.write(accountId: id, token: "sk-ant-oat01-abc")

        // bash가 외부 도구 없이 읽을 수 있는 줄 형식: 1줄 UUID, 2줄 토큰.
        let raw = try String(contentsOf: store.activeURL, encoding: .utf8)
        XCTAssertEqual(raw, "\(id.uuidString)\nsk-ant-oat01-abc\n")
        XCTAssertEqual(store.read(), .init(accountId: id, token: "sk-ant-oat01-abc"))
        XCTAssertEqual(posixMode(store.activeURL), 0o600)
        XCTAssertEqual(posixMode(dir), 0o700)
    }

    func testBashCanReadIt() throws {
        let dir = makeTempDir().appendingPathComponent("claude", isDirectory: true)
        let store = ActiveAccountStore(directory: dir)
        let id = UUID()
        try store.write(accountId: id, token: "sk-ant-oat01-zz_9-")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", #"{ IFS= read -r id; IFS= read -r tok; } < "$1"; printf '%s|%s' "$id" "$tok""#, "_", store.activeURL.path]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        XCTAssertEqual(text, "\(id.uuidString)|sk-ant-oat01-zz_9-")
    }

    func testReplaceIsAtomicAndLeavesNoTempFiles() throws {
        let dir = makeTempDir().appendingPathComponent("claude", isDirectory: true)
        let store = ActiveAccountStore(directory: dir)
        let a = UUID(), b = UUID()
        try store.write(accountId: a, token: "tok-a")
        let inodeBefore = try FileManager.default.attributesOfItem(atPath: store.activeURL.path)[.systemFileNumber] as? NSNumber
        try store.write(accountId: b, token: "tok-b")
        let inodeAfter = try FileManager.default.attributesOfItem(atPath: store.activeURL.path)[.systemFileNumber] as? NSNumber
        XCTAssertNotEqual(inodeBefore, inodeAfter, "rename 교체여야 함(제자리 덮어쓰기 아님)")
        XCTAssertEqual(store.read()?.accountId, b)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [])
        XCTAssertEqual(posixMode(store.activeURL), 0o600)
    }

    func testLooseExistingDirectoryIsTightened() throws {
        let dir = makeTempDir().appendingPathComponent("claude", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        XCTAssertEqual(posixMode(dir), 0o755)
        try ActiveAccountStore(directory: dir).write(accountId: UUID(), token: "t")
        XCTAssertEqual(posixMode(dir), 0o700)
    }

    func testInvalidTokensRejected() {
        let store = ActiveAccountStore(directory: makeTempDir())
        for bad in ["", "two\nlines", " padded", "has space"] {
            XCTAssertThrowsError(try store.write(accountId: UUID(), token: bad), bad)
        }
        XCTAssertNil(store.read())
    }

    func testMalformedFileReadsAsNoActive() throws {
        let dir = makeTempDir()
        let store = ActiveAccountStore(directory: dir)
        for text in ["", "not-a-uuid\ntok\n", "\(UUID().uuidString)\n", "\(UUID().uuidString)\n\n", "\(UUID().uuidString)\ntok en\n"] {
            try Data(text.utf8).write(to: store.activeURL)
            XCTAssertNil(store.read(), text)
        }
    }

    func testClearIfActive() throws {
        let store = ActiveAccountStore(directory: makeTempDir())
        let a = UUID()
        try store.write(accountId: a, token: "t")
        store.clear(ifActive: UUID())
        XCTAssertNotNil(store.read())
        store.clear(ifActive: a)
        XCTAssertNil(store.read())
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.activeURL.path))
    }

    func testRollHistoryAppendAndLastRoll() throws {
        let store = ActiveAccountStore(directory: makeTempDir())
        XCTAssertNil(store.lastRollAt())
        let a = UUID(), b = UUID()
        let t0 = Date(timeIntervalSince1970: 1_795_000_000)
        let t1 = t0.addingTimeInterval(600)
        try store.appendHistory(.init(ts: t0, from: nil, to: a, reason: "활성 계정 자동 지정"))
        XCTAssertNil(store.lastRollAt(), "초기 지정(from=null)은 쿨다운 기준이 아님")
        try store.appendHistory(.init(ts: t1, from: a, to: b, reason: "7d 96%"))

        let records = store.loadHistory()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[1], .init(ts: t1, from: a, to: b, reason: "7d 96%"))
        XCTAssertEqual(store.lastRollAt(), t1)
        XCTAssertEqual(posixMode(store.historyURL), 0o600)

        // 한 줄 = 한 JSON, 토큰 없음, from은 명시적 null.
        let lines = try String(contentsOf: store.historyURL, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains(#""from":null"#))
        XCTAssertTrue(lines[0].contains(#""ts":1795000000000"#))
        XCTAssertTrue(lines[1].contains(#""v":1"#))
    }
}

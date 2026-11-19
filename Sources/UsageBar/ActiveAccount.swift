import Foundation

/// The Claude account every `usagebar-claude` launch uses.
///
/// `<support>/claude/active` (0600, directory 0700) is line-based so the bash
/// wrapper can read it without external tools:
///
///     <account UUID>\n
///     <token>\n
///
/// Rolling = replacing this file (temp file in the same directory + rename,
/// so a reader sees the old or the new pair, never a torn one). No active
/// account = no file. Every replacement appends one line to
/// `roll-history.jsonl` (no token): `{"v":1,"ts":<ms>,"from":<uuid|null>,"to":<uuid>,"reason":…}`.
final class ActiveAccountStore {
    static let shared = ActiveAccountStore()

    struct Active: Equatable {
        let accountId: UUID
        let token: String
    }

    struct RollRecord: Equatable {
        let ts: Date
        let from: UUID?
        let to: UUID
        let reason: String
    }

    enum StoreError: LocalizedError {
        case invalidToken
        case io(String, Int32)

        var errorDescription: String? {
            switch self {
            case .invalidToken:
                return "활성 계정 파일에 쓸 수 없는 토큰 (빈 값 또는 공백·제어문자 포함)"
            case .io(let what, let code):
                return "\(what) 실패: \(String(cString: strerror(code)))"
            }
        }
    }

    let directory: URL
    var activeURL: URL { directory.appendingPathComponent("active") }
    var historyURL: URL { directory.appendingPathComponent("roll-history.jsonl") }

    init(directory: URL = AppPaths.claudeDirectory) {
        self.directory = directory
    }

    // MARK: - Active file

    func read() -> Active? {
        guard let text = try? String(contentsOf: activeURL, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 2,
              let id = UUID(uuidString: String(lines[0])),
              let token = ClaudeProvider.normalizeToken(String(lines[1])),
              token == String(lines[1]) else { return nil }
        return Active(accountId: id, token: token)
    }

    /// Atomic replace. The temp file is created 0600 from the first byte
    /// (O_EXCL + mode), so the token is never readable by others mid-write.
    func write(accountId: UUID, token: String) throws {
        guard let clean = ClaudeProvider.normalizeToken(token), clean == token else {
            throw StoreError.invalidToken
        }
        try ensureDirectory()
        let tmp = directory.appendingPathComponent(".active.\(UUID().uuidString).tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw StoreError.io("임시 파일 생성", errno) }
        var renamed = false
        defer { if !renamed { unlink(tmp.path) } }
        let payload = Data("\(accountId.uuidString)\n\(token)\n".utf8)
        let ok = payload.withUnsafeBytes { buf -> Bool in
            var offset = 0
            while offset < buf.count {
                let n = Foundation.write(fd, buf.baseAddress! + offset, buf.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += n
            }
            return true
        }
        let writeErr = errno
        // umask can only remove bits; fchmod pins exactly 0600 regardless.
        fchmod(fd, 0o600)
        fsync(fd)
        close(fd)
        guard ok else { throw StoreError.io("활성 계정 파일 쓰기", writeErr) }
        guard rename(tmp.path, activeURL.path) == 0 else {
            throw StoreError.io("활성 계정 파일 교체", errno)
        }
        renamed = true
    }

    /// Remove the active file (no active account → wrapper falls back to the
    /// keychain login).
    func clear() {
        unlink(activeURL.path)
    }

    /// Deleting the active account must not leave its token in `active`.
    func clear(ifActive id: UUID) {
        if read()?.accountId == id { clear() }
    }

    // MARK: - Roll history

    func appendHistory(_ record: RollRecord) throws {
        try ensureDirectory()
        var obj: [String: Any] = [
            "v": 1,
            "ts": Int64((record.ts.timeIntervalSince1970 * 1000).rounded()),
            "to": record.to.uuidString,
            "reason": record.reason,
        ]
        obj["from"] = record.from?.uuidString ?? NSNull()
        var line = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        line.append(0x0A)
        try JSONLines.append(line, to: historyURL)
    }

    func loadHistory() -> [RollRecord] {
        JSONLines.objects(at: historyURL).compactMap { obj in
            guard let ms = (obj["ts"] as? NSNumber)?.doubleValue,
                  let to = (obj["to"] as? String).flatMap(UUID.init(uuidString:)) else { return nil }
            return RollRecord(
                ts: Date(timeIntervalSince1970: ms / 1000),
                from: (obj["from"] as? String).flatMap(UUID.init(uuidString:)),
                to: to,
                reason: obj["reason"] as? String ?? "")
        }
    }

    /// Latest account-to-account roll (initial designations, from == nil,
    /// don't start a cooldown). Shared by the GUI and `usagebar roll`, and
    /// survives app restarts.
    func lastRollAt() -> Date? {
        loadHistory().filter { $0.from != nil }.map(\.ts).max()
    }

    // MARK: - Plumbing

    func ensureDirectory() throws {
        try AppPaths.ensurePrivateDirectory(directory)
    }
}

/// Newline-delimited JSON helpers shared by the claude/ data files.
enum JSONLines {
    /// One O_APPEND write per line — concurrent appenders (app, CLI, wrapper)
    /// never interleave within a line of reasonable size.
    static func append(_ line: Data, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { throw ActiveAccountStore.StoreError.io("\(url.lastPathComponent) 열기", errno) }
        defer { close(fd) }
        let written = line.withUnsafeBytes { Foundation.write(fd, $0.baseAddress!, $0.count) }
        guard written == line.count else {
            throw ActiveAccountStore.StoreError.io("\(url.lastPathComponent) 추가", errno)
        }
    }

    /// Every line that parses as a JSON object; malformed lines are skipped.
    static func objects(at url: URL) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any]
        }
    }
}

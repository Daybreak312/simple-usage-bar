import Foundation

/// Fixed data locations. Same domain whether the binary runs bundled
/// (/Applications) or bare (.build/debug).
enum AppPaths {
    /// ~/Library/Application Support/UsageBar
    static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UsageBar", isDirectory: true)
    }

    /// Claude 관측 데이터(사용률 이력·교체 기록, Phase 2부터 장부). 0700.
    static var claudeDirectory: URL {
        support.appendingPathComponent("claude", isDirectory: true)
    }

    /// Creates `url` as 0700, and tightens it if it already existed looser.
    static func ensurePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}

/// Newline-delimited JSON helpers shared by the claude/ data files.
enum JSONLines {
    /// One O_APPEND write per line — concurrent appenders (app, CLI) never
    /// interleave within a line of reasonable size. New files start 0600.
    static func append(_ line: Data, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { throw posixError("\(url.lastPathComponent) 열기") }
        defer { close(fd) }
        let written = line.withUnsafeBytes { Foundation.write(fd, $0.baseAddress!, $0.count) }
        guard written == line.count else { throw posixError("\(url.lastPathComponent) 추가") }
    }

    /// Every line that parses as a JSON object; malformed lines are skipped.
    static func objects(at url: URL) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any]
        }
    }

    /// Number of non-empty lines (parseable or not).
    static func lineCount(at url: URL) -> Int {
        guard let data = try? Data(contentsOf: url) else { return 0 }
        return data.split(separator: 0x0A).count
    }

    /// Atomic whole-file replace (temp file + rename), pinned to 0600.
    static func rewrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Epoch-ms field (`ts`) as a Date.
    static func timestamp(_ obj: [String: Any], key: String = "ts") -> Date? {
        (obj[key] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
    }

    static func epochMs(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }

    private static func posixError(_ what: String) -> Error {
        let code = errno
        return NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
            NSLocalizedDescriptionKey: "\(what) 실패: \(String(cString: strerror(code)))",
        ])
    }
}

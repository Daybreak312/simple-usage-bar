import Foundation

// MARK: - Webhook settings

struct AppSettings: Codable {
    var slackURL: String = ""
    var discordURL: String = ""
    /// Account whose percent shows in the menu bar; nil = worst across all.
    /// Optional so settings.json files from older versions still decode.
    var menuBarAccountId: String?

    var isEmpty: Bool { slackURL.isEmpty && discordURL.isEmpty }
}

/// Stored as settings.json next to accounts.json — same domain regardless of
/// whether the binary runs bundled (/Applications) or bare (.build/debug),
/// unlike UserDefaults whose domain depends on the bundle.
final class SettingsStore {
    static let shared = SettingsStore()

    private let url: URL

    init() {
        let dir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("UsageBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("settings.json")
    }

    func load() -> AppSettings {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return s
    }

    func save(_ settings: AppSettings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

// MARK: - TUI formatting (shared by CLI check and webhook alerts)

enum TUIFormat {
    static func gauge(_ title: String, _ w: WindowUsage?) -> String {
        guard let w else { return "\(title) [----------]   —%" }
        let filled = Int((min(w.percent, 100) / 10).rounded())
        let bar = String(repeating: "=", count: filled)
            + String(repeating: "-", count: 10 - filled)
        var s = "\(title) [\(bar)] \(String(format: "%3d", Int(w.percent)))%"
        if let resets = w.resetsAt {
            s += " (리셋 \(UsageGauge.countdown(to: resets)))"
        }
        return s
    }

    static func line(_ state: AccountState) -> String {
        let name = state.account.provider.displayName
            .padding(toLength: 6, withPad: " ", startingAt: 0)
        if let error = state.lastError {
            return "\(name) | \(state.account.label) | 오류: \(error)"
        }
        guard let snap = state.snapshot else {
            return "\(name) | \(state.account.label) | 데이터 없음"
        }
        var s = "\(name) | \(state.account.label) | \(gauge("5h", snap.fiveHour)) \(gauge("7d", snap.sevenDay))"
        if !snap.details.isEmpty {
            s += " | \(snap.details.joined(separator: ", "))"
        }
        return s
    }

    static func board(_ states: [AccountState]) -> String {
        states.map(line).joined(separator: "\n")
    }
}

// MARK: - Alert sending

enum AlertSender {
    /// One alert message: `[!]` header line + the full account board, as a
    /// monospace code block so the TUI layout survives Slack/Discord rendering.
    static func send(header: String, states: [AccountState]) async -> [(String, Int)] {
        let text = "```\n\(header)\n\n\(TUIFormat.board(states))\n```"
        let settings = SettingsStore.shared.load()
        var results: [(String, Int)] = []
        if !settings.discordURL.isEmpty {
            let status = await post(settings.discordURL, json: ["content": text])
            results.append(("discord", status))
        }
        if !settings.slackURL.isEmpty {
            let status = await post(settings.slackURL, json: ["text": text])
            results.append(("slack", status))
        }
        for (target, status) in results where !(200...299).contains(status) {
            FileHandle.standardError.write(Data("웹훅 전송 실패 (\(target)): HTTP \(status)\n".utf8))
        }
        return results
    }

    private static func post(_ urlString: String, json: [String: Any]) async -> Int {
        guard let body = try? JSONSerialization.data(withJSONObject: json) else { return -1 }
        do {
            let (status, _) = try await HTTP.request(
                urlString, method: "POST",
                headers: ["Content-Type": "application/json"],
                body: body, timeout: 10)
            return status
        } catch {
            return -1
        }
    }
}

// MARK: - Threshold crossing detection

enum AlertThresholds {
    /// Alert when a window's utilization crosses one of these upward.
    static let values: [Double] = [90, 80, 70, 50]

    /// Highest threshold crossed between two polls, or nil.
    /// A nil `old` means no baseline yet (first poll) — never alerts.
    static func crossed(old: Double?, new: Double?) -> Double? {
        guard let old, let new else { return nil }
        return values.first { old < $0 && new >= $0 }
    }
}

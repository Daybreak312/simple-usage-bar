import Foundation
import SwiftUI

/// Checks the GitHub repo for new commits and hands the actual work to
/// scripts/update.sh, launched detached so the app can be killed & relaunched
/// by the script without interrupting the pipeline.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    @Published var currentCommit: String?
    @Published var availableCommit: String?
    @Published var updating = false
    @Published var autoUpdate = true

    private var loopTask: Task<Void, Never>?

    /// Repo root: UserDefaults override first, else derived from the compiled
    /// source path (works as long as the checkout isn't moved).
    nonisolated static func repoPath() -> String? {
        if let override = UserDefaults.standard.string(forKey: "repoPath"),
           !override.isEmpty {
            return override
        }
        let derived = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // UsageBar/
            .deletingLastPathComponent()  // Sources/
            .deletingLastPathComponent()  // repo root
        let marker = derived.appendingPathComponent("Package.swift").path
        return FileManager.default.fileExists(atPath: marker) ? derived.path : nil
    }

    func start() {
        autoUpdate = SettingsStore.shared.load().autoUpdate ?? true
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(nanoseconds: 6 * 3600 * 1_000_000_000)
            }
        }
    }

    func setAutoUpdate(_ on: Bool) {
        autoUpdate = on
        var settings = SettingsStore.shared.load()
        settings.autoUpdate = on
        try? SettingsStore.shared.save(settings)
    }

    func check() async {
        guard let repo = Self.repoPath() else { return }
        let result = await Task.detached(priority: .utility) { () -> (String?, String?) in
            _ = Self.git(repo, ["fetch", "--quiet", "origin", "main"])
            let head = Self.git(repo, ["rev-parse", "--short", "HEAD"])
            let behindCount = Self.git(repo, ["rev-list", "--count", "HEAD..origin/main"])
                .flatMap { Int($0) } ?? 0
            let remote = behindCount > 0
                ? Self.git(repo, ["rev-parse", "--short", "origin/main"]) : nil
            return (head, remote)
        }.value
        currentCommit = result.0
        availableCommit = result.1
        // Hands-free rollout: new commit detected → install & relaunch.
        if availableCommit != nil, autoUpdate, !updating {
            apply()
        }
    }

    /// Fire the detached updater. The app keeps running until the script has
    /// built and installed the new bundle; the script then kills and reopens it.
    func apply() {
        guard let repo = Self.repoPath(), !updating else { return }
        updating = true
        let script = "\(repo)/scripts/update.sh"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", "nohup '\(script)' >/dev/null 2>&1 &"]
        try? proc.run()
    }

    nonisolated private static func git(_ repo: String, _ args: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["-C", repo] + args
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch {
            return nil
        }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty == false) ? text : nil
    }
}

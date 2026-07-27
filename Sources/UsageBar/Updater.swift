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
    /// 자동 설치가 예약된 상태 (버스트 코얼레싱/시작 유예로 잠시 미룸).
    @Published var pendingAutoInstall = false
    @Published var lastCheckAt: Date?
    /// update.sh가 남긴 마지막 실행 결과 (알림 권한 없이도 UI에 보이게).
    @Published var lastRun: (state: String, detail: String, commit: String, at: Date)?

    private var loopTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var recheckTask: Task<Void, Never>?
    private var startedAt = Date()

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
        startedAt = Date()
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                // Hourly: a fetch is cheap, and it doubles as the retry path
                // after a failed update (watchdog unsticks `updating`, the
                // next tick re-applies).
                try? await Task.sleep(nanoseconds: 3600 * 1_000_000_000)
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
        let result = await Task.detached(priority: .utility) { () -> (String?, String?, Int) in
            _ = Self.git(repo, ["fetch", "--quiet", "origin", "main"])
            let head = Self.git(repo, ["rev-parse", "--short", "HEAD"])
            let behindCount = Self.git(repo, ["rev-list", "--count", "HEAD..origin/main"])
                .flatMap { Int($0) } ?? 0
            let remote = behindCount > 0
                ? Self.git(repo, ["rev-parse", "--short", "origin/main"]) : nil
            var age = Int.max
            if remote != nil,
               let ct = Self.git(repo, ["log", "-1", "--format=%ct", "origin/main"])
                   .flatMap({ Int($0) }) {
                age = Int(Date().timeIntervalSince1970) - ct
            }
            return (head, remote, age)
        }.value
        currentCommit = result.0
        availableCommit = result.1
        lastCheckAt = Date()
        readLastRun()
        // Hands-free rollout — with two deferrals that keep it from reading
        // as the app misbehaving. (1) Burst coalescing: a commit younger than
        // 5 minutes usually has siblings right behind it, so wait and update
        // once, to the tip. (2) Startup grace: launching straight into an
        // install-restart looks like a crash loop — let the app breathe
        // briefly first. Both show as "곧 자동 설치" in the footer, and the
        // orange button stays live for immediate manual installs.
        if availableCommit != nil, autoUpdate, !updating {
            let freshCommit = result.2 < 300
            let justLaunched = Date().timeIntervalSince(startedAt) < 60
            if freshCommit {
                recheckSoon(after: 360)
            } else if justLaunched {
                recheckSoon(after: 90)
            } else {
                apply()
            }
        } else if availableCommit == nil {
            pendingAutoInstall = false
        }
    }

    /// One pending re-check (burst coalescing / startup grace).
    private func recheckSoon(after seconds: UInt64) {
        pendingAutoInstall = true
        guard recheckTask == nil else { return }
        recheckTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.recheckTask = nil
            await self?.check()
        }
    }

    /// update.sh가 남긴 상태 파일 파싱.
    private func readLastRun() {
        let url = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("UsageBar/update-status.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = obj["state"] as? String else {
            return
        }
        lastRun = (
            state: state,
            detail: obj["detail"] as? String ?? "",
            commit: obj["commit"] as? String ?? "?",
            at: Date(timeIntervalSince1970: (obj["at"] as? Double) ?? 0)
        )
    }

    /// Fire the detached updater. The app keeps running until the script has
    /// built and installed the new bundle; the script then kills and reopens it.
    func apply() {
        guard let repo = Self.repoPath(), !updating else { return }
        updating = true
        pendingAutoInstall = false
        recheckTask?.cancel()
        recheckTask = nil
        let script = "\(repo)/scripts/update.sh"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", "nohup '\(script)' >/dev/null 2>&1 &"]
        try? proc.run()
        // Success means the script kills this instance before the deadline —
        // still being alive past it means the script died somewhere (offline
        // fetch, pull conflict, build error). Unstick the UI and re-arm so
        // the next 6h check can retry instead of blocking on `updating`.
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.updating = false
        }
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

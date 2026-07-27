import Foundation
import SwiftUI

@main
enum Entry {
    static func main() async {
        let args = CommandLine.arguments
        if CLI.shouldRun(args) {
            exit(await CLI.run(args))
        }
        // 터미널에서 인자 없이(또는 오타로) 실행하면 GUI 인스턴스를 하나 더
        // 띄우는 대신 도움말을 보여준다. Finder/launchd 실행은 TTY가 없어
        // 기존대로 GUI로 간다.
        if isatty(fileno(stdout)) != 0 {
            if args.count > 1 { print("알 수 없는 명령: \(args[1])\n") }
            _ = await CLI.run([args[0], "help"])
            exit(args.count > 1 ? 1 : 0)
        }
        UsageBarApp.main()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar app: no Dock icon, no app switcher entry.
        NSApp.setActivationPolicy(.accessory)
        LocalNotifier.requestAuthorizationIfBundled()
        Self.reapZombieUpdaters()
    }

    /// App Nap 시절 얼어붙은 채 남은 과거 업데이트 스크립트 정리 — 뒤늦게
    /// 깨어나 재설치·재시작·"완료" 알림을 반복하는 개체들. 30분 이상 경과한
    /// 것만 죽여서 진행 중인 정상 업데이트는 건드리지 않는다.
    static func reapZombieUpdaters() {
        let cmd = "for pid in $(pgrep -f usagebar-update-staged 2>/dev/null); do "
            + "e=$(ps -o etime= -p $pid 2>/dev/null | tr -d ' ' | "
            + "awk -F'[-:]' '{n=NF; if(n==1){print int($1); next}; s=$n+$(n-1)*60; if(n>=3)s+=$(n-2)*3600; if(n>=4)s+=$(n-3)*86400; print int(s)}'); "
            + "if [ -n \"$e\" ] && [ \"$e\" -gt 1800 ]; then kill -9 $pid 2>/dev/null; fi; done; true"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", cmd]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try? p.run()
    }
}

struct UsageBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var poller: Poller = {
        let p = Poller.shared
        p.start()
        return p
    }()
    @StateObject private var updater: UpdateChecker = {
        let u = UpdateChecker.shared
        u.start()
        return u
    }()

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(poller)
                .environmentObject(updater)
        } label: {
            MenuBarLabel(poller: poller)
        }
        .menuBarExtraStyle(.window)
    }
}

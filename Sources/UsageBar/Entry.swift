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

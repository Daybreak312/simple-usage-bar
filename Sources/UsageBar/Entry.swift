import Foundation
import SwiftUI

@main
enum Entry {
    static func main() async {
        let args = CommandLine.arguments
        if CLI.shouldRun(args) {
            exit(await CLI.run(args))
        }
        UsageBarApp.main()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar app: no Dock icon, no app switcher entry.
        NSApp.setActivationPolicy(.accessory)
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

import AppKit
import Foundation
import UserNotifications

/// macOS 로컬 알림. 번들(.app)로 실행 중이면 UserNotifications 프레임워크,
/// 베어 바이너리(.build/debug 등)면 osascript 폴백 — UNUserNotificationCenter는
/// 번들 없는 프로세스에서 크래시한다.
enum LocalNotifier {
    static var canUseFramework: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Ask once at launch so the permission prompt doesn't wait for the first alert.
    static func requestAuthorizationIfBundled() {
        guard canUseFramework else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func send(title: String, body: String) {
        if canUseFramework {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        } else {
            let escape = { (s: String) in
                s.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
            }
            let script = "display notification \"\(escape(body))\" with title \"\(escape(title))\""
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", script]
            try? proc.run()
        }
    }
}

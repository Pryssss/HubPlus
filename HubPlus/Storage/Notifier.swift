import Foundation
import UserNotifications

/// Local notifications for noteworthy events. All text is app-controlled (never
/// raw transcript/server text), so notifications can't carry injected content.
enum Notifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notify(_ body: String) {
        let content = UNMutableNotificationContent()
        content.title = "Hub+"
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

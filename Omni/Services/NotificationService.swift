import Foundation
import UserNotifications
import AppKit

@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()
    weak var appState: AppState?

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                NSLog("Notification permission error: \(error.localizedDescription)")
            }
        }
    }

    func sendNotification(provider: AIProvider, preview: String) {
        guard appState?.notificationsEnabled == true else { return }

        // If "notify only when hidden", check window visibility
        if appState?.notifyOnlyWhenHidden == true {
            if let window = appState?.mainWindow, window.isVisible, NSApp.isActive {
                return
            }
        }

        let content = UNMutableNotificationContent()
        content.title = "\(provider.displayName) 回复完成"
        content.body = String(preview.prefix(200))
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // Bring window to front when notification is tapped
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        DispatchQueue.main.async {
            if let appDelegate = NSApp.delegate as? AppDelegate {
                appDelegate.toggleWindow()
            }
        }
        completionHandler()
    }

    // Show notification even when app is in foreground
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

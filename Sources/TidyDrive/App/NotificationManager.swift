import Foundation
import UserNotifications
import TidyDriveCore

@MainActor
final class NotificationManager: NSObject {
    static let shared = NotificationManager()

    static let categoryID = "disk-full"
    static let cleanActionID = "clean-up"

    var onCleanUp: (() -> Void)?

    /// UNUserNotificationCenter needs a real app bundle; a bare `swift run`
    /// binary would crash on first use.
    private var available: Bool { Bundle.main.bundleIdentifier != nil }

    func setUp() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let clean = UNNotificationAction(identifier: Self.cleanActionID, title: "Clean up", options: [.foreground])
        let category = UNNotificationCategory(identifier: Self.categoryID, actions: [clean], intentIdentifiers: [])
        center.setNotificationCategories([category])
        // The warning is what TidyDrive is for, so ask right away.
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notifyDiskFull(_ status: DiskStatus, reclaimable: Int64?) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = "Your disk is \(status.usedPercent)% full"
        var body = "\(ByteFormat.string(status.available)) left."
        if let reclaimable, reclaimable > 0 {
            body += " TidyDrive found \(ByteFormat.string(reclaimable)) you can remove."
        }
        content.body = body
        content.sound = .default
        content.categoryIdentifier = Self.categoryID
        let request = UNNotificationRequest(identifier: "disk-full", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        // Both the action button and a click on the banner itself open the review.
        await MainActor.run { NotificationManager.shared.onCleanUp?() }
    }
}

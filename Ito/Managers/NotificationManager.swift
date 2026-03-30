import Foundation
import UserNotifications
import UIKit
import Combine

@MainActor
public class NotificationManager: ObservableObject {
    public static let shared = NotificationManager()

    @Published public private(set) var isAuthorized = false

    private init() {
        Task {
            await checkStatus()
        }
    }

    public func requestPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            self.isAuthorized = granted
            return granted
        } catch {
            print("Failed to request notification permission: \(error)")
            return false
        }
    }

    public func checkStatus() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        self.isAuthorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    /// Dispatch a summary notification for updated library items
    /// Highlights standard HIG patterns for communication
    public func dispatchUpdateSummary(updatedItems: [(LibraryItem, Int)]) async {
        guard isAuthorized else { return }
        guard !updatedItems.isEmpty else { return }

        // Check user settings for notifications
        let showNotifications = UserDefaults.standard.object(forKey: UserDefaultsKeys.updateNotifications) as? Bool ?? true
        guard showNotifications else { return }

        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()

        if updatedItems.count == 1 {
            let item = updatedItems[0].0
            let chapters = updatedItems[0].1
            let typeLabel = item.isAnime ? "episodes" : "chapters"
            content.title = "New Update"
            content.body = "\(item.title) has \(chapters) new \(typeLabel)."
        } else {
            content.title = "Library Updates"
            let itemsString = updatedItems.prefix(2).map { $0.0.title }.joined(separator: ", ")
            content.body = "\(updatedItems.count) titles have new updates, including \(itemsString)"
            content.threadIdentifier = "LibraryUpdates"
        }

        content.sound = .default

        // Use UIApplication to set badge if modifying outside of notifications too,
        // but here we just bundle it with the push notification response.
        let totalUnread = UpdateManager.shared.newChapterCounts.values.reduce(0, +)
        content.badge = NSNumber(value: totalUnread)

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // Deliver immediately
        )

        do {
            try await center.add(request)
        } catch {
            print("Failed to schedule local notification: \(error)")
        }
    }
}

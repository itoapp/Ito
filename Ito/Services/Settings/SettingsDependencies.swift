import Foundation
import UIKit

@MainActor
protocol NotificationAuthorizationRequesting: AnyObject {
    func requestPermission() async -> Bool
}

extension NotificationManager: NotificationAuthorizationRequesting {}

@MainActor
protocol ApplicationSettingsOpening: AnyObject {
    func openApplicationSettings() async -> Bool
}

@MainActor
final class SystemApplicationSettingsOpener: ApplicationSettingsOpening {
    func openApplicationSettings() async -> Bool {
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            return false
        }
        return await withCheckedContinuation { continuation in
            UIApplication.shared.open(url, options: [:]) { opened in
                continuation.resume(returning: opened)
            }
        }
    }
}

@MainActor
protocol SettingsStorageAccessing: AnyObject {
    var currentCacheSizeBytes: Int { get }

    func refreshCacheSize()
    func clearCache()
    func formatBytes(_ bytes: Int) -> String
}

extension StorageManager: SettingsStorageAccessing {}

@MainActor
protocol ClipboardWriting: AnyObject {
    func write(_ text: String) throws
}

@MainActor
final class SystemClipboardWriter: ClipboardWriting {
    func write(_ text: String) throws {
        UIPasteboard.general.string = text
    }
}

enum DebugLogMessage: Equatable {
    case copied
}

@MainActor
protocol DebugLogMessagePresenting: AnyObject {
    func present(_ message: DebugLogMessage)
}

@MainActor
final class AppMessageDebugLogMessagePresenter: DebugLogMessagePresenting {
    private let messageCenter: AppMessageCenter

    init(messageCenter: AppMessageCenter) {
        self.messageCenter = messageCenter
    }

    func present(_ message: DebugLogMessage) {
        switch message {
        case .copied:
            messageCenter.publish(.debugLogsCopied)
        }
    }
}

@MainActor
struct PreparedSettingsDependencies {
    let settingsStore: AppSettingsStore
    let notificationAuthorization: any NotificationAuthorizationRequesting
    let applicationSettingsOpener: any ApplicationSettingsOpening
    let storageAccess: any SettingsStorageAccessing
    let discordRPCManager: DiscordRPCManager
    let logReader: any DebugLogReading
    let clipboardWriter: any ClipboardWriting
}

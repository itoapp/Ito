import Combine
import Foundation

enum AppMessageKind: Equatable {
    case browseUpdateFailed
    case browseDeleteFailed
    case browseDropLoadFailed
    case browseUnsupportedPluginFile
    case browsePluginDirectoryUnavailable
    case browseImportFailed(BrowseImportSource)
    case repositoryAddFailed
    case repositoryRemoveFailed
    case repositoryRefreshFailed
    case repositoryInstallFailed
    case debugLogsCopied
}

struct AppMessage: Identifiable, Equatable {
    let id: UUID
    let kind: AppMessageKind
}

struct AppMessagePresentation: Equatable {
    let style: ToastMessage.Style
    let title: String
    let detail: String?
}

extension AppMessageKind {
    var presentation: AppMessagePresentation {
        switch self {
        case .browseUpdateFailed:
            return .init(
                style: .error,
                title: "Error",
                detail: "Update failed. Please try again."
            )
        case .browseDeleteFailed:
            return .init(
                style: .error,
                title: "Error",
                detail: "Failed to remove plugin. Please try again."
            )
        case .browseDropLoadFailed:
            return .init(
                style: .error,
                title: "Error",
                detail: "Failed to load dropped file."
            )
        case .browseUnsupportedPluginFile:
            return .init(
                style: .error,
                title: "Error",
                detail: "Please drop a valid .ito plugin file."
            )
        case .browsePluginDirectoryUnavailable:
            return .init(
                style: .error,
                title: "Error",
                detail: "Failed to access plugins directory."
            )
        case .browseImportFailed(let source):
            let prefix = source == .drop ? "File copy error" : "URL Open error"
            return .init(
                style: .error,
                title: "Error",
                detail: "\(prefix): The plugin could not be imported."
            )
        case .repositoryAddFailed:
            return .init(
                style: .error,
                title: "Error",
                detail: "Failed to add repository. Please try again."
            )
        case .repositoryRemoveFailed:
            return .init(
                style: .error,
                title: "Error",
                detail: "Failed to remove repository. Please try again."
            )
        case .repositoryRefreshFailed:
            return .init(
                style: .error,
                title: "Error",
                detail: "Some repositories could not be refreshed. Please try again."
            )
        case .repositoryInstallFailed:
            return .init(
                style: .error,
                title: "Error",
                detail: "Failed to install package. Please try again."
            )
        case .debugLogsCopied:
            return .init(
                style: .success,
                title: "Copied to clipboard",
                detail: nil
            )
        }
    }
}

@MainActor
final class AppMessageCenter: ObservableObject {
    @Published private(set) var currentMessage: AppMessage?

    private var queuedMessages: [AppMessage] = []

    @discardableResult
    func publish(_ kind: AppMessageKind) -> UUID {
        let message = AppMessage(id: UUID(), kind: kind)
        if currentMessage == nil {
            currentMessage = message
        } else {
            queuedMessages.append(message)
        }
        return message.id
    }

    func dismiss(messageID: UUID) {
        guard currentMessage?.id == messageID else { return }
        currentMessage = queuedMessages.isEmpty ? nil : queuedMessages.removeFirst()
    }

    var queuedMessageCount: Int {
        queuedMessages.count
    }
}

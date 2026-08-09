import Combine
import Foundation

@MainActor
protocol BrowsePluginManaging: AnyObject {
    var installedPlugins: [String: InstalledPlugin] { get }
    var installedPluginsPublisher: AnyPublisher<[String: InstalledPlugin], Never> { get }

    func reloadInstalledPlugins() async
}

@MainActor
protocol BrowseRepositoryManaging: AnyObject {
    var repositories: [Repository] { get }
    var repositoriesPublisher: AnyPublisher<[Repository], Never> { get }

    func addRepository(url: String) async throws -> RepositoryAdditionResult
    func installPackage(_ package: RepoPackage, repositoryURL: String) async throws
    func refreshAll() async
}

@MainActor
protocol BrowsePluginFileOperating: AnyObject {
    func supportsPluginFile(at url: URL) -> Bool
    func installPluginFile(from url: URL) throws
    func deletePluginFile(at url: URL) throws
}

public enum BrowseImportSource: Equatable {
    case drop
    case openURL
}

enum BrowseMessage: Equatable {
    case updateFailed(reason: String)
    case deleteFailed(pluginName: String, reason: String)
    case dropLoadFailed(reason: String)
    case unsupportedPluginFile
    case pluginDirectoryUnavailable
    case importFailed(source: BrowseImportSource, reason: String)
    case repositoryAddFailed
}

@MainActor
protocol BrowseMessagePresenting: AnyObject {
    func present(_ message: BrowseMessage)
}

extension PluginManager: BrowsePluginManaging {
    var installedPluginsPublisher: AnyPublisher<[String: InstalledPlugin], Never> {
        $installedPlugins.eraseToAnyPublisher()
    }
}

extension RepoManager: BrowseRepositoryManaging {
    var repositoriesPublisher: AnyPublisher<[Repository], Never> {
        $repositories.eraseToAnyPublisher()
    }

    func installPackage(_ package: RepoPackage, repositoryURL: String) async throws {
        try await installPackage(package, repositoryUrl: repositoryURL)
    }
}

enum BrowsePluginFileError: LocalizedError {
    case unsupportedPluginFile
    case pluginsDirectoryUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedPluginFile:
            return "The selected file is not an Ito plugin."
        case .pluginsDirectoryUnavailable:
            return "The plugins directory is unavailable."
        }
    }
}

@MainActor
final class LocalBrowsePluginFileOperations: BrowsePluginFileOperating {
    private let fileManager: FileManager
    private let applicationSupportDirectory: URL?
    let configuredPluginsDirectory: URL?

    init(
        fileManager: FileManager = .default,
        applicationSupportDirectory: URL? = nil,
        pluginsDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        self.applicationSupportDirectory = applicationSupportDirectory
        self.configuredPluginsDirectory = pluginsDirectory
    }

    func supportsPluginFile(at url: URL) -> Bool {
        url.pathExtension.lowercased() == "ito"
    }

    func installPluginFile(from url: URL) throws {
        guard supportsPluginFile(at: url) else {
            throw BrowsePluginFileError.unsupportedPluginFile
        }

        let pluginsDirectory = try pluginsDirectory()
        let destinationURL = pluginsDirectory.appendingPathComponent(url.lastPathComponent)
        let stagingURL = pluginsDirectory.appendingPathComponent(".browse-import-\(UUID().uuidString)")

        defer { try? fileManager.removeItem(at: stagingURL) }
        try fileManager.copyItem(at: url, to: stagingURL)

        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(
                destinationURL,
                withItemAt: stagingURL,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
        }
    }

    func deletePluginFile(at url: URL) throws {
        try fileManager.removeItem(at: url)
    }

    private func pluginsDirectory() throws -> URL {
        if let configuredPluginsDirectory {
            if !fileManager.fileExists(atPath: configuredPluginsDirectory.path) {
                do {
                    try fileManager.createDirectory(
                        at: configuredPluginsDirectory,
                        withIntermediateDirectories: true
                    )
                } catch {
                    throw BrowsePluginFileError.pluginsDirectoryUnavailable
                }
            }
            return configuredPluginsDirectory
        }

        let baseDirectory: URL
        if let applicationSupportDirectory {
            baseDirectory = applicationSupportDirectory
        } else if let directory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            baseDirectory = directory
        } else {
            throw BrowsePluginFileError.pluginsDirectoryUnavailable
        }

        let pluginsDirectory = baseDirectory.appendingPathComponent("Plugins", isDirectory: true)
        if !fileManager.fileExists(atPath: pluginsDirectory.path) {
            do {
                try fileManager.createDirectory(
                    at: pluginsDirectory,
                    withIntermediateDirectories: true
                )
            } catch {
                throw BrowsePluginFileError.pluginsDirectoryUnavailable
            }
        }
        return pluginsDirectory
    }
}

@MainActor
final class AppMessageBrowseMessagePresenter: BrowseMessagePresenting {
    private let messageCenter: AppMessageCenter

    init(messageCenter: AppMessageCenter) {
        self.messageCenter = messageCenter
    }

    func present(_ message: BrowseMessage) {
        messageCenter.publish(message.appMessageKind)
    }
}

private extension BrowseMessage {
    var appMessageKind: AppMessageKind {
        switch self {
        case .updateFailed:
            return .browseUpdateFailed
        case .deleteFailed:
            return .browseDeleteFailed
        case .dropLoadFailed:
            return .browseDropLoadFailed
        case .unsupportedPluginFile:
            return .browseUnsupportedPluginFile
        case .pluginDirectoryUnavailable:
            return .browsePluginDirectoryUnavailable
        case .importFailed(let source, _):
            return .browseImportFailed(source)
        case .repositoryAddFailed:
            return .repositoryAddFailed
        }
    }
}

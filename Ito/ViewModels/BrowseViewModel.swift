import Foundation
import Combine
import SwiftUI
import ito_runner

@MainActor
public class BrowseViewModel: ObservableObject {
    @Published public var errorMessage: String?
    @Published public var showDeleteConfirmation = false
    @Published public var pendingDeleteOffsets: IndexSet?
    @Published public var isInstallingUpdate: String?

    public let pluginManager: PluginManager
    public let repoManager: RepoManager

    public init(repoManager: RepoManager, pluginManager: PluginManager) {
        self.repoManager = repoManager
        self.pluginManager = pluginManager
    }

    public var sortedPlugins: [InstalledPlugin] {
        pluginManager.installedPlugins.values.sorted { $0.info.name < $1.info.name }
    }

    public struct UpdateItem: Identifiable {
        public var id: String { pkg.id }
        public let pkg: RepoPackage
        public let repoUrl: String
        public init(pkg: RepoPackage, repoUrl: String) {
            self.pkg = pkg
            self.repoUrl = repoUrl
        }
    }

    public var availableUpdates: [UpdateItem] {
        var updates: [String: UpdateItem] = [:]
        for repo in repoManager.repositories {
            guard let packages = repo.index?.packages else { continue }
            for pkg in packages {
                if let installed = pluginManager.installedPlugins[pkg.id] {
                    if installed.info.version.compare(pkg.version, options: .numeric) == .orderedAscending {
                        if let existing = updates[pkg.id] {
                            if existing.pkg.version.compare(pkg.version, options: .numeric) == .orderedAscending {
                                updates[pkg.id] = UpdateItem(pkg: pkg, repoUrl: repo.url)
                            }
                        } else {
                            updates[pkg.id] = UpdateItem(pkg: pkg, repoUrl: repo.url)
                        }
                    }
                }
            }
        }
        return Array(updates.values).sorted { $0.pkg.name < $1.pkg.name }
    }

    public func installUpdate(_ updateItem: UpdateItem) async {
        isInstallingUpdate = updateItem.id
        defer { isInstallingUpdate = nil }
        do {
            try await repoManager.installPackage(updateItem.pkg, repositoryUrl: updateItem.repoUrl)
        } catch {
            errorMessage = "Update failed: \(error.localizedDescription)"
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if errorMessage?.hasPrefix("Update failed") == true {
                errorMessage = nil
            }
        }
    }

    public func performDelete(at offsets: IndexSet) async {
        let toDelete = offsets.map { sortedPlugins[$0] }
        let fileManager = FileManager.default

        for plugin in toDelete {
            do {
                try fileManager.removeItem(at: plugin.url)
            } catch {
                errorMessage = "Failed to remove \(plugin.info.name): \(error.localizedDescription)"
            }
        }
        await pluginManager.reloadInstalledPlugins()
    }
}

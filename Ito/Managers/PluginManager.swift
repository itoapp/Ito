import OSLog
import Foundation
import Combine
import ito_runner

public struct InstalledPlugin: Identifiable {
    public var id: String { info.id }
    public let url: URL
    public let info: PluginInfo
    public let iconData: Data?
}

/// Manages the state of installed plugins to provide fast, synchronous O(1) lookups
/// for the UI (like RepositoriesView) without blocking the main thread parsing ZIP files.
public class PluginManager: ObservableObject {
    // Key: Plugin ID (e.g., moe.itoapp.ito.hianime)
    // Value: The parsed manifest info for that plugin
    @Published public private(set) var installedPlugins: [String: InstalledPlugin] = [:]

    // Cache for loaded WASM runners
    private var runnerCache: [String: ItoRunner] = [:]
    private let pluginsDirectory: URL?
    public let pluginSettingsStore: PluginSettingsStore

    var configuredInstalledPluginsDirectory: URL? {
        pluginsDirectory
    }

    public init(pluginSettingsStore: PluginSettingsStore, pluginsDirectory: URL? = nil) {
        self.pluginSettingsStore = pluginSettingsStore
        self.pluginsDirectory = pluginsDirectory
    }

    /// Gets a cached ItoRunner for a plugin ID, or initializes a new one if not cached.
    @MainActor
    public func getRunner(for pluginId: String) async throws -> ItoRunner {
        guard let plugin = installedPlugins[pluginId] else {
            AppLogger.plugin.debug("🔌 [PluginManager] Plugin not found: \(pluginId)")
            throw URLError(.fileDoesNotExist) // Plugin not installed
        }

        try pluginSettingsStore.prepare(pluginId: pluginId)
        if let cached = runnerCache[pluginId] {
            AppLogger.plugin.debug("🔌 [PluginManager] Returning cached runner for \(pluginId)")
            return cached
        }

        AppLogger.plugin.debug("\("🔌 [PluginManager] Creating new runner for \(pluginId)")...")
        let runner = ItoRunner()
        await runner.setNetModule(AppNetModule())
        await runner.setStdModule(DefaultStdModule())
        await runner.setDefaultsModule(AppDefaultsModule(pluginId: pluginId, store: pluginSettingsStore))
        await runner.setHtmlModule(DefaultHtmlModule())
        await runner.setJsModule(DefaultJsModule())
        await runner.setWebviewModule(AppWebviewModule())

        AppLogger.plugin.debug("\("🔌 [PluginManager] Loading bundle for \(pluginId)")...")
        _ = try await runner.loadBundle(from: plugin.url)

        runnerCache[pluginId] = runner
        AppLogger.plugin.debug("🔌 [PluginManager] Runner cached for \(pluginId)")
        return runner
    }

    /// Evicts a cached runner for a plugin so the next getRunner call creates a fresh one.
    /// Use this after settings changes that require the WASM module to be reloaded.
    @MainActor
    public func evictRunner(for pluginId: String) {
        if runnerCache.removeValue(forKey: pluginId) != nil {
            AppLogger.plugin.debug("🔌 [PluginManager] Evicted cached runner for \(pluginId)")
        }
    }

    /// Scans the Application Support/Plugins directory and parses all manifests.
    @MainActor
    public func reloadInstalledPlugins() async {
        do {
            try await discoverAndPrepareInstalledPlugins(failOnInvalidPlugin: false)
        } catch {
            AppLogger.plugin.error("Failed to load installed plugins: \(error)")
        }
    }

    /// Performs strict readiness discovery, registers every installed manifest/file
    /// identity, and verifies all registered suites before publishing the cache.
    @MainActor
    public func discoverAndPrepareInstalledPlugins() async throws {
        try await discoverAndPrepareInstalledPlugins(failOnInvalidPlugin: true)
    }

    /// Performs discovery with explicit invalid-file handling.
    @MainActor
    public func discoverAndPrepareInstalledPlugins(
        failOnInvalidPlugin: Bool
    ) async throws {
        let scan = try scanInstalledPlugins(failOnInvalidPlugin: failOnInvalidPlugin)
        try pluginSettingsStore.prepareForDurableSnapshot(scan.discoveries)
        publishInstalledPlugins(scan.plugins)
    }

    /// Restore-only scan. This reads bundle metadata and republishes the in-memory
    /// cache without registering identities, migrating suites, or creating runners.
    @MainActor
    public func reloadAfterRestore() async throws {
        let scan = try scanInstalledPlugins(failOnInvalidPlugin: true)
        publishInstalledPlugins(scan.plugins)
    }

    @MainActor
    private func scanInstalledPlugins(
        failOnInvalidPlugin: Bool
    ) throws -> (
        plugins: [String: InstalledPlugin],
        discoveries: [PluginSettingsDiscovery]
    ) {
        let fileManager = FileManager.default
        let pluginsDir: URL
        if let pluginsDirectory {
            pluginsDir = pluginsDirectory
        } else {
            guard let appSupportDir = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                throw URLError(.cannotFindHost)
            }
            pluginsDir = appSupportDir.appendingPathComponent("Plugins")
        }

        guard fileManager.fileExists(atPath: pluginsDir.path) else {
            return ([:], [])
        }

        let files = try fileManager.contentsOfDirectory(
            at: pluginsDir,
            includingPropertiesForKeys: nil
        )
        let itoFiles = files.filter { $0.pathExtension == "ito" }

        var newCache: [String: InstalledPlugin] = [:]
        var discoveries: [PluginSettingsDiscovery] = []

        // We use static extraction to avoid loading WASM into memory just to read metadata
        for url in itoFiles {
            do {
                let extracted = try ItoRunner.extractPluginInfo(from: url)
                let filenameId = url.deletingPathExtension().lastPathComponent
                discoveries.append(
                    PluginSettingsDiscovery(
                        pluginId: extracted.manifest.info.id,
                        manifestId: extracted.manifest.info.id,
                        filenameId: filenameId,
                        source: "installedFileScan"
                    )
                )
                newCache[extracted.manifest.info.id] = InstalledPlugin(
                    url: url,
                    info: extracted.manifest.info,
                    iconData: extracted.icon
                )
            } catch {
                if failOnInvalidPlugin {
                    throw error
                }
                AppLogger.plugin.error(
                    "Failed to extract plugin info for \(url.lastPathComponent): \(error)"
                )
            }
        }

        return (newCache, discoveries)
    }

    @MainActor
    private func publishInstalledPlugins(_ newCache: [String: InstalledPlugin]) {
        installedPlugins = newCache

        // Evict any cached runners whose plugin was removed or updated,
        // so the next getRunner call loads the fresh WASM binary.
        let validIds = Set(newCache.keys)
        for cachedId in runnerCache.keys {
            if !validIds.contains(cachedId) {
                runnerCache.removeValue(forKey: cachedId)
                AppLogger.plugin.debug(
                    "🔌 [PluginManager] Evicted removed plugin runner: \(cachedId)"
                )
            }
        }
        // Also evict ALL runners to pick up updated .ito files
        runnerCache.removeAll()
        AppLogger.plugin.debug(
            "🔌 [PluginManager] Cleared runner cache (\(newCache.count) plugins loaded)"
        )
    }
}

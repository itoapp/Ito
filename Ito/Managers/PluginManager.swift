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
    public static let shared = PluginManager()
    
    // Key: Plugin ID (e.g., com.kunihir0.ito.hianime)
    // Value: The parsed manifest info for that plugin
    @Published public private(set) var installedPlugins: [String: InstalledPlugin] = [:]
    
    // Cache for loaded WASM runners
    private var runnerCache: [String: ItoRunner] = [:]
    
    private init() {
        Task {
            await reloadInstalledPlugins()
        }
    }
    
    /// Gets a cached ItoRunner for a plugin ID, or initializes a new one if not cached.
    @MainActor
    public func getRunner(for pluginId: String) async throws -> ItoRunner {
        if let cached = runnerCache[pluginId] {
            return cached
        }
        
        guard let plugin = installedPlugins[pluginId] else {
            throw URLError(.fileDoesNotExist) // Plugin not installed
        }
        
        let runner = ItoRunner()
        await runner.setNetModule(AppNetModule())
        await runner.setStdModule(DefaultStdModule())
        await runner.setDefaultsModule(DefaultDefaultsModule(pluginId: pluginId))
        await runner.setHtmlModule(DefaultHtmlModule())
        await runner.setJsModule(DefaultJsModule())
        
        _ = try await runner.loadBundle(from: plugin.url)
        
        runnerCache[pluginId] = runner
        return runner
    }
    
    /// Scans the Application Support/Plugins directory and parses all manifests.
    @MainActor
    public func reloadInstalledPlugins() async {
        let fileManager = FileManager.default
        guard let appSupportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let pluginsDir = appSupportDir.appendingPathComponent("Plugins")
        
        guard fileManager.fileExists(atPath: pluginsDir.path) else {
            self.installedPlugins = [:]
            return
        }
        
        do {
            let files = try fileManager.contentsOfDirectory(at: pluginsDir, includingPropertiesForKeys: nil)
            let itoFiles = files.filter { $0.pathExtension == "ito" }
            
            var newCache: [String: InstalledPlugin] = [:]
            
            // We use static extraction to avoid loading WASM into memory just to read metadata
            for url in itoFiles {
                do {
                    let extracted = try ItoRunner.extractPluginInfo(from: url)
                    newCache[extracted.manifest.info.id] = InstalledPlugin(url: url, info: extracted.manifest.info, iconData: extracted.icon)
                } catch {
                    print("Failed to extract plugin info for \(url.lastPathComponent): \(error)")
                }
            }
            
            self.installedPlugins = newCache
            
        } catch {
            print("Failed to load installed plugins: \(error)")
        }
    }
}

import Foundation
import Combine
import CryptoKit
import GRDB

public struct RepoPackage: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let version: String
    public let minAppVersion: String
    public let downloadUrl: String
    public let iconUrl: String?
    public let sha256: String
    public let pluginType: String

    enum CodingKeys: String, CodingKey {
        case id, name, version, minAppVersion = "min_app_version"
        case downloadUrl = "download_url"
        case iconUrl = "icon_url"
        case sha256
        case pluginType = "type"
    }
}

public struct RepoIndex: Codable, Equatable, Sendable {
    public let repoName: String
    public let repoUrl: String
    public let description: String
    public let packages: [RepoPackage]

    enum CodingKeys: String, CodingKey {
        case repoName = "repo_name"
        case repoUrl = "repo_url"
        case description, packages
    }
}

public struct Repository: Codable, Identifiable, Equatable, Sendable {
    public var id: String { url }
    public let url: String
    public var lastFetched: Date?
    public var index: RepoIndex?
}

@MainActor
public class RepoManager: ObservableObject {
    public static let shared = RepoManager()

    @Published public private(set) var repositories: [Repository] = []
    private let defaultsKey = "ito_repositories"

    // The current app version for compatibility checks
    public let currentAppVersion = "1.0.0"

    private init() {
        loadRepos()
    }

    private func loadRepos() {
        // ALWAYS prioritize SQLite store to enable robust cross-device backups
        do {
            let dbPool = AppDatabase.shared.dbPool
            if let pref = try dbPool.read({ db in
                try AppPreference.fetchOne(db, key: defaultsKey)
            }), let decoded = try? JSONDecoder().decode([Repository].self, from: pref.value) {
                print("🌍 [DEBUG-REPO] Loaded Repositories from Database AppPreference.")
                self.repositories = decoded
                return
            }
        } catch {
            print("🌍 [DEBUG-REPO] Failed to parse SQLite repos: \(error)")
        }

        // Legacy fallback
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([Repository].self, from: data) {
            self.repositories = decoded
            print("🌍 [DEBUG-REPO] Loaded Repositories from Legacy UserDefaults. Migrating to SQLite...")
            self.saveRepos() // Propagate to SQLite immediately
        }
    }

    private func saveRepos() {
        if let encoded = try? JSONEncoder().encode(repositories) {
            do {
                let dbPool = AppDatabase.shared.dbPool
                try dbPool.write { db in
                    try AppPreference(key: defaultsKey, value: encoded).save(db)
                }
                print("🌍 [DEBUG-REPO] Maintained single source of truth for repos via SQLite.")
            } catch {
                print("🌍 [DEBUG-REPO] Fatal SQLite Save error: \(error)")
            }
        }
    }

    public func addRepository(url: String) async throws {
        // Normalize: strip trailing /index.json so the base URL is always stored
        var normalizedUrl = url
        if normalizedUrl.hasSuffix("/index.json") {
            normalizedUrl = String(normalizedUrl.dropLast("/index.json".count))
        }
        print("🌍 [DEBUG-REPO] Attempting to add repository: \(normalizedUrl)")

        // Prevent duplicates
        guard !repositories.contains(where: { $0.url == normalizedUrl }) else {
            print("🌍 [DEBUG-REPO] Repository already exists: \(normalizedUrl)")
            return
        }

        var repo = Repository(url: normalizedUrl)
        do {
            let fetchedIndex = try await fetchIndex(for: url)
            repo.index = fetchedIndex
            repo.lastFetched = Date()

            self.repositories.append(repo)
            self.saveRepos()
            print("🌍 [DEBUG-REPO] Successfully added repository: \(fetchedIndex.repoName)")
        } catch {
            print("🌍 [DEBUG-REPO] Failed to add repository: \(error)")
            throw error
        }
    }

    public func removeRepository(url: String) {
        print("🌍 [DEBUG-REPO] Removing repository: \(url)")
        repositories.removeAll { $0.url == url }
        saveRepos()
    }

    public func refreshAll() async {
        print("🌍 [DEBUG-REPO] Refreshing all repositories...")
        for (index, repo) in repositories.enumerated() {
            do {
                let newIndex = try await fetchIndex(for: repo.url)
                self.repositories[index].index = newIndex
                self.repositories[index].lastFetched = Date()
                self.saveRepos()
                print("🌍 [DEBUG-REPO] Refreshed: \(newIndex.repoName)")
            } catch {
                print("🌍 [DEBUG-REPO] Failed to refresh \(repo.url): \(error)")
            }
        }
    }

    private func fetchIndex(for urlStr: String) async throws -> RepoIndex {
        print("🌍 [DEBUG-REPO] Fetching index for \(urlStr)")
        guard let url = URL(string: urlStr) else {
            print("🌍 [DEBUG-REPO] Invalid URL format: \(urlStr)")
            throw URLError(.badURL)
        }
        let indexUrl = url.lastPathComponent == "index.json" ? url : url.appendingPathComponent("index.json")
        print("🌍 [DEBUG-REPO] Downloading from: \(indexUrl.absoluteString)")

        var request = URLRequest(url: indexUrl)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse {
            print("🌍 [DEBUG-REPO] HTTP Status Code: \(httpResponse.statusCode)")
            if !(200...299).contains(httpResponse.statusCode) {
                print("🌍 [DEBUG-REPO] Server returned error status: \(httpResponse.statusCode)")
                throw URLError(URLError.Code(rawValue: httpResponse.statusCode))
            }
        }

        do {
            let decoded = try JSONDecoder().decode(RepoIndex.self, from: data)
            print("🌍 [DEBUG-REPO] Successfully decoded RepoIndex: \(decoded.repoName) with \(decoded.packages.count) packages")
            return decoded
        } catch {
            print("🌍 [DEBUG-REPO] JSON Decoding error: \(error)")
            if let rawString = String(data: data, encoding: .utf8) {
                print("🌍 [DEBUG-REPO] Raw response data (first 500 chars):\n\(String(rawString.prefix(500)))")
            }
            throw error
        }
    }

    // Checks if the plugin is compatible with this app
    public func isCompatible(minAppVersion: String) -> Bool {
        return currentAppVersion.compare(minAppVersion, options: .numeric) != .orderedAscending
    }

    public enum PluginStatus {
        case notInstalled
        case installed
        case updateAvailable(installedVersion: String)
    }

    public func getPluginStatus(id: String, repoVersion: String) -> PluginStatus {
        let fileManager = FileManager.default
        guard let appSupportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return .notInstalled
        }
        let pluginsDir = appSupportDir.appendingPathComponent("Plugins")
        let pluginURL = pluginsDir.appendingPathComponent("\(id).ito")

        guard fileManager.fileExists(atPath: pluginURL.path) else {
            return .notInstalled
        }

        // A full implementation would parse the manifest.json inside the .ito zip here.
        // Since we are mocking the zip extraction for brevity in this method, 
        // we'll assume it's installed. To check versions, we'd need ItoRunner to load the bundle.
        // For a seamless UI without massive overhead per row, we can just return `.installed` 
        // and rely on a cached dictionary of installed plugins updated by BrowseView, 
        // OR we can read the version if we had a lightweight way.
        // Let's assume installed for now, but mark the architectural need for a shared PluginManager.

        // Mock version comparison:
        // if installedVersion < repoVersion { return .updateAvailable(...) }

        return .installed
    }

    public func installPackage(_ pkg: RepoPackage, repositoryUrl: String) async throws {
        guard let url = URL(string: "\(repositoryUrl)/\(pkg.downloadUrl)") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            print("Server returned \(httpResponse.statusCode) for \(url)")
            throw URLError(.fileDoesNotExist)
        }

        // Verify Hash
        let digest = SHA256.hash(data: data)
        let computedHash = digest.compactMap { String(format: "%02x", $0) }.joined()

        guard computedHash.lowercased() == pkg.sha256.lowercased() else {
            print("Hash mismatch! Expected \(pkg.sha256), got \(computedHash)")
            throw URLError(.cannotDecodeRawData) // Or a custom error
        }

        // Save to Application Support/Plugins
        let fileManager = FileManager.default
        guard let appSupportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw URLError(.cannotCreateFile)
        }
        let pluginsDir = appSupportDir.appendingPathComponent("Plugins")

        if !fileManager.fileExists(atPath: pluginsDir.path) {
            try fileManager.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        }

        let destUrl = pluginsDir.appendingPathComponent("\(pkg.id).ito")
        try data.write(to: destUrl)

        print("Successfully installed \(pkg.name)")

        // Tell the cache to reload
        await PluginManager.shared.reloadInstalledPlugins()
    }
}

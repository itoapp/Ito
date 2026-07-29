import OSLog
import Foundation
import Combine
import CryptoKit
import GRDB

nonisolated public struct RepoPackage: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let version: String
    public let minAppVersion: String
    public let downloadUrl: String
    public let iconUrl: String?
    public let sha256: String
    public let pluginType: String
    public let archived: Bool?
    public let archivedReason: String?
    public let archivedDate: String?

    enum CodingKeys: String, CodingKey {
        case id, name, version, minAppVersion = "min_app_version"
        case downloadUrl = "download_url"
        case iconUrl = "icon_url"
        case sha256
        case pluginType = "type"
        case archived
        case archivedReason = "archived_reason"
        case archivedDate = "archived_date"
    }
}

extension RepoPackage {
    public var isArchived: Bool { archived ?? false }
}

nonisolated public struct RepoIndex: Codable, Equatable, Sendable {
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

nonisolated public struct Repository: Codable, Identifiable, Equatable, Sendable {
    public var id: String { url }
    public let url: String
    public var lastFetched: Date?
    public var index: RepoIndex?
}

@MainActor
public class RepoManager: ObservableObject {
    @Published public private(set) var repositories: [Repository] = []
    private let dbPool: DatabasePool
    private let pluginManager: PluginManager?
    private let indexFetcher: @Sendable (URL) async throws -> Data

    // The current app version for compatibility checks
    public let currentAppVersion = "1.0.0"

    public init(
        dbPool: DatabasePool,
        pluginManager: PluginManager? = nil,
        indexFetcher: @escaping @Sendable (URL) async throws -> Data = { url in
            let (data, response) = try await URLSession.shared.data(from: url)
            if let response = response as? HTTPURLResponse,
               !(200...299).contains(response.statusCode) {
                throw URLError(URLError.Code(rawValue: response.statusCode))
            }
            return data
        }
    ) {
        self.dbPool = dbPool
        self.pluginManager = pluginManager
        self.indexFetcher = indexFetcher
    }

    public func reload() async throws {
        repositories = try await dbPool.read { db in
            try RepositoryRecord.order(Column("url")).fetchAll(db).map { record in
                Repository(
                    url: record.url,
                    lastFetched: record.lastFetched,
                    index: try record.indexPayload.map { try JSONDecoder().decode(RepoIndex.self, from: $0) }
                )
            }
        }
    }

    private func normalizedURL(_ rawURL: String) throws -> String {
        guard var components = URLComponents(string: rawURL) else {
            throw URLError(.badURL)
        }
        if components.path.hasSuffix("/index.json") {
            components.path.removeLast("/index.json".count)
        }
        while components.path.count > 1 && components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        guard let normalized = components.url?.absoluteString else {
            throw URLError(.badURL)
        }
        return normalized
    }

    public func addRepository(url: String) async throws {
        let normalizedUrl = try normalizedURL(url)
        AppLogger.database.debug("🌍 [DEBUG-REPO] Attempting to add repository: \(normalizedUrl)")

        // Prevent duplicates
        guard !repositories.contains(where: { $0.url == normalizedUrl }) else {
            AppLogger.database.debug("🌍 [DEBUG-REPO] Repository already exists: \(normalizedUrl)")
            return
        }

        var repo = Repository(url: normalizedUrl)
        do {
            let fetchedIndex = try await fetchIndex(for: normalizedUrl)
            repo.index = fetchedIndex
            repo.lastFetched = Date()

            let record = RepositoryRecord(
                url: repo.url,
                lastFetched: repo.lastFetched,
                indexPayload: try JSONEncoder().encode(fetchedIndex)
            )
            try await dbPool.write { db in try record.insert(db) }
            repositories.append(repo)
            repositories.sort { $0.url < $1.url }
            AppLogger.database.debug("🌍 [DEBUG-REPO] Successfully added repository: \(fetchedIndex.repoName)")
        } catch {
            AppLogger.database.error("🌍 [DEBUG-REPO] Failed to add repository: \(error)")
            throw error
        }
    }

    public func removeRepository(url: String) async throws {
        let normalized = try normalizedURL(url)
        AppLogger.database.debug("🌍 [DEBUG-REPO] Removing repository: \(normalized)")
        _ = try await dbPool.write { db in
            try RepositoryRecord.deleteOne(db, key: normalized)
        }
        repositories.removeAll { $0.url == normalized }
    }

    public func refreshAll() async {
        AppLogger.database.debug("🌍 [DEBUG-REPO] Refreshing all repositories...")
        for repo in repositories {
            do {
                let newIndex = try await fetchIndex(for: repo.url)
                let fetchedAt = Date()
                let record = RepositoryRecord(
                    url: repo.url,
                    lastFetched: fetchedAt,
                    indexPayload: try JSONEncoder().encode(newIndex)
                )
                try await dbPool.write { db in try record.save(db) }
                if let index = repositories.firstIndex(where: { $0.url == repo.url }) {
                    repositories[index].index = newIndex
                    repositories[index].lastFetched = fetchedAt
                }
                AppLogger.database.debug("🌍 [DEBUG-REPO] Refreshed: \(newIndex.repoName)")
            } catch {
                AppLogger.database.error("\("🌍 [DEBUG-REPO] Failed to refresh \(repo.url)"): \(error)")
            }
        }
    }

    private func fetchIndex(for urlStr: String) async throws -> RepoIndex {
        AppLogger.database.debug("🌍 [DEBUG-REPO] Fetching index for \(urlStr)")
        guard let url = URL(string: urlStr) else {
            AppLogger.database.debug("🌍 [DEBUG-REPO] Invalid URL format: \(urlStr)")
            throw URLError(.badURL)
        }
        let indexUrl = url.lastPathComponent == "index.json" ? url : url.appendingPathComponent("index.json")
        AppLogger.database.debug("🌍 [DEBUG-REPO] Downloading from: \(indexUrl.absoluteString)")

        let data = try await indexFetcher(indexUrl)

        do {
            let decoded = try JSONDecoder().decode(RepoIndex.self, from: data)
            AppLogger.database.debug("\("🌍 [DEBUG-REPO] Successfully decoded RepoIndex: \(decoded.repoName)") with \(decoded.packages.count) packages")
            return decoded
        } catch {
            AppLogger.database.error("🌍 [DEBUG-REPO] JSON Decoding error: \(error)")
            if let rawString = String(data: data, encoding: .utf8) {
                AppLogger.database.debug("\("🌍 [DEBUG-REPO] Raw response data (first 500 chars)"):\n\(String(rawString.prefix(500)))")
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
            AppLogger.database.debug("\("Server returned \(httpResponse.statusCode)") for \(url)")
            throw URLError(.fileDoesNotExist)
        }

        // Verify Hash
        let digest = SHA256.hash(data: data)
        let computedHash = digest.compactMap { String(format: "%02x", $0) }.joined()

        guard computedHash.lowercased() == pkg.sha256.lowercased() else {
            AppLogger.database.debug("\("Hash mismatch! Expected \(pkg.sha256)"), got \(computedHash)")
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

        AppLogger.database.debug("Successfully installed \(pkg.name)")

        // Tell the cache to reload
        await pluginManager?.reloadInstalledPlugins()
    }
}

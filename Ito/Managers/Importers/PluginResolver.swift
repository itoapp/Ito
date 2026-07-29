import Combine
import Foundation
import GRDB

public struct PluginResolution: Sendable {
    public let resolvedId: String
    public let confidence: Int
    public let isInstalled: Bool
    public let foreignId: String
    public let candidates: [(id: String, score: Int)]

    public var needsAttention: Bool {
        confidence < 45 || !isInstalled
    }
}

@MainActor
public final class PluginResolver: ObservableObject {
    private static let builtInAliases = [
        "mangasee": "mangasee123",
        "manganato": "manganato",
        "bato": "bato",
        "comick": "comick",
        "mangadex": "mangadex"
    ]

    private let dbPool: DatabasePool
    private let repoManager: RepoManager
    private let installedPluginIds: () -> Set<String>
    private var userAliases: [String: String] = [:]

    init(
        dbPool: DatabasePool,
        repoManager: RepoManager,
        installedPluginIds: @escaping () -> Set<String>
    ) {
        self.dbPool = dbPool
        self.repoManager = repoManager
        self.installedPluginIds = installedPluginIds
    }

    public func reload() async throws {
        let records = try await dbPool.read { db in
            try PluginMigrationAliasRecord.fetchAll(db)
        }
        userAliases = Dictionary(uniqueKeysWithValues: records.map { ($0.foreignId, $0.pluginId) })
    }

    public func saveUserAlias(foreignId: String, itoPluginId: String) async throws {
        let key = Self.cleanedBase(foreignId)
        let record = PluginMigrationAliasRecord(
            foreignId: key,
            pluginId: itoPluginId,
            updatedAt: Date()
        )
        try await dbPool.write { db in try record.save(db) }
        userAliases[key] = itoPluginId
    }

    public func resolve(foreignId: String) -> PluginResolution {
        let components = foreignId.split(separator: ".")
        let langTag = components.count > 1 ? String(components[0]).lowercased() : nil
        let cleanedBase = Self.cleanedBase(foreignId)
        let aliases = Self.builtInAliases.merging(userAliases) { _, user in user }
        let targetName = aliases[cleanedBase] ?? cleanedBase
        let installed = installedPluginIds()

        if let directAlias = userAliases[cleanedBase], directAlias.contains(".") {
            return PluginResolution(
                resolvedId: directAlias,
                confidence: 100,
                isInstalled: installed.contains(directAlias),
                foreignId: foreignId,
                candidates: []
            )
        }

        var scoredCandidates: [(id: String, score: Int)] = []
        for package in repoManager.repositories.flatMap({ $0.index?.packages ?? [] }) {
            var score = 0
            let packageId = package.id.lowercased()
            let packageName = package.name.lowercased()
            if packageId.hasSuffix(".\(targetName)") { score += 50 }
            if packageName == targetName {
                score += 40
            } else if packageId.contains(targetName) {
                score += 10
            }
            if let langTag, langTag != "all", langTag != "any",
               packageId.hasSuffix(".\(langTag)") || packageId.contains(".\(langTag).") {
                score += 30
            }
            if score > 0 {
                scoredCandidates.append((package.id, score))
            }
        }
        scoredCandidates.sort { $0.score > $1.score }
        let candidates = Array(scoredCandidates.prefix(3))
        if let best = candidates.first {
            return PluginResolution(
                resolvedId: best.id,
                confidence: best.score,
                isInstalled: installed.contains(best.id),
                foreignId: foreignId,
                candidates: candidates
            )
        }

        let fallbackId = "moe.itoapp.ito.\(targetName)"
        return PluginResolution(
            resolvedId: fallbackId,
            confidence: 0,
            isInstalled: installed.contains(fallbackId),
            foreignId: foreignId,
            candidates: []
        )
    }

    public func resolveId(foreignId: String) -> String {
        resolve(foreignId: foreignId).resolvedId
    }

    private static func cleanedBase(_ foreignId: String) -> String {
        let components = foreignId.split(separator: ".")
        let base = components.last.map(String.init) ?? foreignId
        return base
            .replacingOccurrences(of: "-v[0-9]+", with: "", options: .regularExpression)
            .lowercased()
    }
}

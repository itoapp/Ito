import Foundation

// MARK: - Resolution Result

public struct PluginResolution: Sendable {
    public let resolvedId: String
    public let confidence: Int            // 0–100
    public let isInstalled: Bool
    public let foreignId: String
    public let candidates: [(id: String, score: Int)]

    /// Convenience: true when confidence is below the threshold and the plugin isn't installed
    public var needsAttention: Bool {
        return confidence < 45 || !isInstalled
    }
}

// Make the tuple Sendable-safe by wrapping it
extension PluginResolution {
    public struct Candidate: Sendable {
        public let id: String
        public let score: Int
    }
}

// MARK: - PluginResolver

@MainActor
public class PluginResolver {
    public static let shared = PluginResolver()

    // Static aliases for known cross-app renames
    private var migrationAliases: [String: String] = [
        "mangasee": "mangasee123",
        "manganato": "manganato",
        "bato": "bato",
        "comick": "comick",
        "mangadex": "mangadex"
    ]

    // Persisted user-defined remaps that survive across imports
    private let userAliasesKey = "ito_user_migration_aliases"

    private init() {
        loadUserAliases()
    }

    // MARK: - Persistence

    private func loadUserAliases() {
        if let saved = UserDefaults.standard.dictionary(forKey: userAliasesKey) as? [String: String] {
            for (key, value) in saved {
                migrationAliases[key] = value
            }
        }
    }

    /// Saves a user-defined remap so future imports auto-resolve
    public func saveUserAlias(foreignId: String, itoPluginId: String) {
        let components = foreignId.split(separator: ".")
        let baseNameRaw = components.count > 1 ? String(components.last!) : foreignId
        let cleanedBase = baseNameRaw
            .replacingOccurrences(of: "-v[0-9]+", with: "", options: .regularExpression)
            .lowercased()

        migrationAliases[cleanedBase] = itoPluginId

        // Persist only user-added aliases
        var userAliases = UserDefaults.standard.dictionary(forKey: userAliasesKey) as? [String: String] ?? [:]
        userAliases[cleanedBase] = itoPluginId
        UserDefaults.standard.set(userAliases, forKey: userAliasesKey)
    }

    // MARK: - Resolution

    /// Full resolution returning metadata for the migration report
    public func resolve(foreignId: String) -> PluginResolution {
        let components = foreignId.split(separator: ".")
        var langTag: String?
        var baseNameRaw = foreignId

        if components.count > 1 {
            langTag = String(components.first!).lowercased()
            baseNameRaw = String(components.last!)
        } else if components.count == 1 {
            baseNameRaw = String(components.first!)
        }

        let cleanedBase = baseNameRaw
            .replacingOccurrences(of: "-v[0-9]+", with: "", options: .regularExpression)
            .lowercased()

        let targetName = migrationAliases[cleanedBase] ?? cleanedBase

        // Check if user alias pointed directly to a full plugin ID (from manual remap)
        if let directAlias = migrationAliases[cleanedBase], directAlias.contains(".") {
            let installed = PluginManager.shared.installedPlugins[directAlias] != nil
            return PluginResolution(
                resolvedId: directAlias,
                confidence: 100,
                isInstalled: installed,
                foreignId: foreignId,
                candidates: []
            )
        }

        // Confidence Scoring Engine
        var scoredCandidates: [(id: String, score: Int)] = []

        for repo in RepoManager.shared.repositories {
            guard let packages = repo.index?.packages else { continue }

            for package in packages {
                var score = 0
                let pkgId = package.id.lowercased()
                let pkgName = package.name.lowercased()

                // Exact suffix match
                if pkgId.hasSuffix(".\(targetName)") {
                    score += 50
                }

                // Name equivalency
                if pkgName == targetName {
                    score += 40
                } else if pkgId.contains(targetName) {
                    score += 10
                }

                // Language harmony
                if let tag = langTag, tag != "all" && tag != "any" {
                    if pkgId.hasSuffix(".\(tag)") || pkgId.contains(".\(tag).") {
                        score += 30
                    } else if pkgName.contains("(\(tag))") || pkgName.contains("[\(tag)]") || pkgName.contains("-\(tag)") {
                        score += 30
                    }
                }

                if score > 0 {
                    scoredCandidates.append((id: package.id, score: score))
                }
            }
        }

        // Sort by score descending, take top 3
        scoredCandidates.sort { $0.score > $1.score }
        let topCandidates = Array(scoredCandidates.prefix(3))

        if let best = topCandidates.first {
            let installed = PluginManager.shared.installedPlugins[best.id] != nil
            return PluginResolution(
                resolvedId: best.id,
                confidence: best.score,
                isInstalled: installed,
                foreignId: foreignId,
                candidates: topCandidates
            )
        }

        // No match at all — fabricate fallback
        let fallbackId = "moe.itoapp.ito.\(targetName)"
        return PluginResolution(
            resolvedId: fallbackId,
            confidence: 0,
            isInstalled: false,
            foreignId: foreignId,
            candidates: []
        )
    }

    /// Convenience: returns just the resolved ID string (for callers that don't need metadata)
    public func resolveId(foreignId: String) -> String {
        return resolve(foreignId: foreignId).resolvedId
    }
}

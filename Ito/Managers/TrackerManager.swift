import Foundation
import Combine

@MainActor
public class TrackerManager: ObservableObject {
    public static let shared = TrackerManager()

    // Instead of [String: Int], we now map [LocalId: [TrackerIdentifier: String]]
    @Published public private(set) var trackerMappings: [String: [String: String]] = [:]

    public let providers: [any TrackerProvider]

    private let mappingsKey = "Ito.MultiTrackerMappings"
    private let legacyMappingsKey = "Ito.TrackerMappings"

    private init() {
        // Initialize providers here
        self.providers = [
            AnilistTracker()
        ]

        loadMappings()
    }

    private func loadMappings() {
        if let data = UserDefaults.standard.data(forKey: mappingsKey),
           let decoded = try? JSONDecoder().decode([String: [String: String]].self, from: data) {
            self.trackerMappings = decoded
        } else {
            // Migrate legacy mappings
            if let legacyData = UserDefaults.standard.data(forKey: legacyMappingsKey),
               let legacyDecoded = try? JSONDecoder().decode([String: Int].self, from: legacyData) {

                var newMappings: [String: [String: String]] = [:]
                for (localId, anilistId) in legacyDecoded {
                    newMappings[localId] = ["anilist": String(anilistId)]
                }

                self.trackerMappings = newMappings
                saveMappings()
            }
        }
    }

    private func saveMappings() {
        if let encoded = try? JSONEncoder().encode(trackerMappings) {
            UserDefaults.standard.set(encoded, forKey: mappingsKey)
        }
    }

    public func link(localId: String, providerId: String, mediaId: String) {
        var currentMapping = trackerMappings[localId] ?? [:]
        currentMapping[providerId] = mediaId
        trackerMappings[localId] = currentMapping
        saveMappings()

        // Backward compatibility for AniList in LibraryItem if needed.
        // It's recommended to migrate LibraryManager away from `anilistId` to generic tracker logic,
        // but to avoid breaking things instantly:
        if providerId == "anilist", let intId = Int(mediaId) {
            LibraryManager.shared.setAnilistId(for: localId, anilistId: intId)
        }
    }

    public func unlink(localId: String, providerId: String) {
        if var currentMapping = trackerMappings[localId] {
            currentMapping.removeValue(forKey: providerId)
            if currentMapping.isEmpty {
                trackerMappings.removeValue(forKey: localId)
            } else {
                trackerMappings[localId] = currentMapping
            }
            saveMappings()
        }

        if providerId == "anilist" {
            LibraryManager.shared.removeAnilistId(for: localId)
        }
    }

    public func getMediaId(for localId: String, providerId: String) -> String? {
        if let mappedId = trackerMappings[localId]?[providerId] {
            return mappedId
        }

        // Fallback for AniList legacy
        if providerId == "anilist", let legacyId = LibraryManager.shared.getAnilistId(for: localId) {
            return String(legacyId)
        }

        return nil
    }

    public var authenticatedProviders: [any TrackerProvider] {
        return providers.filter { $0.isAuthenticated }
    }

    public func updateProgress(localId: String, progress: Int) async {
        let mappings = trackerMappings[localId] ?? [:]

        for provider in authenticatedProviders {
            if let mediaId = mappings[provider.identifier] {
                do {
                    try await provider.updateProgress(mediaId: mediaId, progress: progress, status: nil)
                } catch {
                    print("Failed to update progress on \(provider.name): \(error.localizedDescription)")
                }
            } else if provider.identifier == "anilist", let legacyId = LibraryManager.shared.getAnilistId(for: localId) {
                // Legacy fallback update
                do {
                    try await provider.updateProgress(mediaId: String(legacyId), progress: progress, status: nil)
                } catch {
                    print("Failed to update legacy AniList progress: \(error.localizedDescription)")
                }
            }
        }
    }
}

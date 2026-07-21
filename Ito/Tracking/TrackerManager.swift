import OSLog
import Foundation
import Combine

@MainActor
public class TrackerManager: ObservableObject {
    enum CredentialBootstrapState: Equatable {
        case notStarted
        case inFlight
        case ready
        case retryableProtectedDataFailure
        case recoverableVerificationFailure
        case conflict
        case permanentFailure
    }

    public static let shared: TrackerManager = {
        let credentialStore = KeychainTrackerCredentialStore()
        let legacyTokenStore = LegacyTokenStore(defaults: .standard)
        return TrackerManager(
            credentialStore: credentialStore,
            legacyTokenStore: legacyTokenStore,
            defaults: .standard
        )
    }()

    // Instead of [String: Int], we now map [LocalId: [TrackerIdentifier: String]]
    @Published public private(set) var trackerMappings: [String: [String: String]] = [:]
    @Published private(set) var credentialBootstrapState: CredentialBootstrapState = .notStarted

    public let providers: [any TrackerProvider]

    private let mappingsKey = "Ito.MultiTrackerMappings"
    private let legacyMappingsKey = "Ito.TrackerMappings"
    private let defaults: UserDefaults
    private let anilistTracker: AnilistTracker
    private var credentialBootstrapTask: Task<AniListCredentialRepository.BootstrapOutcome, any Error>?

    init(
        credentialStore: any TrackerCredentialStoring,
        legacyTokenStore: any LegacyTokenStoring,
        defaults: UserDefaults
    ) {
        let credentialRepository = AniListCredentialRepository(
            secureStore: credentialStore,
            legacyStore: legacyTokenStore
        )
        let anilistTracker = AnilistTracker(
            credentialRepository: credentialRepository,
            usernameDefaults: defaults
        )
        self.defaults = defaults
        self.anilistTracker = anilistTracker
        self.providers = [anilistTracker]

        loadMappings()
    }

    func bootstrapCredentials() async {
        switch credentialBootstrapState {
        case .ready, .conflict, .permanentFailure:
            return
        case .notStarted, .inFlight, .retryableProtectedDataFailure, .recoverableVerificationFailure:
            break
        }

        if let credentialBootstrapTask {
            await finishBootstrap(credentialBootstrapTask)
            return
        }

        credentialBootstrapState = .inFlight
        let task = Task { try await anilistTracker.bootstrapCredentials() }
        credentialBootstrapTask = task
        await finishBootstrap(task)
    }

    private func finishBootstrap(
        _ task: Task<AniListCredentialRepository.BootstrapOutcome, any Error>
    ) async {
        do {
            let outcome = try await task.value
            credentialBootstrapState = CredentialBootstrapState(outcome.state)
        } catch {
            credentialBootstrapState = .permanentFailure
        }
        credentialBootstrapTask = nil
    }

    private func loadMappings() {
        if let data = defaults.data(forKey: mappingsKey),
           let decoded = try? JSONDecoder().decode([String: [String: String]].self, from: data) {
            self.trackerMappings = decoded
        } else {
            // Migrate legacy mappings
            if let legacyData = defaults.data(forKey: legacyMappingsKey),
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
            defaults.set(encoded, forKey: mappingsKey)
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
                    AppLogger.auth.error("\("Failed to update progress on \(provider.name)"): \(error.localizedDescription)")
                }
            } else if provider.identifier == "anilist", let legacyId = LibraryManager.shared.getAnilistId(for: localId) {
                // Legacy fallback update
                do {
                    try await provider.updateProgress(mediaId: String(legacyId), progress: progress, status: nil)
                } catch {
                    AppLogger.auth.error("Failed to update legacy AniList progress: \(error.localizedDescription)")
                }
            }
        }
    }
}

private extension TrackerManager.CredentialBootstrapState {
    init(_ state: AniListCredentialRepository.BootstrapState) {
        switch state {
        case .notStarted:
            self = .notStarted
        case .ready:
            self = .ready
        case .retryableProtectedDataFailure:
            self = .retryableProtectedDataFailure
        case .recoverableVerificationFailure:
            self = .recoverableVerificationFailure
        case .conflict:
            self = .conflict
        case .permanentFailure:
            self = .permanentFailure
        }
    }
}

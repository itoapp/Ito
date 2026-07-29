import Combine
import Foundation
import GRDB
import OSLog

@MainActor
public final class TrackerManager: ObservableObject {
    enum CredentialBootstrapState: Equatable {
        case notStarted
        case inFlight
        case ready
        case retryableProtectedDataFailure
        case recoverableVerificationFailure
        case conflict
        case permanentFailure
    }

    @Published private var trackerMappings: [MediaIdentity: [String: String]] = [:]
    @Published private(set) var credentialBootstrapState: CredentialBootstrapState = .notStarted

    public let providers: [any TrackerProvider]

    private let dbPool: DatabasePool
    private let anilistTracker: AnilistTracker
    private var credentialBootstrapTask: Task<AniListCredentialRepository.BootstrapOutcome, any Error>?

    init(
        dbPool: DatabasePool,
        credentialStore: any TrackerCredentialStoring,
        legacyTokenStore: any LegacyTokenStoring,
        usernameDefaults: UserDefaults
    ) {
        self.dbPool = dbPool
        let credentialRepository = AniListCredentialRepository(
            secureStore: credentialStore,
            legacyStore: legacyTokenStore
        )
        let tracker = AnilistTracker(
            credentialRepository: credentialRepository,
            usernameDefaults: usernameDefaults
        )
        anilistTracker = tracker
        providers = [tracker]
    }

    func reload() async throws {
        let records = try await dbPool.read { db in
            try TrackerLinkRecord.fetchAll(db)
        }
        trackerMappings = Dictionary(grouping: records) {
            MediaIdentity(pluginId: $0.pluginId, canonicalMediaId: $0.canonicalMediaId)
        }.mapValues { Dictionary(uniqueKeysWithValues: $0.map { ($0.providerId, $0.remoteMediaId) }) }
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
            credentialBootstrapState = CredentialBootstrapState(try await task.value.state)
        } catch {
            credentialBootstrapState = .permanentFailure
        }
        credentialBootstrapTask = nil
    }

    public func link(
        media: MediaIdentity,
        providerId: String,
        remoteMediaId: String
    ) async throws {
        try await dbPool.write { db in
            try TrackerLinkRecord(
                pluginId: media.pluginId,
                canonicalMediaId: media.canonicalMediaId,
                providerId: providerId,
                remoteMediaId: remoteMediaId,
                updatedAt: Date(),
                provenance: .runtime
            ).save(db)
        }
        trackerMappings[media, default: [:]][providerId] = remoteMediaId
    }

    public func unlink(media: MediaIdentity, providerId: String) async throws {
        _ = try await dbPool.write { db in
            try TrackerLinkRecord
                .filter(Column("pluginId") == media.pluginId)
                .filter(Column("canonicalMediaId") == media.canonicalMediaId)
                .filter(Column("providerId") == providerId)
                .deleteAll(db)
        }
        trackerMappings[media]?.removeValue(forKey: providerId)
        if trackerMappings[media]?.isEmpty == true {
            trackerMappings.removeValue(forKey: media)
        }
    }

    public func trackerId(for media: MediaIdentity, providerId: String) -> String? {
        trackerMappings[media]?[providerId]
    }

    public func hasLinks(for media: MediaIdentity) -> Bool {
        trackerMappings[media]?.isEmpty == false
    }

    public var authenticatedProviders: [any TrackerProvider] {
        providers.filter(\.isAuthenticated)
    }

    public func updateProgress(media: MediaIdentity, progress: Int) async {
        let mappings = trackerMappings[media] ?? [:]
        for provider in authenticatedProviders {
            guard let remoteMediaId = mappings[provider.identifier] else { continue }
            do {
                try await provider.updateProgress(mediaId: remoteMediaId, progress: progress, status: nil)
            } catch {
                AppLogger.auth.error(
                    "Failed to update progress on \(provider.name): \(error.localizedDescription)"
                )
            }
        }
    }
}

private extension TrackerManager.CredentialBootstrapState {
    init(_ state: AniListCredentialRepository.BootstrapState) {
        switch state {
        case .notStarted: self = .notStarted
        case .ready: self = .ready
        case .retryableProtectedDataFailure: self = .retryableProtectedDataFailure
        case .recoverableVerificationFailure: self = .recoverableVerificationFailure
        case .conflict: self = .conflict
        case .permanentFailure: self = .permanentFailure
        }
    }
}

import Foundation
import Security
import Testing
@testable import Ito

@MainActor
struct AnilistTrackerCredentialTests {
    @Test func OAuthWithNoPriorSessionStaysUnpublishedUntilReadbackAndCleanupFinish() async throws {
        let readbackGate = AsyncTestGate()
        let cleanupGate = AsyncTestGate()
        let secure = FakeTrackerCredentialStore(readGates: [readbackGate])
        let legacy = FakeLegacyTokenStore(token: "legacy-fixture", removalGates: [cleanupGate])
        let subject = makeSubject(secure: secure, legacy: legacy)
        defer { subject.cleanup() }

        let oauth = Task { try await subject.tracker.persistAuthenticatedToken("oauth-fixture") }
        await readbackGate.waitForAdmissions()
        #expect(subject.tracker.anilistToken == nil)

        await readbackGate.open()
        await cleanupGate.waitForAdmissions()
        #expect(subject.tracker.anilistToken == nil)

        await cleanupGate.open()
        try await oauth.value
        #expect(subject.tracker.anilistToken == "oauth-fixture")
        #expect(await legacy.currentToken() == nil)
    }

    @Test func failedOAuthReadbackPreservesExistingPublishedSession() async throws {
        let secure = FakeTrackerCredentialStore(
            initialToken: "old-fixture",
            readResults: [
                .success("old-fixture"),
                .failure(.protectedDataUnavailable(errSecNotAvailable)),
                .failure(.protectedDataUnavailable(errSecNotAvailable))
            ]
        )
        let legacy = FakeLegacyTokenStore()
        let subject = makeSubject(secure: secure, legacy: legacy)
        defer { subject.cleanup() }
        _ = try await subject.tracker.bootstrapCredentials()
        #expect(subject.tracker.anilistToken == "old-fixture")

        await #expect(throws: AniListCredentialRepository.RepositoryError.storage(
            .protectedDataUnavailable(errSecNotAvailable)
        )) {
            try await subject.tracker.persistAuthenticatedToken("new-fixture")
        }

        #expect(subject.tracker.anilistToken == "old-fixture")
        #expect(subject.tracker.isAuthenticated)

        let outcome = try await subject.tracker.bootstrapCredentials()

        #expect(outcome == .init(state: .retryableProtectedDataFailure, token: "old-fixture"))
        #expect(subject.tracker.anilistToken == "old-fixture")

        let recoveredOutcome = try await subject.tracker.bootstrapCredentials()

        #expect(recoveredOutcome == .init(state: .ready, token: "new-fixture"))
        #expect(subject.tracker.anilistToken == "new-fixture")
    }

    @Test func failedOAuthReadbackLeavesNilPublishedSessionUnchanged() async throws {
        let secure = FakeTrackerCredentialStore(readResults: [
            .failure(.protectedDataUnavailable(errSecInteractionNotAllowed))
        ])
        let legacy = FakeLegacyTokenStore()
        let subject = makeSubject(secure: secure, legacy: legacy)
        defer { subject.cleanup() }

        await #expect(throws: AniListCredentialRepository.RepositoryError.storage(
            .protectedDataUnavailable(errSecInteractionNotAllowed)
        )) {
            try await subject.tracker.persistAuthenticatedToken("new-fixture")
        }

        #expect(subject.tracker.anilistToken == nil)
        #expect(!subject.tracker.isAuthenticated)
    }

    @Test func OAuthCleanupFailurePreservesExistingPublishedSession() async throws {
        let secure = FakeTrackerCredentialStore(
            initialToken: "old-fixture",
            readResults: [.success("old-fixture"), .success("new-fixture")]
        )
        let legacy = FakeLegacyTokenStore(
            token: "legacy-fixture",
            removalResults: [.failure(.init(errorDescription: "redacted cleanup failure"))]
        )
        let subject = makeSubject(secure: secure, legacy: legacy)
        defer { subject.cleanup() }
        _ = try await subject.tracker.bootstrapCredentials()
        #expect(subject.tracker.anilistToken == "old-fixture")

        await #expect(throws: AniListCredentialRepository.RepositoryError.legacyCleanupFailed) {
            try await subject.tracker.persistAuthenticatedToken("new-fixture")
        }

        #expect(subject.tracker.anilistToken == "old-fixture")
        #expect(await secure.currentToken() == "new-fixture")
        #expect(await legacy.currentToken() == "legacy-fixture")

        let outcome = try await subject.tracker.bootstrapCredentials()

        #expect(outcome == .init(state: .ready, token: "new-fixture"))
        #expect(subject.tracker.anilistToken == "new-fixture")
        #expect(await legacy.currentToken() == nil)
    }

    @Test func secureLogoutFailurePreservesTokenUsernameAndLegacyCredential() async throws {
        let secure = FakeTrackerCredentialStore(
            initialToken: "secure-fixture",
            removeResults: [.failure(.protectedDataUnavailable(errSecInteractionNotAllowed))]
        )
        let legacy = FakeLegacyTokenStore(token: "legacy-fixture")
        let subject = makeSubject(secure: secure, legacy: legacy, username: "fixture-user")
        defer { subject.cleanup() }
        _ = try await subject.tracker.bootstrapCredentials()

        await #expect(throws: AniListCredentialRepository.RepositoryError.storage(
            .protectedDataUnavailable(errSecInteractionNotAllowed)
        )) {
            try await subject.tracker.logout()
        }

        #expect(subject.tracker.anilistToken == "secure-fixture")
        #expect(subject.tracker.username == "fixture-user")
        #expect(await secure.currentToken() == "secure-fixture")
        #expect(await legacy.currentToken() == "legacy-fixture")
    }

    @Test func legacyLogoutFailurePreservesPublishedStateAndRetryCompletesCleanup() async throws {
        let secure = FakeTrackerCredentialStore(initialToken: "secure-fixture")
        let legacy = FakeLegacyTokenStore(
            token: "legacy-fixture",
            removalResults: [
                .failure(.init(errorDescription: "redacted cleanup failure")),
                .success(())
            ]
        )
        let subject = makeSubject(secure: secure, legacy: legacy, username: "fixture-user")
        defer { subject.cleanup() }
        _ = try await subject.tracker.bootstrapCredentials()

        await #expect(throws: AniListCredentialRepository.RepositoryError.legacyCleanupFailed) {
            try await subject.tracker.logout()
        }
        #expect(subject.tracker.anilistToken == "secure-fixture")
        #expect(subject.tracker.username == "fixture-user")
        #expect(await secure.currentToken() == nil)
        #expect(await legacy.currentToken() == "legacy-fixture")

        try await subject.tracker.logout()
        #expect(subject.tracker.anilistToken == nil)
        #expect(subject.tracker.username == nil)
        #expect(await legacy.currentToken() == nil)
        #expect(subject.defaults.object(forKey: "anilist_username") == nil)
    }

    @Test func postMutationLogoutCancellationClearsAllPublishedAndPersistedState() async throws {
        let legacyRemovalGate = AsyncTestGate()
        let secure = FakeTrackerCredentialStore(initialToken: "secure-fixture")
        let legacy = FakeLegacyTokenStore(
            token: "legacy-fixture",
            removalGates: [legacyRemovalGate]
        )
        let subject = makeSubject(
            secure: secure,
            legacy: legacy,
            username: "fixture-user"
        )
        defer { subject.cleanup() }
        _ = try await subject.tracker.bootstrapCredentials()

        let logout = Task { try await subject.tracker.logout() }
        await legacyRemovalGate.waitForAdmissions()
        #expect(await secure.currentToken() == nil)

        logout.cancel()
        await legacyRemovalGate.open()
        try await logout.value

        #expect(await legacy.currentToken() == nil)
        #expect(subject.tracker.anilistToken == nil)
        #expect(subject.tracker.username == nil)
        #expect(subject.defaults.object(forKey: "anilist_username") == nil)

        let freshRepository = AniListCredentialRepository(secureStore: secure, legacyStore: legacy)
        let freshTracker = AnilistTracker(
            credentialRepository: freshRepository,
            usernameDefaults: subject.defaults
        )
        let freshOutcome = try await freshTracker.bootstrapCredentials()

        #expect(freshOutcome == .init(state: .ready, token: nil))
        #expect(!freshTracker.isAuthenticated)
        #expect(freshTracker.username == nil)
    }

    @Test func cancelledOAuthFollowedByQueuedLogoutCannotRepublishOAuthToken() async throws {
        let oauthReadbackGate = AsyncTestGate()
        let secure = FakeTrackerCredentialStore(
            initialToken: "old-fixture",
            readGates: [nil, oauthReadbackGate]
        )
        let legacy = FakeLegacyTokenStore()
        let subject = makeSubject(secure: secure, legacy: legacy)
        defer { subject.cleanup() }
        _ = try await subject.tracker.bootstrapCredentials()

        let oauth = Task { try await subject.tracker.persistAuthenticatedToken("new-fixture") }
        await oauthReadbackGate.waitForAdmissions()
        let logout = Task { try await subject.tracker.logout() }
        oauth.cancel()
        await oauthReadbackGate.open()

        try await oauth.value
        try await logout.value

        #expect(subject.tracker.anilistToken == nil)
        #expect(!subject.tracker.isAuthenticated)
        #expect(await secure.currentToken() == nil)
        #expect(await legacy.currentToken() == nil)
    }

    private func makeSubject(
        secure: FakeTrackerCredentialStore,
        legacy: FakeLegacyTokenStore,
        username: String? = nil
    ) -> TrackerSubject {
        let suiteName = "AnilistTrackerCredentialTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        if let username {
            defaults.set(username, forKey: "anilist_username")
        }
        let repository = AniListCredentialRepository(secureStore: secure, legacyStore: legacy)
        let tracker = AnilistTracker(credentialRepository: repository, usernameDefaults: defaults)
        return TrackerSubject(tracker: tracker, defaults: defaults, suiteName: suiteName)
    }
}

@MainActor
private struct TrackerSubject {
    let tracker: AnilistTracker
    let defaults: UserDefaults
    let suiteName: String

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

import Foundation
import Security
import Testing
@testable import Ito

struct AniListCredentialRepositoryTests {
    private let providerID = "anilist"

    @Test func legacyOnlyBootstrapPublishesAfterExactReadbackAndVerifiedCleanup() async throws {
        let journal = CredentialTestJournal()
        let secure = FakeTrackerCredentialStore(journal: journal)
        let legacy = FakeLegacyTokenStore(token: "legacy-fixture", journal: journal)
        let repository = AniListCredentialRepository(secureStore: secure, legacyStore: legacy)
        let publication = CredentialPublicationProbe()

        let outcome = try await repository.bootstrap { token in
            journal.record(.publication)
            publication.record(token)
        }

        #expect(outcome == .init(state: .ready, token: "legacy-fixture"))
        #expect(publication.lastToken == "legacy-fixture")
        #expect(await legacy.currentToken() == nil)
        #expect(journal.snapshot() == [
            .secureRead, .legacyRead, .secureSet, .secureRead,
            .legacyRemove, .legacyRead, .publication
        ])
    }

    @Test func secureOnlyBootstrapPublishesWithoutMutation() async throws {
        let secure = FakeTrackerCredentialStore(initialToken: "secure-fixture")
        let legacy = FakeLegacyTokenStore()
        let repository = AniListCredentialRepository(secureStore: secure, legacyStore: legacy)
        let publication = CredentialPublicationProbe()

        let outcome = try await repository.bootstrap { publication.record($0) }

        #expect(outcome == .init(state: .ready, token: "secure-fixture"))
        #expect(publication.lastToken == "secure-fixture")
        #expect(await secure.recordedOperations() == [.read(providerID: providerID)])
        #expect(await legacy.recordedOperations() == [.read])
    }

    @Test func equalSecureAndLegacyBootstrapCleansLegacyWithoutRewritingSecure() async throws {
        let secure = FakeTrackerCredentialStore(initialToken: "equal-fixture")
        let legacy = FakeLegacyTokenStore(token: "equal-fixture")
        let repository = AniListCredentialRepository(secureStore: secure, legacyStore: legacy)

        let outcome = try await repository.bootstrap()

        #expect(outcome == .init(state: .ready, token: "equal-fixture"))
        #expect(await secure.recordedOperations() == [.read(providerID: providerID)])
        #expect(await legacy.recordedOperations() == [.read, .remove, .read])
    }

    @Test func conflictingSecureAndLegacyCredentialsUseSecureAndKeepBoth() async throws {
        let secure = FakeTrackerCredentialStore(initialToken: "secure-fixture")
        let legacy = FakeLegacyTokenStore(token: "legacy-fixture")
        let repository = AniListCredentialRepository(secureStore: secure, legacyStore: legacy)
        let publication = CredentialPublicationProbe()

        let outcome = try await repository.bootstrap { publication.record($0) }

        #expect(outcome == .init(state: .conflict, token: "secure-fixture"))
        #expect(publication.lastToken == "secure-fixture")
        #expect(await secure.currentToken() == "secure-fixture")
        #expect(await legacy.currentToken() == "legacy-fixture")
        #expect(await secure.recordedOperations() == [.read(providerID: providerID)])
    }

    @Test func protectedSecureReadRetainsLegacyAndDoesNotPublish() async throws {
        let secure = FakeTrackerCredentialStore(
            readResults: [.failure(.protectedDataUnavailable(errSecInteractionNotAllowed))]
        )
        let legacy = FakeLegacyTokenStore(token: "legacy-fixture")
        let repository = AniListCredentialRepository(secureStore: secure, legacyStore: legacy)
        let publication = CredentialPublicationProbe()

        let outcome = try await repository.bootstrap { publication.record($0) }

        #expect(outcome == .init(state: .retryableProtectedDataFailure, token: nil))
        #expect(publication.count == 0)
        #expect(await legacy.currentToken() == "legacy-fixture")
        #expect(await secure.recordedOperations() == [.read(providerID: providerID)])
    }

    @Test func bootstrapReadbackMismatchRetainsBothStoresThenExplicitBootstrapRepairs() async throws {
        let secure = FakeTrackerCredentialStore(readResults: [.success(nil), .success("mismatch-fixture")])
        let legacy = FakeLegacyTokenStore(token: "legacy-fixture")
        let repository = AniListCredentialRepository(secureStore: secure, legacyStore: legacy)
        let publication = CredentialPublicationProbe()

        let firstOutcome = try await repository.bootstrap { publication.record($0) }

        #expect(firstOutcome == .init(state: .recoverableVerificationFailure, token: nil))
        #expect(publication.count == 0)
        #expect(await secure.currentToken() == "legacy-fixture")
        #expect(await legacy.currentToken() == "legacy-fixture")
        #expect(!((await secure.recordedOperations()).contains(.remove(providerID: providerID))))

        let recoveredOutcome = try await repository.bootstrap { publication.record($0) }

        #expect(recoveredOutcome == .init(state: .ready, token: "legacy-fixture"))
        #expect(publication.lastToken == "legacy-fixture")
        #expect(await legacy.currentToken() == nil)
    }

    @Test func protectedBootstrapReadbackRetainsBothStoresThenExplicitBootstrapRepairs() async throws {
        let secure = FakeTrackerCredentialStore(readResults: [
            .success(nil),
            .failure(.protectedDataUnavailable(errSecNotAvailable))
        ])
        let legacy = FakeLegacyTokenStore(token: "legacy-fixture")
        let repository = AniListCredentialRepository(secureStore: secure, legacyStore: legacy)
        let publication = CredentialPublicationProbe()

        let firstOutcome = try await repository.bootstrap { publication.record($0) }

        #expect(firstOutcome == .init(state: .retryableProtectedDataFailure, token: nil))
        #expect(publication.count == 0)
        #expect(await secure.currentToken() == "legacy-fixture")
        #expect(await legacy.currentToken() == "legacy-fixture")
        #expect(!((await secure.recordedOperations()).contains(.remove(providerID: providerID))))

        let recoveredOutcome = try await repository.bootstrap { publication.record($0) }

        #expect(recoveredOutcome == .init(state: .ready, token: "legacy-fixture"))
        #expect(publication.lastToken == "legacy-fixture")
        #expect(await legacy.currentToken() == nil)
    }

    @Test func protectedPendingRepairRetainsRetryableStateAndRepairToken() async throws {
        let secure = FakeTrackerCredentialStore(readResults: [
            .success(nil),
            .success("mismatch-fixture"),
            .failure(.protectedDataUnavailable(errSecInteractionNotAllowed))
        ])
        let legacy = FakeLegacyTokenStore(token: "legacy-fixture")
        let repository = AniListCredentialRepository(secureStore: secure, legacyStore: legacy)
        let publication = CredentialPublicationProbe()

        let mismatchOutcome = try await repository.bootstrap { publication.record($0) }
        let protectedOutcome = try await repository.bootstrap { publication.record($0) }

        #expect(mismatchOutcome == .init(state: .recoverableVerificationFailure, token: nil))
        #expect(protectedOutcome == .init(state: .retryableProtectedDataFailure, token: nil))
        #expect(publication.count == 0)
        #expect(await secure.currentToken() == "legacy-fixture")
        #expect(await legacy.currentToken() == "legacy-fixture")

        let recoveredOutcome = try await repository.bootstrap { publication.record($0) }

        #expect(recoveredOutcome == .init(state: .ready, token: "legacy-fixture"))
        #expect(publication.lastToken == "legacy-fixture")
        #expect(await legacy.currentToken() == nil)
    }

    @Test func equalCredentialsWithStickyLegacyCleanupPublishOnlyAfterExplicitRepair() async throws {
        let secure = FakeTrackerCredentialStore(initialToken: "equal-fixture")
        let legacy = FakeLegacyTokenStore(
            token: "equal-fixture",
            stickyRemovalResults: [true, false]
        )
        let repository = AniListCredentialRepository(secureStore: secure, legacyStore: legacy)
        let publication = CredentialPublicationProbe()

        let firstOutcome = try await repository.bootstrap { publication.record($0) }

        #expect(firstOutcome == .init(state: .recoverableVerificationFailure, token: nil))
        #expect(publication.count == 0)
        #expect(await secure.currentToken() == "equal-fixture")
        #expect(await legacy.currentToken() == "equal-fixture")

        let recoveredOutcome = try await repository.bootstrap { publication.record($0) }

        #expect(recoveredOutcome == .init(state: .ready, token: "equal-fixture"))
        #expect(publication.lastToken == "equal-fixture")
        #expect(await legacy.currentToken() == nil)
    }

    @Test func concurrentBootstrapCoalescesAndSuccessfulBootstrapBecomesNoOp() async throws {
        let readGate = AsyncTestGate()
        let secure = FakeTrackerCredentialStore(readGates: [readGate])
        let legacy = FakeLegacyTokenStore()
        let repository = AniListCredentialRepository(secureStore: secure, legacyStore: legacy)

        let first = Task { try await repository.bootstrap() }
        await readGate.waitForAdmissions()
        let second = Task { try await repository.bootstrap() }
        await repository.waitForEnqueuedInvocations(2)
        await readGate.open()

        #expect(try await first.value == .init(state: .ready, token: nil))
        #expect(try await second.value == .init(state: .ready, token: nil))
        _ = try await repository.bootstrap()
        #expect(await secure.recordedOperations() == [.read(providerID: providerID)])
        let metrics = await repository.instrumentationSnapshot()
        #expect(metrics.enqueuedInvocations == 2)
        #expect(metrics.startedOperations == 1)
    }

    @Test func protectedBootstrapRetriesAndCompletesOnNextInvocation() async throws {
        let secure = FakeTrackerCredentialStore(readResults: [
            .failure(.protectedDataUnavailable(errSecNotAvailable)),
            .success(nil)
        ])
        let legacy = FakeLegacyTokenStore(token: "legacy-fixture")
        let repository = AniListCredentialRepository(secureStore: secure, legacyStore: legacy)

        #expect(try await repository.bootstrap().state == .retryableProtectedDataFailure)
        #expect(try await repository.bootstrap().state == .ready)
        #expect(await legacy.currentToken() == nil)
        #expect(await secure.currentToken() == "legacy-fixture")
    }

    @Test func bootstrapThenOAuthRemainSerializedWhileBootstrapIsSuspended() async throws {
        let gate = AsyncTestGate()
        let secure = FakeTrackerCredentialStore(readGates: [gate])
        let repository = AniListCredentialRepository(secureStore: secure, legacyStore: FakeLegacyTokenStore())

        let bootstrap = Task { try await repository.bootstrap() }
        await gate.waitForAdmissions()
        let oauth = Task { try await repository.persistOAuthToken("oauth-fixture") }
        await repository.waitForEnqueuedInvocations(2)

        #expect(await repository.instrumentationSnapshot().activeOperations == 1)
        #expect(await repository.instrumentationSnapshot().maximumActiveOperations == 1)
        #expect(await secure.metrics().maximum == 1)
        await gate.open()
        _ = try await bootstrap.value
        try await oauth.value
        #expect(await repository.instrumentationSnapshot().maximumActiveOperations == 1)
    }

    @Test func bootstrapThenLogoutRemainSerializedWhileBootstrapIsSuspended() async throws {
        let gate = AsyncTestGate()
        let secure = FakeTrackerCredentialStore(initialToken: "secure-fixture", readGates: [gate])
        let repository = AniListCredentialRepository(secureStore: secure, legacyStore: FakeLegacyTokenStore())

        let bootstrap = Task { try await repository.bootstrap() }
        await gate.waitForAdmissions()
        let logout = Task { try await repository.logout() }
        await repository.waitForEnqueuedInvocations(2)

        #expect(await repository.instrumentationSnapshot().activeOperations == 1)
        #expect(await repository.instrumentationSnapshot().maximumActiveOperations == 1)
        await gate.open()
        _ = try await bootstrap.value
        try await logout.value
        #expect(await secure.currentToken() == nil)
        #expect(await repository.instrumentationSnapshot().maximumActiveOperations == 1)
    }

    @Test func OAuthThenLogoutRemainSerializedWhileOAuthIsSuspended() async throws {
        let gate = AsyncTestGate()
        let secure = FakeTrackerCredentialStore(setGates: [gate])
        let repository = AniListCredentialRepository(secureStore: secure, legacyStore: FakeLegacyTokenStore())

        let oauth = Task { try await repository.persistOAuthToken("oauth-fixture") }
        await gate.waitForAdmissions()
        let logout = Task { try await repository.logout() }
        await repository.waitForEnqueuedInvocations(2)

        #expect(await repository.instrumentationSnapshot().activeOperations == 1)
        #expect(await repository.instrumentationSnapshot().maximumActiveOperations == 1)
        await gate.open()
        try await oauth.value
        try await logout.value
        #expect(await secure.currentToken() == nil)
        #expect(await repository.instrumentationSnapshot().maximumActiveOperations == 1)
    }

    @Test func logoutThenOAuthRemainSerializedAndOAuthWins() async throws {
        let gate = AsyncTestGate()
        let secure = FakeTrackerCredentialStore(initialToken: "old-fixture", removeGates: [gate])
        let repository = AniListCredentialRepository(secureStore: secure, legacyStore: FakeLegacyTokenStore())

        let logout = Task { try await repository.logout() }
        await gate.waitForAdmissions()
        let oauth = Task { try await repository.persistOAuthToken("new-fixture") }
        await repository.waitForEnqueuedInvocations(2)

        #expect(await repository.instrumentationSnapshot().activeOperations == 1)
        #expect(await repository.instrumentationSnapshot().maximumActiveOperations == 1)
        await gate.open()
        try await logout.value
        try await oauth.value
        #expect(await secure.currentToken() == "new-fixture")
        #expect(await repository.instrumentationSnapshot().maximumActiveOperations == 1)
    }

    @Test func cancellationOfQueuedOAuthPerformsNoMutation() async throws {
        let gate = AsyncTestGate()
        let secure = FakeTrackerCredentialStore(readGates: [gate])
        let repository = AniListCredentialRepository(secureStore: secure, legacyStore: FakeLegacyTokenStore())
        let bootstrap = Task { try await repository.bootstrap() }
        await gate.waitForAdmissions()
        let oauth = Task { try await repository.persistOAuthToken("canceled-fixture") }
        await repository.waitForEnqueuedInvocations(2)

        oauth.cancel()
        await #expect(throws: CancellationError.self) { try await oauth.value }
        await gate.open()
        _ = try await bootstrap.value

        #expect(await secure.recordedOperations() == [.read(providerID: providerID)])
        #expect(await secure.currentToken() == nil)
    }

    @Test func cancellationAfterOAuthMutationCompletesPolicyAndSuppressesPublication() async throws {
        let readbackGate = AsyncTestGate()
        let journal = CredentialTestJournal()
        let secure = FakeTrackerCredentialStore(readGates: [readbackGate], journal: journal)
        let legacy = FakeLegacyTokenStore(token: "legacy-fixture", journal: journal)
        let repository = AniListCredentialRepository(secureStore: secure, legacyStore: legacy)
        let publication = CredentialPublicationProbe()
        let oauth = Task {
            try await repository.persistOAuthToken("oauth-fixture") {
                journal.record(.publication)
                publication.record($0)
            }
        }
        await readbackGate.waitForAdmissions()

        oauth.cancel()
        await readbackGate.open()
        try await oauth.value

        #expect(await secure.recordedOperations() == [
            .set(providerID: providerID), .read(providerID: providerID)
        ])
        #expect(await secure.currentToken() == "oauth-fixture")
        #expect(await legacy.currentToken() == nil)
        #expect(try await repository.bootstrap() == .init(state: .ready, token: "oauth-fixture"))
        #expect(publication.count == 0)
        #expect(journal.snapshot() == [
            .secureSet, .secureRead, .legacyRemove, .legacyRead
        ])
    }

    @Test func activeLogoutCancellationStillPublishesMandatoryClearing() async throws {
        let legacyRemovalGate = AsyncTestGate()
        let secure = FakeTrackerCredentialStore(initialToken: "secure-fixture")
        let legacy = FakeLegacyTokenStore(
            token: "legacy-fixture",
            removalGates: [legacyRemovalGate]
        )
        let repository = AniListCredentialRepository(secureStore: secure, legacyStore: legacy)
        let publication = CredentialPublicationProbe()
        let logout = Task {
            try await repository.logout { publication.record($0) }
        }
        await legacyRemovalGate.waitForAdmissions()
        #expect(await secure.currentToken() == nil)

        logout.cancel()
        await legacyRemovalGate.open()
        try await logout.value

        #expect(await legacy.currentToken() == nil)
        #expect(publication.count == 1)
        #expect(publication.lastToken == nil)
    }

    @Test func noCredentialsCompletesReadyWithoutMutation() async throws {
        let secure = FakeTrackerCredentialStore()
        let legacy = FakeLegacyTokenStore()
        let repository = AniListCredentialRepository(secureStore: secure, legacyStore: legacy)

        let outcome = try await repository.bootstrap()

        #expect(outcome == .init(state: .ready, token: nil))
        #expect(await secure.recordedOperations() == [.read(providerID: providerID)])
        #expect(await legacy.recordedOperations() == [.read])
    }

    @Test func repositoryErrorsDoNotExposeCredentialFixtures() throws {
        let fixture = "fixture-secret-value-with-unique-fragment"
        let errors: [AniListCredentialRepository.RepositoryError] = [
            .verificationFailed,
            .legacyCleanupFailed,
            .storage(.unexpected(operation: .update, status: -9_999))
        ]

        for error in errors {
            let description = try #require(error.errorDescription)
            #expect(!description.contains(fixture))
            #expect(!description.contains("unique-fragment"))
            #expect(!description.contains(String(fixture.utf8.count)))
        }
    }
}

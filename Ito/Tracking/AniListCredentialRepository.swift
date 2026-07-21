import Foundation

actor AniListCredentialRepository {
    nonisolated enum BootstrapState: Equatable, Sendable {
        case notStarted
        case ready
        case retryableProtectedDataFailure
        case recoverableVerificationFailure
        case conflict
        case permanentFailure
    }

    nonisolated struct BootstrapOutcome: Equatable, Sendable {
        let state: BootstrapState
        let token: String?
    }

    nonisolated struct InstrumentationSnapshot: Equatable, Sendable {
        let enqueuedInvocations: Int
        let startedOperations: Int
        let activeOperations: Int
        let maximumActiveOperations: Int
    }

    nonisolated enum RepositoryError: Error, Equatable, Sendable, LocalizedError {
        case verificationFailed
        case legacyCleanupFailed
        case storage(TrackerCredentialStoreError)

        var errorDescription: String? {
            switch self {
            case .verificationFailed:
                "Secure credential verification failed."
            case .legacyCleanupFailed:
                "Legacy credential cleanup could not be verified."
            case .storage(let error):
                error.errorDescription
            }
        }
    }

    typealias Publication = @MainActor @Sendable (String?) -> Void

    private enum Operation {
        case bootstrap(id: UUID)
        case persist(id: UUID, token: String)
        case logout(id: UUID)

        var id: UUID {
            switch self {
            case .bootstrap(let id), .persist(let id, _), .logout(let id):
                id
            }
        }
    }

    private struct BootstrapWaiter {
        let id: UUID
        let continuation: CheckedContinuation<BootstrapOutcome, any Error>
        let publication: Publication?
        var suppressPublication = false
    }

    private struct VoidWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
        let publication: Publication?
        var suppressPublication = false
    }

    private enum PublicationDecision {
        case none
        case publish(String?)
    }

    private struct BootstrapExecution {
        let outcome: BootstrapOutcome
        let publication: PublicationDecision
    }

    private static let providerID = "anilist"

    private let secureStore: any TrackerCredentialStoring
    private let legacyStore: any LegacyTokenStoring
    private var queue: [Operation] = []
    private var pumpRunning = false
    private var activeOperationID: UUID?
    private var activeLogoutID: UUID?
    private var pendingBootstrapID: UUID?
    private var bootstrapWaiters: [UUID: [BootstrapWaiter]] = [:]
    private var voidWaiters: [UUID: VoidWaiter] = [:]
    private(set) var bootstrapState: BootstrapState = .notStarted
    private var authoritativeToken: String?
    private var pendingRepairToken: String?
    private var enqueuedInvocations = 0
    private var startedOperations = 0
    private var activeOperations = 0
    private var maximumActiveOperations = 0
    private var enqueueWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(
        secureStore: any TrackerCredentialStoring,
        legacyStore: any LegacyTokenStoring
    ) {
        self.secureStore = secureStore
        self.legacyStore = legacyStore
    }

    func bootstrap(publication: Publication? = nil) async throws -> BootstrapOutcome {
        if !pumpRunning,
           queue.isEmpty,
           activeOperationID == nil,
           bootstrapState == .ready || bootstrapState == .conflict || bootstrapState == .permanentFailure {
            let outcome = BootstrapOutcome(state: bootstrapState, token: authoritativeToken)
            if let publication, bootstrapState == .ready || bootstrapState == .conflict {
                await publication(authoritativeToken)
            }
            return outcome
        }

        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                enqueueBootstrap(waiterID: waiterID, continuation: continuation, publication: publication)
            }
        } onCancel: {
            Task { await self.cancel(waiterID: waiterID) }
        }
    }

    func persistOAuthToken(_ token: String, publication: Publication? = nil) async throws {
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                enqueueVoid(
                    operation: .persist(id: UUID(), token: token),
                    waiterID: waiterID,
                    continuation: continuation,
                    publication: publication
                )
            }
        } onCancel: {
            Task { await self.cancel(waiterID: waiterID) }
        }
    }

    func logout(publication: Publication? = nil) async throws {
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                enqueueVoid(
                    operation: .logout(id: UUID()),
                    waiterID: waiterID,
                    continuation: continuation,
                    publication: publication
                )
            }
        } onCancel: {
            Task { await self.cancel(waiterID: waiterID) }
        }
    }

    func waitForEnqueuedInvocations(_ count: Int) async {
        guard enqueuedInvocations < count else { return }
        await withCheckedContinuation { enqueueWaiters.append((count, $0)) }
    }

    func instrumentationSnapshot() -> InstrumentationSnapshot {
        InstrumentationSnapshot(
            enqueuedInvocations: enqueuedInvocations,
            startedOperations: startedOperations,
            activeOperations: activeOperations,
            maximumActiveOperations: maximumActiveOperations
        )
    }

    private func enqueueBootstrap(
        waiterID: UUID,
        continuation: CheckedContinuation<BootstrapOutcome, any Error>,
        publication: Publication?
    ) {
        recordEnqueueInvocation()
        if let operationID = pendingBootstrapID {
            bootstrapWaiters[operationID, default: []].append(
                BootstrapWaiter(
                    id: waiterID,
                    continuation: continuation,
                    publication: publication
                )
            )
            return
        }

        let operationID = UUID()
        pendingBootstrapID = operationID
        bootstrapWaiters[operationID] = [
            BootstrapWaiter(
                id: waiterID,
                continuation: continuation,
                publication: publication
            )
        ]
        queue.append(.bootstrap(id: operationID))
        startPumpIfNeeded()
    }

    private func enqueueVoid(
        operation: Operation,
        waiterID: UUID,
        continuation: CheckedContinuation<Void, any Error>,
        publication: Publication?
    ) {
        recordEnqueueInvocation()
        voidWaiters[operation.id] = VoidWaiter(
            id: waiterID,
            continuation: continuation,
            publication: publication
        )
        queue.append(operation)
        startPumpIfNeeded()
    }

    private func startPumpIfNeeded() {
        guard !pumpRunning else { return }
        pumpRunning = true
        Task { await pump() }
    }

    private func pump() async {
        while !queue.isEmpty {
            let operation = queue.removeFirst()
            activeOperationID = operation.id
            startedOperations += 1
            activeOperations += 1
            maximumActiveOperations = max(maximumActiveOperations, activeOperations)

            switch operation {
            case .bootstrap(let id):
                let execution = await performBootstrap()
                pendingBootstrapID = nil
                await publishBootstrapResult(execution.publication, operationID: id)
                let waiters = bootstrapWaiters.removeValue(forKey: id) ?? []
                for waiter in waiters {
                    waiter.continuation.resume(returning: execution.outcome)
                }
            case .persist(let id, let token):
                let result: Result<Void, any Error>
                do {
                    try await performPersist(token: token)
                    result = .success(())
                } catch {
                    result = .failure(error)
                }
                await finishVoid(id: id, result: result, publicationValue: token)
            case .logout(let id):
                activeLogoutID = id
                let result: Result<Void, any Error>
                do {
                    try await performLogout()
                    result = .success(())
                } catch {
                    result = .failure(error)
                }
                await finishVoid(id: id, result: result, publicationValue: nil)
                activeLogoutID = nil
            }

            activeOperationID = nil
            activeOperations -= 1
        }
        pumpRunning = false
    }

    private func finishVoid(
        id: UUID,
        result: Result<Void, any Error>,
        publicationValue: String?
    ) async {
        if case .success = result,
           let waiter = voidWaiters[id],
           !waiter.suppressPublication,
           let publication = waiter.publication {
            await publication(publicationValue)
        }
        guard let waiter = voidWaiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(with: result)
    }

    private func publishBootstrapResult(
        _ decision: PublicationDecision,
        operationID: UUID
    ) async {
        guard case .publish(let token) = decision else { return }
        let waiterIDs = bootstrapWaiters[operationID]?.map(\.id) ?? []
        for waiterID in waiterIDs {
            guard let waiter = bootstrapWaiters[operationID]?.first(where: { $0.id == waiterID }),
                  !waiter.suppressPublication,
                  let publication = waiter.publication else { continue }
            await publication(token)
        }
    }

    private func performBootstrap() async -> BootstrapExecution {
        if bootstrapState == .ready || bootstrapState == .conflict || bootstrapState == .permanentFailure {
            let publication: PublicationDecision = bootstrapState == .ready || bootstrapState == .conflict
                ? .publish(authoritativeToken)
                : .none
            return BootstrapExecution(
                outcome: BootstrapOutcome(state: bootstrapState, token: authoritativeToken),
                publication: publication
            )
        }

        if let pendingRepairToken {
            return await performPendingRepair(token: pendingRepairToken)
        }

        do {
            let secureToken = try await secureStore.token(for: Self.providerID)
            let legacyToken = await legacyStore.token()

            if let secureToken {
                if let legacyToken {
                    if legacyToken == secureToken {
                        do {
                            try await removeLegacyToken()
                        } catch {
                            markPendingRepair(token: secureToken, error: error)
                            return unpublishedBootstrapOutcome()
                        }
                    } else {
                        authoritativeToken = secureToken
                        bootstrapState = .conflict
                        return BootstrapExecution(
                            outcome: BootstrapOutcome(state: .conflict, token: secureToken),
                            publication: .publish(secureToken)
                        )
                    }
                }

                authoritativeToken = secureToken
                bootstrapState = .ready
                return BootstrapExecution(
                    outcome: BootstrapOutcome(state: .ready, token: secureToken),
                    publication: .publish(secureToken)
                )
            }

            guard let legacyToken else {
                authoritativeToken = nil
                bootstrapState = .ready
                return BootstrapExecution(
                    outcome: BootstrapOutcome(state: .ready, token: nil),
                    publication: .publish(nil)
                )
            }

            try await secureStore.setToken(legacyToken, for: Self.providerID)
            do {
                try await verifySecureTokenAndCleanupLegacy(legacyToken)
            } catch {
                markPendingRepair(token: legacyToken, error: error)
                return unpublishedBootstrapOutcome()
            }
            authoritativeToken = legacyToken
            pendingRepairToken = nil
            bootstrapState = .ready
            return BootstrapExecution(
                outcome: BootstrapOutcome(state: .ready, token: legacyToken),
                publication: .publish(legacyToken)
            )
        } catch let error as TrackerCredentialStoreError {
            bootstrapState = error.isProtectedDataUnavailable
                ? .retryableProtectedDataFailure
                : .permanentFailure
        } catch {
            bootstrapState = .permanentFailure
        }

        return BootstrapExecution(
            outcome: BootstrapOutcome(state: bootstrapState, token: authoritativeToken),
            publication: .none
        )
    }

    private func performPersist(token: String) async throws {
        do {
            try await secureStore.setToken(token, for: Self.providerID)
        } catch let error as TrackerCredentialStoreError {
            throw RepositoryError.storage(error)
        }

        do {
            try await verifySecureTokenAndCleanupLegacy(token)
        } catch let error as TrackerCredentialStoreError {
            markPendingRepair(token: token, error: error)
            throw RepositoryError.storage(error)
        } catch {
            markPendingRepair(token: token, error: error)
            throw error
        }

        authoritativeToken = token
        pendingRepairToken = nil
        bootstrapState = .ready
    }

    private func performLogout() async throws {
        do {
            try await secureStore.removeToken(for: Self.providerID)
            try await removeLegacyToken()
        } catch let error as TrackerCredentialStoreError {
            throw RepositoryError.storage(error)
        }

        authoritativeToken = nil
        pendingRepairToken = nil
        bootstrapState = .ready
    }

    private func performPendingRepair(token: String) async -> BootstrapExecution {
        do {
            try await verifySecureTokenAndCleanupLegacy(token)
        } catch {
            markPendingRepair(token: token, error: error)
            return unpublishedBootstrapOutcome()
        }

        authoritativeToken = token
        pendingRepairToken = nil
        bootstrapState = .ready
        return BootstrapExecution(
            outcome: BootstrapOutcome(state: .ready, token: token),
            publication: .publish(token)
        )
    }

    private func verifySecureTokenAndCleanupLegacy(_ token: String) async throws {
        guard try await secureStore.token(for: Self.providerID) == token else {
            throw RepositoryError.verificationFailed
        }
        try await removeLegacyToken()
    }

    private func markPendingRepair(token: String, error: any Error) {
        pendingRepairToken = token
        bootstrapState = if let storageError = error as? TrackerCredentialStoreError,
                            storageError.isProtectedDataUnavailable {
            .retryableProtectedDataFailure
        } else {
            .recoverableVerificationFailure
        }
    }

    private func unpublishedBootstrapOutcome() -> BootstrapExecution {
        BootstrapExecution(
            outcome: BootstrapOutcome(state: bootstrapState, token: authoritativeToken),
            publication: .none
        )
    }

    private func removeLegacyToken() async throws {
        do {
            try await legacyStore.removeToken()
            guard await legacyStore.token() == nil else {
                throw RepositoryError.legacyCleanupFailed
            }
        } catch {
            throw RepositoryError.legacyCleanupFailed
        }
    }

    private func cancel(waiterID: UUID) {
        for (operationID, waiters) in bootstrapWaiters {
            guard let index = waiters.firstIndex(where: { $0.id == waiterID }) else { continue }
            if activeOperationID == operationID {
                var updated = waiters
                updated[index].suppressPublication = true
                bootstrapWaiters[operationID] = updated
                return
            }

            var remaining = waiters
            let waiter = remaining.remove(at: index)
            bootstrapWaiters[operationID] = remaining
            waiter.continuation.resume(throwing: CancellationError())
            if remaining.isEmpty {
                bootstrapWaiters.removeValue(forKey: operationID)
                queue.removeAll { $0.id == operationID }
                if pendingBootstrapID == operationID {
                    pendingBootstrapID = nil
                }
            }
            return
        }

        guard let entry = voidWaiters.first(where: { $0.value.id == waiterID }) else { return }
        let operationID = entry.key
        if activeOperationID == operationID {
            if activeLogoutID == operationID {
                return
            }
            var waiter = entry.value
            waiter.suppressPublication = true
            voidWaiters[operationID] = waiter
            return
        }
        queue.removeAll { $0.id == operationID }
        let waiter = voidWaiters.removeValue(forKey: operationID)
        waiter?.continuation.resume(throwing: CancellationError())
    }

    private func recordEnqueueInvocation() {
        enqueuedInvocations += 1
        let ready = enqueueWaiters.filter { $0.count <= enqueuedInvocations }
        enqueueWaiters.removeAll { $0.count <= enqueuedInvocations }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}

private extension TrackerCredentialStoreError {
    var isProtectedDataUnavailable: Bool {
        if case .protectedDataUnavailable = self { return true }
        return false
    }
}

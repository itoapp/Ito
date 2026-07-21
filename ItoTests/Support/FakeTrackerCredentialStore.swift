import Foundation
@testable import Ito

final class CredentialTestJournal: @unchecked Sendable {
    nonisolated enum Event: Equatable, Sendable {
        case secureRead
        case secureSet
        case secureRemove
        case legacyRead
        case legacyRemove
        case publication
    }

    private let lock = NSLock()
    private var events: [Event] = []

    func record(_ event: Event) {
        lock.withLock { events.append(event) }
    }

    func snapshot() -> [Event] {
        lock.withLock { events }
    }
}

final class CredentialPublicationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedTokens: [String?] = []

    func record(_ token: String?) {
        lock.withLock { recordedTokens.append(token) }
    }

    var count: Int {
        lock.withLock { recordedTokens.count }
    }

    var lastToken: String? {
        lock.withLock { recordedTokens.last ?? nil }
    }
}

actor AsyncTestGate {
    private var isOpen: Bool
    private var admissions = 0
    private var blocked: [CheckedContinuation<Void, Never>] = []
    private var admissionWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(open: Bool = false) {
        self.isOpen = open
    }

    func enter() async {
        admissions += 1
        let ready = admissionWaiters.filter { $0.count <= admissions }
        admissionWaiters.removeAll { $0.count <= admissions }
        for waiter in ready {
            waiter.continuation.resume()
        }

        guard !isOpen else { return }
        await withCheckedContinuation { blocked.append($0) }
    }

    func waitForAdmissions(_ count: Int = 1) async {
        guard admissions < count else { return }
        await withCheckedContinuation { admissionWaiters.append((count, $0)) }
    }

    func open() {
        isOpen = true
        let continuations = blocked
        blocked.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}

actor FakeTrackerCredentialStore: TrackerCredentialStoring {
    nonisolated enum Operation: Equatable, Sendable {
        case read(providerID: String)
        case set(providerID: String)
        case remove(providerID: String)
    }

    private var storedToken: String?
    private var readResults: [Result<String?, TrackerCredentialStoreError>]
    private var setResults: [Result<Void, TrackerCredentialStoreError>]
    private var removeResults: [Result<Void, TrackerCredentialStoreError>]
    private var readGates: [AsyncTestGate?]
    private var setGates: [AsyncTestGate?]
    private var removeGates: [AsyncTestGate?]
    private var operations: [Operation] = []
    private var activeOperations = 0
    private var maximumActiveOperations = 0
    private let journal: CredentialTestJournal?

    init(
        initialToken: String? = nil,
        readResults: [Result<String?, TrackerCredentialStoreError>] = [],
        setResults: [Result<Void, TrackerCredentialStoreError>] = [],
        removeResults: [Result<Void, TrackerCredentialStoreError>] = [],
        readGates: [AsyncTestGate?] = [],
        setGates: [AsyncTestGate?] = [],
        removeGates: [AsyncTestGate?] = [],
        journal: CredentialTestJournal? = nil
    ) {
        self.storedToken = initialToken
        self.readResults = readResults
        self.setResults = setResults
        self.removeResults = removeResults
        self.readGates = readGates
        self.setGates = setGates
        self.removeGates = removeGates
        self.journal = journal
    }

    func token(for providerID: String) async throws -> String? {
        begin(.read(providerID: providerID))
        defer { end() }
        journal?.record(.secureRead)
        let gate = readGates.isEmpty ? nil : readGates.removeFirst()
        let result = readResults.isEmpty ? nil : readResults.removeFirst()
        await gate?.enter()
        return try result?.get() ?? storedToken
    }

    func setToken(_ token: String, for providerID: String) async throws {
        begin(.set(providerID: providerID))
        defer { end() }
        journal?.record(.secureSet)
        let gate = setGates.isEmpty ? nil : setGates.removeFirst()
        let result = setResults.isEmpty ? Result<Void, TrackerCredentialStoreError>.success(()) : setResults.removeFirst()
        await gate?.enter()
        try result.get()
        storedToken = token
    }

    func removeToken(for providerID: String) async throws {
        begin(.remove(providerID: providerID))
        defer { end() }
        journal?.record(.secureRemove)
        let gate = removeGates.isEmpty ? nil : removeGates.removeFirst()
        let result = removeResults.isEmpty ? Result<Void, TrackerCredentialStoreError>.success(()) : removeResults.removeFirst()
        await gate?.enter()
        try result.get()
        storedToken = nil
    }

    func recordedOperations() -> [Operation] {
        operations
    }

    func metrics() -> (active: Int, maximum: Int) {
        (activeOperations, maximumActiveOperations)
    }

    func currentToken() -> String? {
        storedToken
    }

    private func begin(_ operation: Operation) {
        operations.append(operation)
        activeOperations += 1
        maximumActiveOperations = max(maximumActiveOperations, activeOperations)
    }

    private func end() {
        activeOperations -= 1
    }
}

actor FakeLegacyTokenStore: LegacyTokenStoring {
    nonisolated enum Operation: Equatable, Sendable {
        case read
        case remove
    }

    nonisolated struct Failure: Error, LocalizedError, Sendable {
        let errorDescription: String?
    }

    private var storedToken: String?
    private var removalResults: [Result<Void, Failure>]
    private var stickyRemovalResults: [Bool]
    private var readGates: [AsyncTestGate?]
    private var removalGates: [AsyncTestGate?]
    private var operations: [Operation] = []
    private let journal: CredentialTestJournal?

    init(
        token: String? = nil,
        removalResults: [Result<Void, Failure>] = [],
        stickyRemovalResults: [Bool] = [],
        readGates: [AsyncTestGate?] = [],
        removalGates: [AsyncTestGate?] = [],
        journal: CredentialTestJournal? = nil
    ) {
        self.storedToken = token
        self.removalResults = removalResults
        self.stickyRemovalResults = stickyRemovalResults
        self.readGates = readGates
        self.removalGates = removalGates
        self.journal = journal
    }

    func token() async -> String? {
        operations.append(.read)
        journal?.record(.legacyRead)
        let gate = readGates.isEmpty ? nil : readGates.removeFirst()
        await gate?.enter()
        return storedToken
    }

    func removeToken() async throws {
        operations.append(.remove)
        journal?.record(.legacyRemove)
        let gate = removalGates.isEmpty ? nil : removalGates.removeFirst()
        let result = removalResults.isEmpty ? Result<Void, Failure>.success(()) : removalResults.removeFirst()
        let isSticky = stickyRemovalResults.isEmpty ? false : stickyRemovalResults.removeFirst()
        await gate?.enter()
        try result.get()
        if !isSticky {
            storedToken = nil
        }
    }

    func recordedOperations() -> [Operation] {
        operations
    }

    func currentToken() -> String? {
        storedToken
    }
}

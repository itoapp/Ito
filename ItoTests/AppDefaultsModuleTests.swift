import Combine
import Foundation
import Testing
@testable import Ito

@MainActor
struct AppDefaultsModuleTests {
    @Test func moduleAndAlreadyObservingStoreShareSynchronousRows() throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let store = PluginSettingsStore(
            dbPool: database.dbPool,
            domainFactory: { EmptyPluginDomain(name: $0) }
        )
        let module = AppDefaultsModule(pluginId: "plugin", store: store)
        var observedRevisions: [Int] = []
        let observation = store.$revision.dropFirst().sink {
            observedRevisions.append($0)
        }
        defer { observation.cancel() }

        module.set(key: "mode", value: "reader")

        #expect(module.get(key: "mode") == "reader")
        #expect(store.get(pluginId: "plugin", key: "mode") == "reader")
        #expect(observedRevisions.count == 1)
        module.remove(key: "mode")
        #expect(module.get(key: "mode") == nil)
        #expect(observedRevisions.count == 2)
    }

    @Test func failedVoidABIWriteCannotExposeFalseHostSuccess() throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let faults = ModuleOperationFault()
        let store = PluginSettingsStore(
            dbPool: database.dbPool,
            domainFactory: { EmptyPluginDomain(name: $0) },
            operationFault: faults.hit
        )
        let module = AppDefaultsModule(pluginId: "plugin", store: store)
        module.set(key: "key", value: "committed")
        faults.failNext("set")

        module.set(key: "key", value: "uncommitted")

        #expect(module.get(key: "key") == "committed")
        #expect(store.get(pluginId: "plugin", key: "key") == "committed")
        #expect(store.lastPersistenceError?.operation == "set")
    }

    @Test func moduleRemoveIsSynchronous() throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let store = PluginSettingsStore(
            dbPool: database.dbPool,
            domainFactory: { EmptyPluginDomain(name: $0) }
        )
        let module = AppDefaultsModule(pluginId: "plugin", store: store)
        module.set(key: "key", value: "value")

        module.remove(key: "key")

        #expect(module.get(key: "key") == nil)
    }
}

private final class EmptyPluginDomain: LegacyDefaultsDomain, @unchecked Sendable {
    let domainName: String

    init(name: String) {
        domainName = name
    }

    func persistentDomain() -> [String: Any] { [:] }
    func removeObject(forKey key: String) {}
}

private final class ModuleOperationFault: @unchecked Sendable {
    private let lock = NSLock()
    private var operation: String?

    func failNext(_ operation: String) {
        lock.withLock { self.operation = operation }
    }

    func hit(_ operation: String) throws {
        let shouldThrow = lock.withLock {
            guard self.operation == operation else { return false }
            self.operation = nil
            return true
        }
        if shouldThrow { throw ModuleFailure() }
    }
}

private struct ModuleFailure: Error {}

import Combine
import Foundation
import XCTest
import ZIPFoundation
import ito_runner
@testable import Ito

@MainActor
final class PluginSettingsViewModelTests: XCTestCase {
    func testInitialLoadPreparesExactPluginThenReloadsAuthoritativeStore() async throws {
        let store = PR7BSettingsStoreSpy()
        let schema = try pr7bSettingsSchema()
        let viewModel = makeViewModel(schema: schema, store: store)

        await viewModel.loadIfNeeded()

        XCTAssertEqual(store.preparedPluginIDs, ["plugin.manga"])
        XCTAssertEqual(store.reloadCount, 1)
        XCTAssertTrue(viewModel.isPrepared)
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertFalse(viewModel.isReloading)
        XCTAssertNil(viewModel.loadError)
    }

    func testSchemaIsExposedWithoutParallelMutableRowModels() throws {
        let settings: [Setting] = [
            .toggle(id: "toggle", name: "Toggle", summary: nil, defaultValue: true),
            .text(id: "text", name: "Text", summary: "Summary", defaultValue: "value"),
            .picker(
                id: "picker",
                name: "Picker",
                summary: nil,
                options: ["one", "two"],
                defaultValue: "one"
            )
        ]
        let viewModel = makeViewModel(schema: try pr7bSettingsSchema(settings: settings))

        XCTAssertEqual(viewModel.schema.settings.count, 3)
        XCTAssertEqual(viewModel.plugin.id, "plugin.manga")
    }

    func testBindingReadsAuthoritativeStoreAndTracksRevisionPublication() throws {
        let store = PR7BSettingsStoreSpy()
        store.values["theme"] = "dark"
        let viewModel = makeViewModel(schema: try pr7bSettingsSchema(), store: store)

        XCTAssertEqual(viewModel.storedValue(key: "theme"), "dark")
        store.values["theme"] = "light"
        store.revision += 1

        XCTAssertEqual(viewModel.bindingRevision, 1)
        XCTAssertEqual(viewModel.storedValue(key: "theme"), "light")
        XCTAssertEqual(store.reads.map(\.key), ["theme", "theme"])
    }

    func testImmediatePersistenceSuccessWritesOnceAndReloads() async throws {
        let store = PR7BSettingsStoreSpy()
        let viewModel = makeViewModel(schema: try pr7bSettingsSchema(), store: store)

        XCTAssertTrue(viewModel.persistValue(key: "theme", value: "dark"))
        await pr7bWaitUntil { store.reloadCount == 1 }

        XCTAssertEqual(store.writes.map { ($0.pluginID, $0.key, $0.value) }.count, 1)
        XCTAssertEqual(store.writes.first?.pluginID, "plugin.manga")
        XCTAssertEqual(store.writes.first?.key, "theme")
        XCTAssertEqual(store.writes.first?.value, "dark")
        XCTAssertEqual(store.values["theme"], "dark")
        XCTAssertNil(viewModel.persistenceError)
    }

    func testPersistenceFailureKeepsAuthoritativeValueAndPresentsFailure() throws {
        let store = PR7BSettingsStoreSpy()
        store.values["theme"] = "committed"
        store.persistSucceeds = false
        let messages = PR7BMessagePresenterSpy()
        let viewModel = makeViewModel(
            schema: try pr7bSettingsSchema(),
            store: store,
            messages: messages
        )

        XCTAssertFalse(viewModel.persistValue(key: "theme", value: "uncommitted"))

        XCTAssertEqual(store.values["theme"], "committed")
        XCTAssertEqual(viewModel.storedValue(key: "theme"), "committed")
        XCTAssertEqual(viewModel.persistenceError, "The setting could not be saved.")
        XCTAssertEqual(
            messages.messages,
            [.settingsPersistenceFailed(pluginName: "Fixture Source")]
        )
        XCTAssertEqual(store.reloadCount, 0)
    }

    func testPrepareFailureIsVisibleRecoverableAndDoesNotReload() async throws {
        let store = PR7BSettingsStoreSpy()
        store.prepareError = PR7BTestFailure.failed
        let messages = PR7BMessagePresenterSpy()
        let viewModel = makeViewModel(
            schema: try pr7bSettingsSchema(),
            store: store,
            messages: messages
        )

        await viewModel.loadIfNeeded()

        XCTAssertFalse(viewModel.isPrepared)
        XCTAssertEqual(viewModel.loadError, "fixture failure")
        XCTAssertEqual(store.reloadCount, 0)
        XCTAssertEqual(messages.messages, [
            .settingsLoadFailed(pluginName: "Fixture Source", reason: "fixture failure")
        ])

        store.prepareError = nil
        await viewModel.load()
        XCTAssertTrue(viewModel.isPrepared)
        XCTAssertEqual(store.reloadCount, 1)
    }

    func testReloadFailureIsVisibleAndRetryClearsFailure() async throws {
        let store = PR7BSettingsStoreSpy()
        store.reloadResults = [.failure(PR7BTestFailure.failed), .success(())]
        let messages = PR7BMessagePresenterSpy()
        let viewModel = makeViewModel(
            schema: try pr7bSettingsSchema(),
            store: store,
            messages: messages
        )

        await viewModel.reload()
        XCTAssertEqual(viewModel.reloadError, "fixture failure")
        XCTAssertEqual(messages.messages, [
            .settingsReloadFailed(pluginName: "Fixture Source", reason: "fixture failure")
        ])

        await viewModel.reload()
        XCTAssertNil(viewModel.reloadError)
        XCTAssertFalse(viewModel.isReloading)
        XCTAssertEqual(store.reloadCount, 2)
    }

    func testOlderNonCooperativeReloadCannotOverwriteNewerSuccess() async throws {
        let store = PR7BSettingsStoreSpy()
        store.suspendsReload = true
        let viewModel = makeViewModel(schema: try pr7bSettingsSchema(), store: store)

        let old = Task { await viewModel.reload() }
        await pr7bWaitUntil { store.pendingReloadCount == 1 }
        let fresh = Task { await viewModel.reload() }
        await pr7bWaitUntil { store.pendingReloadCount == 2 }

        store.completeReload(at: 0, with: .failure(PR7BTestFailure.failed))
        await old.value
        XCTAssertTrue(viewModel.isReloading)
        XCTAssertNil(viewModel.reloadError)

        store.completeReload(at: 0, with: .success(()))
        await fresh.value
        XCTAssertFalse(viewModel.isReloading)
        XCTAssertNil(viewModel.reloadError)
    }

    func testCancelSuppressesOutstandingReloadCompletion() async throws {
        let store = PR7BSettingsStoreSpy()
        store.suspendsReload = true
        let viewModel = makeViewModel(schema: try pr7bSettingsSchema(), store: store)

        let task = Task { await viewModel.reload() }
        await pr7bWaitUntil { store.pendingReloadCount == 1 }
        viewModel.cancel()
        store.completeReload(with: .failure(PR7BTestFailure.failed))
        await task.value

        XCTAssertFalse(viewModel.isReloading)
        XCTAssertNil(viewModel.reloadError)
    }

    func testImmediateCancelOwnsPersistenceTriggeredReloadBeforeItCanStart() async throws {
        let store = PR7BSettingsStoreSpy()
        store.suspendsReload = true
        let viewModel = makeViewModel(schema: try pr7bSettingsSchema(), store: store)

        XCTAssertTrue(viewModel.persistValue(key: "theme", value: "dark"))
        viewModel.cancel()
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(store.reloadCount, 0)
        XCTAssertFalse(viewModel.isReloading)
        XCTAssertNil(viewModel.reloadError)
    }

    func testDefaultInitializationWritesOnlyWhenAuthoritativeValueIsMissing() throws {
        let store = PR7BSettingsStoreSpy()
        store.values["existing"] = "kept"
        let viewModel = makeViewModel(schema: try pr7bSettingsSchema(), store: store)

        viewModel.ensureDefault(key: "existing", value: "replacement")
        viewModel.ensureDefault(key: "missing", value: "default")

        XCTAssertEqual(store.values["existing"], "kept")
        XCTAssertEqual(store.values["missing"], "default")
        XCTAssertEqual(store.writes.map(\.key), ["missing"])
    }

    func testArchivedDeletionConfirmationNamesExactStablePluginAndDoesNotActEarly() {
        let plugin = pr7bPlugin(id: "archived.exact", name: "Archived Exact", archived: true)
        let files = PR7BFileDeletionSpy()
        let viewModel = makeSourceDeletionViewModel(plugin: plugin, files: files)

        viewModel.requestArchivedPluginDeletion()

        XCTAssertTrue(viewModel.showArchivedPluginDeleteConfirmation)
        XCTAssertEqual(viewModel.plugin.id, "archived.exact")
        XCTAssertEqual(viewModel.plugin.info.name, "Archived Exact")
        XCTAssertEqual(files.snapshotPlugins.map(\.id), [plugin.id])
        XCTAssertTrue(files.stagedSnapshots.isEmpty)
    }

    func testArchivedDeletionSuccessPublishesAndDismissesOnlyAfterDurableCommit() async {
        let files = PR7BFileDeletionSpy()
        let publisher = PR7BPluginStatePublisherSpy()
        publisher.suspends = true
        let viewModel = makeSourceDeletionViewModel(publisher: publisher, files: files)
        viewModel.requestArchivedPluginDeletion()

        let task = Task { await viewModel.confirmArchivedPluginDeletion() }
        await pr7bWaitUntil { publisher.callCount == 1 }
        XCTAssertFalse(viewModel.shouldDismiss)
        XCTAssertEqual(files.transaction.commitCount, 0)

        publisher.complete()
        await task.value
        XCTAssertEqual(files.transaction.commitCount, 1)
        XCTAssertEqual(publisher.publishCount, 1)
        XCTAssertTrue(viewModel.shouldDismiss)
    }

    func testArchivedDeletionFailureDoesNotDismissAndUsesInjectedMessage() async {
        let files = PR7BFileDeletionSpy()
        files.transaction.commitError = PR7BTestFailure.failed
        let messages = PR7BMessagePresenterSpy()
        let viewModel = makeSourceDeletionViewModel(files: files, messages: messages)
        viewModel.requestArchivedPluginDeletion()

        await viewModel.confirmArchivedPluginDeletion()

        XCTAssertFalse(viewModel.shouldDismiss)
        XCTAssertEqual(files.transaction.rollbackCount, 1)
        XCTAssertEqual(messages.messages.count, 1)
        guard case .archivedPluginDeleteFailed(let name, let reason) = messages.messages[0] else {
            return XCTFail("Expected archived delete failure message")
        }
        XCTAssertEqual(name, "Fixture Source")
        XCTAssertEqual(reason, "fixture failure")
    }

    func testDuplicateArchivedDeletionTapIsSuppressed() async {
        let files = PR7BFileDeletionSpy()
        let publisher = PR7BPluginStatePublisherSpy()
        publisher.suspends = true
        let viewModel = makeSourceDeletionViewModel(publisher: publisher, files: files)
        viewModel.requestArchivedPluginDeletion()

        let first = Task { await viewModel.confirmArchivedPluginDeletion() }
        await pr7bWaitUntil { publisher.callCount == 1 }
        await viewModel.confirmArchivedPluginDeletion()

        XCTAssertEqual(files.stagedSnapshots.count, 1)
        XCTAssertEqual(publisher.callCount, 1)
        publisher.complete()
        await first.value
    }

    func testLocalFileDeletionTransactionUsesConfiguredDirectoryAndSupportsRollbackAndCommit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PR7BFileBoundary-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pluginURL = root.appendingPathComponent("fixture.ito")
        let operations = LocalBrowsePluginFileOperations(
            fileManager: .default,
            pluginsDirectory: root
        )

        let plugin = InstalledPlugin(
            url: pluginURL,
            info: PluginInfo(
                id: "fixture",
                name: "Archived Fixture",
                version: "1.0",
                minAppVersion: "1.0",
                type: .manga,
                archived: true
            ),
            iconData: nil
        )
        try makePluginArchive(id: plugin.id, archived: true).write(to: pluginURL)
        let rollbackSnapshot = try operations.snapshotPluginFile(for: plugin)
        let rollbackTransaction = try operations.stagePluginFileDeletion(from: rollbackSnapshot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pluginURL.path))
        try rollbackTransaction.rollback()
        XCTAssertTrue(FileManager.default.fileExists(atPath: pluginURL.path))

        let commitSnapshot = try operations.snapshotPluginFile(for: plugin)
        let commitTransaction = try operations.stagePluginFileDeletion(from: commitSnapshot)
        try commitTransaction.commit()
        XCTAssertFalse(FileManager.default.fileExists(atPath: pluginURL.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testFileSnapshotRejectsReplacementBetweenConfirmationAndDeletion() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PR7BFileReplacement-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pluginURL = root.appendingPathComponent("fixture.ito")
        try makePluginArchive(id: "fixture", archived: true).write(to: pluginURL)
        let plugin = InstalledPlugin(
            url: pluginURL,
            info: PluginInfo(
                id: "fixture",
                name: "Archived Fixture",
                version: "1.0",
                minAppVersion: "1.0",
                type: .manga,
                archived: true
            ),
            iconData: nil
        )
        let operations = LocalBrowsePluginFileOperations(
            fileManager: .default,
            pluginsDirectory: root
        )
        let snapshot = try operations.snapshotPluginFile(for: plugin)
        try makePluginArchive(id: "replacement", archived: true).write(
            to: pluginURL,
            options: .atomic
        )

        XCTAssertThrowsError(try operations.stagePluginFileDeletion(from: snapshot)) { error in
            XCTAssertEqual(
                error as? SourcePluginFileError,
                .stalePluginIdentity
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: pluginURL.path))
    }

    func testArchivedDeletionIntegratesConfiguredFileBoundaryWithPluginManagerPublication() async throws {
        let testDatabase = try TestDatabase()
        defer { testDatabase.cleanup() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PR7BPluginManagerBoundary-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pluginURL = directory.appendingPathComponent("archived.fixture.ito")
        try makePluginArchive(id: "archived.fixture", archived: true).write(to: pluginURL)
        let domains = PR7BPluginDomainCatalog()
        let store = PluginSettingsStore(
            dbPool: testDatabase.dbPool,
            standardApplicationDomain: "test.pr7b",
            domainFactory: domains.domain
        )
        let manager = PluginManager(pluginSettingsStore: store, pluginsDirectory: directory)
        try await manager.discoverAndPrepareInstalledPlugins()
        let plugin = try XCTUnwrap(manager.installedPlugins["archived.fixture"])
        let files = LocalBrowsePluginFileOperations(
            fileManager: .default,
            pluginsDirectory: directory
        )
        let viewModel = SourceViewModel(
            plugin: plugin,
            runnerProvider: PR7BSourceRunnerProviderSpy(),
            pluginStatePublisher: manager,
            fileDeletion: files,
            messagePresenter: PR7BMessagePresenterSpy(),
            searchDebounceNanoseconds: nil
        )
        viewModel.requestArchivedPluginDeletion()

        await viewModel.confirmArchivedPluginDeletion()

        XCTAssertTrue(manager.installedPlugins.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pluginURL.path))
        XCTAssertTrue(viewModel.shouldDismiss)
    }

    func testPluginSettingsViewRemainsSchemaAndBindingDrivenWithNoRowViewModels() throws {
        let viewSource = try sourceFile("Ito/Views/Browse/PluginSettingsView.swift")
        let modelSource = try sourceFile("Ito/ViewModels/PluginSettingsViewModel.swift")

        XCTAssertTrue(viewSource.contains("ForEach(viewModel.schema.settings"))
        XCTAssertTrue(viewSource.contains("Binding("))
        XCTAssertTrue(viewSource.contains("viewModel.storedValue(key:"))
        XCTAssertTrue(viewSource.contains("viewModel.persistValue(key:"))
        XCTAssertFalse(viewSource.contains("@State private var setting"))
        XCTAssertFalse(modelSource.contains("@Published private(set) var settings"))
        XCTAssertFalse(modelSource.contains("[String: String]"))

        for source in [viewSource, modelSource] {
            for forbidden in [
                "PluginManager.shared", "SnackBarManager.shared", "FileManager.default",
                "UserDefaults.standard", "AppLogger", "AnyView", "configure("
            ] {
                XCTAssertFalse(source.contains(forbidden))
            }
        }
    }

    private func makeViewModel(
        schema: SettingsSchema,
        store: PR7BSettingsStoreSpy = PR7BSettingsStoreSpy(),
        messages: PR7BMessagePresenterSpy = PR7BMessagePresenterSpy()
    ) -> PluginSettingsViewModel {
        PluginSettingsViewModel(
            plugin: pr7bPlugin(),
            schema: schema,
            settingsStore: store,
            messagePresenter: messages
        )
    }

    private func makeSourceDeletionViewModel(
        plugin: InstalledPlugin = pr7bPlugin(archived: true),
        publisher: PR7BPluginStatePublisherSpy = PR7BPluginStatePublisherSpy(),
        files: PR7BFileDeletionSpy = PR7BFileDeletionSpy(),
        messages: PR7BMessagePresenterSpy = PR7BMessagePresenterSpy()
    ) -> SourceViewModel {
        publisher.currentPlugins[plugin.id] = plugin
        return SourceViewModel(
            plugin: plugin,
            runnerProvider: PR7BSourceRunnerProviderSpy(),
            pluginStatePublisher: publisher,
            fileDeletion: files,
            messagePresenter: messages,
            searchDebounceNanoseconds: nil
        )
    }

    private func makePluginArchive(id: String, archived: Bool) throws -> Data {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PR7BArchive-\(UUID().uuidString)")
        let archiveURL = directory.appendingPathComponent("fixture.ito")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let archive = try Archive(url: archiveURL, accessMode: .create)
        let manifest = Data(
            """
            {
              "id": "\(id)",
              "name": "Archived Fixture",
              "version": "1.0",
              "min_app_version": "1.0",
              "type": "manga",
              "archived": \(archived)
            }
            """.utf8
        )
        try archive.addEntry(
            with: "manifest.json",
            type: .file,
            uncompressedSize: Int64(manifest.count)
        ) { position, size in
            let start = Int(position)
            return manifest.subdata(in: start..<min(start + size, manifest.count))
        }
        return try Data(contentsOf: archiveURL)
    }

    private func sourceFile(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}

private final class PR7BPluginDomainCatalog: @unchecked Sendable {
    private let lock = NSLock()
    private var domains: [String: PR7BEmptyPluginDomain] = [:]

    func domain(_ name: String) -> any LegacyDefaultsDomain {
        lock.withLock {
            if let domain = domains[name] { return domain }
            let domain = PR7BEmptyPluginDomain(name: name)
            domains[name] = domain
            return domain
        }
    }
}

private final class PR7BEmptyPluginDomain: LegacyDefaultsDomain, @unchecked Sendable {
    let domainName: String

    init(name: String) {
        domainName = name
    }

    func persistentDomain() -> [String: Any] { [:] }
    func removeObject(forKey key: String) { _ = key }
}

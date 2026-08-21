import Combine
import XCTest
@testable import Ito

@MainActor
final class AppScopeIdentityTests: XCTestCase {
    func testRepeatedRootAndTabRecomputationReturnsSameSearchViewModel() {
        let scope = makeScope()

        let first = scope.rootModels.searchViewModel
        _ = scope.viewFactory.makeSearchView()
        let second = scope.viewFactory.rootModels.searchViewModel
        _ = scope.viewFactory.makeSearchView()
        let third = scope.rootModels.searchViewModel

        XCTAssertTrue(first === second)
        XCTAssertTrue(second === third)
    }

    func testNewPreparedRuntimeEpochReceivesNewSearchViewModel() {
        let firstScope = makeScope()
        let secondScope = makeScope()

        XCTAssertFalse(firstScope === secondScope)
        XCTAssertFalse(
            firstScope.rootModels.searchViewModel
                === secondScope.rootModels.searchViewModel
        )
    }

    func testRepeatedRootAndTabRecomputationReturnsSameDiscoverViewModel() {
        let scope = makeScope()

        let first = scope.rootModels.discoverViewModel
        _ = scope.viewFactory.makeDiscoverView()
        let second = scope.viewFactory.rootModels.discoverViewModel
        _ = scope.viewFactory.makeDiscoverView()
        let third = scope.rootModels.discoverViewModel

        XCTAssertTrue(first === second)
        XCTAssertTrue(second === third)
    }

    func testNewPreparedRuntimeEpochReceivesNewDiscoverViewModel() {
        let firstScope = makeScope()
        let secondScope = makeScope()

        XCTAssertFalse(firstScope === secondScope)
        XCTAssertFalse(
            firstScope.rootModels.discoverViewModel
                === secondScope.rootModels.discoverViewModel
        )
    }

    func testSearchDependenciesAndModelAreNotDuplicated() {
        let executor = AppScopeSearchExecutor()
        let store = AppScopeRecentStore()
        let dependencies = PreparedApplicationDependencies(
            settings: makeTestPreparedSettingsDependencies(),
            searchExecutor: executor,
            recentSearchStore: store,
            searchDebounceMilliseconds: nil,
            presentationLogger: PresentationEventCaptureSpy(),
            browseRepositoryManager: AppScopeBrowseRepositoryManager(),
            repositoryManagement: makeTestRepositoryManagementDependencies(),
            browsePluginManager: AppScopeBrowsePluginManager(),
            browseFileOperations: AppScopeBrowseFileOperations()
        )
        let scope = AppScope(preparedDependencies: dependencies)

        XCTAssertFalse(scope.rootModels.hasLoadedSearchViewModel)
        let first = scope.rootModels.searchViewModel
        let second = scope.rootModels.searchViewModel

        XCTAssertTrue(first === second)
        XCTAssertTrue(scope.dependencies.searchExecutor === executor)
        XCTAssertEqual(store.loadCallCount, 1)
    }

    func testSearchConstructionIsLazyWithinPreparedScope() {
        let scope = makeScope()

        XCTAssertFalse(scope.rootModels.hasLoadedSearchViewModel)
        _ = scope.viewFactory.makeSearchView()
        XCTAssertTrue(scope.rootModels.hasLoadedSearchViewModel)
    }

    func testDiscoverDependenciesAndModelAreNotDuplicated() {
        let service = AppScopeDiscoverService()
        let cache = InMemoryDiscoverCache()
        let clock = AppScopeDiscoverClock()
        let dependencies = PreparedApplicationDependencies(
            settings: makeTestPreparedSettingsDependencies(),
            searchExecutor: AppScopeSearchExecutor(),
            recentSearchStore: AppScopeRecentStore(),
            searchDebounceMilliseconds: nil,
            presentationLogger: PresentationEventCaptureSpy(),
            browseRepositoryManager: AppScopeBrowseRepositoryManager(),
            repositoryManagement: makeTestRepositoryManagementDependencies(),
            browsePluginManager: AppScopeBrowsePluginManager(),
            browseFileOperations: AppScopeBrowseFileOperations(),
            discoverService: service,
            discoverCache: cache,
            discoverClock: clock,
            discoverDebounceMilliseconds: nil
        )
        let scope = AppScope(preparedDependencies: dependencies)

        XCTAssertFalse(scope.rootModels.hasLoadedDiscoverViewModel)
        let first = scope.rootModels.discoverViewModel
        let second = scope.rootModels.discoverViewModel

        XCTAssertTrue(first === second)
        XCTAssertTrue(scope.dependencies.discoverService === service)
        XCTAssertTrue(scope.dependencies.discoverCache === cache)
        XCTAssertTrue(scope.dependencies.discoverClock === clock)
    }

    func testDiscoverConstructionIsLazyWithinPreparedScope() {
        let scope = makeScope()

        XCTAssertFalse(scope.rootModels.hasLoadedDiscoverViewModel)
        _ = scope.viewFactory.makeDiscoverView()
        XCTAssertTrue(scope.rootModels.hasLoadedDiscoverViewModel)
    }

    func testSettingsRootFactoryDoesNotEagerlyLoadAnySettingsViewModel() {
        let scope = makeScope()

        XCTAssertFalse(scope.rootModels.hasLoadedAppearanceSettingsViewModel)
        XCTAssertFalse(scope.rootModels.hasLoadedLibrarySettingsViewModel)
        XCTAssertFalse(scope.rootModels.hasLoadedPrivacySettingsViewModel)
        XCTAssertFalse(scope.rootModels.hasLoadedStorageSettingsViewModel)
        XCTAssertFalse(scope.rootModels.hasLoadedDebugLogViewModel)

        _ = scope.viewFactory.makeSettingsView()

        XCTAssertFalse(scope.rootModels.hasLoadedAppearanceSettingsViewModel)
        XCTAssertFalse(scope.rootModels.hasLoadedLibrarySettingsViewModel)
        XCTAssertFalse(scope.rootModels.hasLoadedPrivacySettingsViewModel)
        XCTAssertFalse(scope.rootModels.hasLoadedStorageSettingsViewModel)
        XCTAssertFalse(scope.rootModels.hasLoadedDebugLogViewModel)
    }

    func testAppScopeIsUnavailableBeforeRuntimePreparation() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let bootstrap = DurableStateBootstrap(
            dbPool: database.dbPool,
            migration: {},
            sourceDatabaseURL: database.databaseURL,
            installedPluginsDirectory: database.databaseURL
                .deletingLastPathComponent()
                .appendingPathComponent("Plugins", isDirectory: true)
        )

        XCTAssertNil(bootstrap.appScope)
        let prepared = await bootstrap.prepare()
        XCTAssertTrue(prepared)
        XCTAssertNotNil(bootstrap.appScope)
        XCTAssertFalse(try XCTUnwrap(bootstrap.appScope).rootModels.hasLoadedSearchViewModel)
        XCTAssertFalse(try XCTUnwrap(bootstrap.appScope).rootModels.hasLoadedDiscoverViewModel)
    }

    func testUnmigratedTabsAndEnvironmentObjectFanOutRemainUnchanged() throws {
        let appSource = try sourceFile("Ito/ItoApp.swift")
        let tabSource = try sourceFile("Ito/Views/MainTabView.swift")
        let environmentObjects = [
            "progressManager",
            "trackerManager",
            "updateManager",
            "repoManager",
            "pluginResolver",
            "settingsStore",
            "libraryManager",
            "pluginManager",
            "storageManager",
            "discordRPCManager",
            "historyManager",
            "notificationManager",
            "backupManager",
            "librarySourceRemapper"
        ]

        for environmentObject in environmentObjects {
            XCTAssertTrue(
                appSource.contains(".environmentObject(\(environmentObject))"),
                "Missing legacy environment object: \(environmentObject)"
            )
        }
        for unmigratedTab in [
            "LibraryView()",
            "appScope.viewFactory.makeSettingsView()"
        ] {
            XCTAssertTrue(tabSource.contains(unmigratedTab))
        }
        XCTAssertTrue(tabSource.contains("appScope.viewFactory.makeBrowseView()"))
        XCTAssertTrue(tabSource.contains("appScope.viewFactory.makeDiscoverView()"))
    }

    func testUITestFixtureStorageAndDefaultsAreIsolatedFromProduction() throws {
        let appSupportURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let productionDatabaseURL = appSupportURL.appendingPathComponent(
            UITestLaunchConfiguration.productionDatabaseDirectoryName,
            isDirectory: true
        )
        let fixtureDatabaseURL = try UITestLaunchConfiguration.fixtureRootURL()
            .appendingPathComponent(
                UITestLaunchConfiguration.fixtureDatabaseDirectoryName,
                isDirectory: true
            )

        XCTAssertNotEqual(
            productionDatabaseURL.standardizedFileURL,
            fixtureDatabaseURL.standardizedFileURL
        )
        XCTAssertNotEqual(
            UITestLaunchConfiguration.fixtureDefaultsSuiteName,
            Bundle.main.bundleIdentifier
        )
        XCTAssertNotEqual(
            UITestLaunchConfiguration.fixtureTrackerKeychainService,
            KeychainTrackerCredentialStore.productionService
        )
        XCTAssertTrue(
            UITestLaunchConfiguration(
                resetsStorage: true,
                repositoryDeepLinkEnabled: false,
                backupWipeEnabled: false
            ).isEnabled
        )
    }

    func testPreparedDependenciesUseInjectedDefaultsAndPluginDirectory() throws {
        let database = try TestDatabase()
        defer { database.cleanup() }

        let suiteName = "AppScopeIdentityTests.\(UUID().uuidString)"
        let fixtureDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { fixtureDefaults.removePersistentDomain(forName: suiteName) }
        let recentSearchSentinel = "fixture-\(UUID().uuidString)"
        fixtureDefaults.set(
            [recentSearchSentinel],
            forKey: UserDefaultsRecentSearchStore.key
        )

        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let pluginsDirectory = fixtureRoot.appendingPathComponent(
            "Plugins",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let pluginSettings = PluginSettingsStore(dbPool: database.dbPool)
        let pluginManager = PluginManager(
            pluginSettingsStore: pluginSettings,
            pluginsDirectory: pluginsDirectory
        )
        let repoManager = RepoManager(
            dbPool: database.dbPool,
            pluginManager: pluginManager
        )
        let settingsStore = AppSettingsStore(dbPool: database.dbPool)
        let notificationManager = NotificationManager()
        let storageManager = StorageManager(pluginManager: pluginManager)
        let discordRPCManager = DiscordRPCManager(
            libraryManager: LibraryManager(dbPool: database.dbPool)
        )
        let dependencies = PreparedApplicationDependencies.production(
            pluginManager: pluginManager,
            repoManager: repoManager,
            settingsStore: settingsStore,
            notificationManager: notificationManager,
            storageManager: storageManager,
            discordRPCManager: discordRPCManager,
            recentSearchDefaults: fixtureDefaults,
            browsePluginsDirectory: pluginsDirectory
        )

        XCTAssertTrue(dependencies.settings.settingsStore === settingsStore)
        XCTAssertTrue(dependencies.settings.notificationAuthorization === notificationManager)
        XCTAssertTrue(dependencies.settings.storageAccess === storageManager)
        XCTAssertTrue(dependencies.settings.discordRPCManager === discordRPCManager)
        XCTAssertTrue(dependencies.repositoryManagement.repositoryListManager === repoManager)
        XCTAssertTrue(dependencies.repositoryManagement.repositoryDetailManager === repoManager)
        XCTAssertEqual(dependencies.recentSearchStore.load(), [recentSearchSentinel])
        let fileOperations = try XCTUnwrap(
            dependencies.browseFileOperations as? LocalBrowsePluginFileOperations
        )
        XCTAssertEqual(
            fileOperations.configuredPluginsDirectory?.standardizedFileURL,
            pluginsDirectory.standardizedFileURL
        )

        let sourceURL = fixtureRoot.appendingPathComponent("fixture.ito")
        try FileManager.default.createDirectory(
            at: fixtureRoot,
            withIntermediateDirectories: true
        )
        try Data("fixture".utf8).write(to: sourceURL)
        try fileOperations.installPluginFile(from: sourceURL)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: pluginsDirectory.appendingPathComponent("fixture.ito").path
            )
        )
    }

    private func makeScope() -> AppScope {
        AppScope(
            preparedDependencies: PreparedApplicationDependencies(
                settings: makeTestPreparedSettingsDependencies(),
                searchExecutor: AppScopeSearchExecutor(),
                recentSearchStore: AppScopeRecentStore(),
                searchDebounceMilliseconds: nil,
                presentationLogger: PresentationEventCaptureSpy(),
                browseRepositoryManager: AppScopeBrowseRepositoryManager(),
                repositoryManagement: makeTestRepositoryManagementDependencies(),
                browsePluginManager: AppScopeBrowsePluginManager(),
                browseFileOperations: AppScopeBrowseFileOperations()
            )
        )
    }

    private func sourceFile(_ path: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(path),
            encoding: .utf8
        )
    }
}

@MainActor
private final class AppScopeSearchExecutor: SearchPluginExecuting {
    let plugins: [SearchPluginDescriptor] = []

    func search(
        plugin: SearchPluginDescriptor,
        query: String,
        limit: Int
    ) async throws -> [PluginSearchResult] {
        _ = plugin
        _ = query
        _ = limit
        return []
    }

    func evictRunner(for pluginID: String) {
        _ = pluginID
    }
}

@MainActor
private final class AppScopeRecentStore: RecentSearchPersisting {
    private(set) var loadCallCount = 0

    func load() -> [String] {
        loadCallCount += 1
        return []
    }

    func save(_ searches: [String]) {
        _ = searches
    }

    func clear() {}
}

@MainActor
private final class AppScopeBrowsePluginManager: BrowsePluginManaging {
    let installedPlugins: [String: InstalledPlugin] = [:]

    var installedPluginsPublisher: AnyPublisher<[String: InstalledPlugin], Never> {
        Just(installedPlugins).eraseToAnyPublisher()
    }

    func reloadInstalledPlugins() async {}
}

@MainActor
private final class AppScopeBrowseRepositoryManager: BrowseRepositoryManaging {
    let repositories: [Repository] = []

    var repositoriesPublisher: AnyPublisher<[Repository], Never> {
        Just(repositories).eraseToAnyPublisher()
    }

    func addRepository(url: String) async throws -> RepositoryAdditionResult {
        _ = url
        return .added
    }

    func installPackage(_ package: RepoPackage, repositoryURL: String) async throws {
        _ = package
        _ = repositoryURL
    }

    func refreshAll() async {}
}

@MainActor
private final class AppScopeBrowseFileOperations: BrowsePluginFileOperating {
    func supportsPluginFile(at url: URL) -> Bool {
        url.pathExtension == "ito"
    }

    func installPluginFile(from url: URL) throws {
        _ = url
    }

    func deletePluginFile(at url: URL) throws {
        _ = url
    }
}

@MainActor
private final class AppScopeDiscoverService: DiscoverHomeFilterServing {
    func loadHomeSection(
        _ request: DiscoverHomeSectionRequest
    ) async throws -> [DiscoverMedia] {
        _ = request
        return []
    }

    func search(_ request: DiscoverSearchRequest) async throws -> DiscoverPageResult {
        _ = request
        return DiscoverPageResult(media: [], hasNextPage: false)
    }

    func loadGenres() async throws -> [String] { [] }
    func loadTags() async throws -> [DiscoverTag] { [] }
}

@MainActor
private final class AppScopeDiscoverClock: DiscoverClock {
    let now = Date(timeIntervalSince1970: 0)

    func sleep(milliseconds: Int) async throws {
        _ = milliseconds
    }
}

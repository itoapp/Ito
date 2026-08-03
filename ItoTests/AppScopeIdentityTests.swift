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

    func testSearchDependenciesAndModelAreNotDuplicated() {
        let executor = AppScopeSearchExecutor()
        let store = AppScopeRecentStore()
        let dependencies = PreparedApplicationDependencies(
            searchExecutor: executor,
            recentSearchStore: store,
            searchDebounceMilliseconds: nil,
            presentationLogger: PresentationEventCaptureSpy(),
            browseRepositoryManager: AppScopeBrowseRepositoryManager(),
            browsePluginManager: AppScopeBrowsePluginManager(),
            browseFileOperations: AppScopeBrowseFileOperations(),
            browseMessagePresenter: AppScopeBrowseMessagePresenter()
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
            "DiscoverView()",
            "SettingsView()"
        ] {
            XCTAssertTrue(tabSource.contains(unmigratedTab))
        }
        XCTAssertTrue(tabSource.contains("appScope.viewFactory.makeBrowseView()"))
    }

    private func makeScope() -> AppScope {
        AppScope(
            preparedDependencies: PreparedApplicationDependencies(
                searchExecutor: AppScopeSearchExecutor(),
                recentSearchStore: AppScopeRecentStore(),
                searchDebounceMilliseconds: nil,
                presentationLogger: PresentationEventCaptureSpy(),
                browseRepositoryManager: AppScopeBrowseRepositoryManager(),
                browsePluginManager: AppScopeBrowsePluginManager(),
                browseFileOperations: AppScopeBrowseFileOperations(),
                browseMessagePresenter: AppScopeBrowseMessagePresenter()
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
private final class AppScopeBrowseMessagePresenter: BrowseMessagePresenting {
    func present(_ message: BrowseMessage) {
        _ = message
    }
}

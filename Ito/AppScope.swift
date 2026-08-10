import Foundation

@MainActor
struct PreparedApplicationDependencies {
    let searchExecutor: any SearchPluginExecuting
    let recentSearchStore: any RecentSearchPersisting
    let searchDebounceMilliseconds: Int?
    let presentationLogger: any PresentationEventLogging
    let browseRepositoryManager: any BrowseRepositoryManaging
    let browsePluginManager: any BrowsePluginManaging
    let browseFileOperations: any BrowsePluginFileOperating
    let discoverService: any DiscoverHomeFilterServing
    let discoverCache: any DiscoverCaching
    let discoverClock: any DiscoverClock
    let discoverDebounceMilliseconds: Int?

    init(
        searchExecutor: any SearchPluginExecuting,
        recentSearchStore: any RecentSearchPersisting,
        searchDebounceMilliseconds: Int?,
        presentationLogger: any PresentationEventLogging,
        browseRepositoryManager: any BrowseRepositoryManaging,
        browsePluginManager: any BrowsePluginManaging,
        browseFileOperations: any BrowsePluginFileOperating,
        discoverService: any DiscoverHomeFilterServing = DiscoverManager.shared,
        discoverCache: any DiscoverCaching = InMemoryDiscoverCache(),
        discoverClock: any DiscoverClock = SystemDiscoverClock(),
        discoverDebounceMilliseconds: Int? = DiscoverViewModel.productionDebounceMilliseconds
    ) {
        self.searchExecutor = searchExecutor
        self.recentSearchStore = recentSearchStore
        self.searchDebounceMilliseconds = searchDebounceMilliseconds
        self.presentationLogger = presentationLogger
        self.browseRepositoryManager = browseRepositoryManager
        self.browsePluginManager = browsePluginManager
        self.browseFileOperations = browseFileOperations
        self.discoverService = discoverService
        self.discoverCache = discoverCache
        self.discoverClock = discoverClock
        self.discoverDebounceMilliseconds = discoverDebounceMilliseconds
    }

    static func production(
        pluginManager: PluginManager,
        repoManager: RepoManager,
        recentSearchDefaults: UserDefaults = .standard,
        browsePluginsDirectory: URL? = nil
    ) -> Self {
        Self(
            searchExecutor: PluginManagerSearchExecutor(pluginManager: pluginManager),
            recentSearchStore: UserDefaultsRecentSearchStore(defaults: recentSearchDefaults),
            searchDebounceMilliseconds: SearchViewModel.automaticSearchDebounceMilliseconds,
            presentationLogger: OSLogPresentationEventLogger(),
            browseRepositoryManager: repoManager,
            browsePluginManager: pluginManager,
            browseFileOperations: LocalBrowsePluginFileOperations(
                pluginsDirectory: browsePluginsDirectory
            )
        )
    }
}

@MainActor
final class RootModelStore {
    private let makeSearchViewModel: () -> SearchViewModel
    private let makeBrowseViewModel: () -> BrowseViewModel
    private let makeDiscoverViewModel: () -> DiscoverViewModel
    private var storedSearchViewModel: SearchViewModel?
    private var storedBrowseViewModel: BrowseViewModel?
    private var storedDiscoverViewModel: DiscoverViewModel?

    init(
        preparedDependencies: PreparedApplicationDependencies,
        repositoryIntentRouter: any BrowseRepositoryIntentRouting,
        browseMessagePresenter: any BrowseMessagePresenting
    ) {
        makeSearchViewModel = {
            SearchViewModel(
                searchExecutor: preparedDependencies.searchExecutor,
                recentSearchStore: preparedDependencies.recentSearchStore,
                debounceMilliseconds: preparedDependencies.searchDebounceMilliseconds,
                presentationLogger: preparedDependencies.presentationLogger
            )
        }
        makeBrowseViewModel = {
            BrowseViewModel(
                repositoryManager: preparedDependencies.browseRepositoryManager,
                pluginManager: preparedDependencies.browsePluginManager,
                fileOperations: preparedDependencies.browseFileOperations,
                messagePresenter: browseMessagePresenter,
                repositoryIntentRouter: repositoryIntentRouter
            )
        }
        makeDiscoverViewModel = {
            DiscoverViewModel(
                service: preparedDependencies.discoverService,
                cache: preparedDependencies.discoverCache,
                clock: preparedDependencies.discoverClock,
                debounceMilliseconds: preparedDependencies.discoverDebounceMilliseconds
            )
        }
    }

    var searchViewModel: SearchViewModel {
        if let storedSearchViewModel { return storedSearchViewModel }
        let viewModel = makeSearchViewModel()
        storedSearchViewModel = viewModel
        return viewModel
    }

    var hasLoadedSearchViewModel: Bool {
        storedSearchViewModel != nil
    }

    var browseViewModel: BrowseViewModel {
        if let storedBrowseViewModel { return storedBrowseViewModel }
        let viewModel = makeBrowseViewModel()
        storedBrowseViewModel = viewModel
        return viewModel
    }

    var hasLoadedBrowseViewModel: Bool {
        storedBrowseViewModel != nil
    }

    var discoverViewModel: DiscoverViewModel {
        if let storedDiscoverViewModel { return storedDiscoverViewModel }
        let viewModel = makeDiscoverViewModel()
        storedDiscoverViewModel = viewModel
        return viewModel
    }

    var hasLoadedDiscoverViewModel: Bool {
        storedDiscoverViewModel != nil
    }
}

@MainActor
final class AppScope {
    let dependencies: PreparedApplicationDependencies
    let rootModels: RootModelStore
    let viewFactory: AppViewFactory
    let router: AppRouter
    let messageCenter: AppMessageCenter

    init(
        preparedDependencies: PreparedApplicationDependencies,
        router: AppRouter = AppRouter(),
        messageCenter: AppMessageCenter = AppMessageCenter()
    ) {
        dependencies = preparedDependencies
        self.router = router
        self.messageCenter = messageCenter
        let rootModels = RootModelStore(
            preparedDependencies: preparedDependencies,
            repositoryIntentRouter: router,
            browseMessagePresenter: AppMessageBrowseMessagePresenter(messageCenter: messageCenter)
        )
        self.rootModels = rootModels
        self.viewFactory = AppViewFactory(rootModels: rootModels)
    }

    static func prepared(
        pluginManager: PluginManager,
        repoManager: RepoManager,
        recentSearchDefaults: UserDefaults = .standard,
        browsePluginsDirectory: URL? = nil
    ) -> AppScope {
        AppScope(
            preparedDependencies: .production(
                pluginManager: pluginManager,
                repoManager: repoManager,
                recentSearchDefaults: recentSearchDefaults,
                browsePluginsDirectory: browsePluginsDirectory
            )
        )
    }
}

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
    let browseMessagePresenter: any BrowseMessagePresenting

    static func production(
        pluginManager: PluginManager,
        repoManager: RepoManager
    ) -> Self {
        Self(
            searchExecutor: PluginManagerSearchExecutor(pluginManager: pluginManager),
            recentSearchStore: UserDefaultsRecentSearchStore(defaults: .standard),
            searchDebounceMilliseconds: SearchViewModel.automaticSearchDebounceMilliseconds,
            presentationLogger: OSLogPresentationEventLogger(),
            browseRepositoryManager: repoManager,
            browsePluginManager: pluginManager,
            browseFileOperations: LocalBrowsePluginFileOperations(),
            browseMessagePresenter: SnackBarBrowseMessagePresenter()
        )
    }
}

@MainActor
final class RootModelStore {
    private let makeSearchViewModel: () -> SearchViewModel
    private let makeBrowseViewModel: () -> BrowseViewModel
    private var storedSearchViewModel: SearchViewModel?
    private var storedBrowseViewModel: BrowseViewModel?

    init(preparedDependencies: PreparedApplicationDependencies) {
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
                messagePresenter: preparedDependencies.browseMessagePresenter
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
}

@MainActor
final class AppScope {
    let dependencies: PreparedApplicationDependencies
    let rootModels: RootModelStore
    let viewFactory: AppViewFactory

    init(preparedDependencies: PreparedApplicationDependencies) {
        dependencies = preparedDependencies
        let rootModels = RootModelStore(preparedDependencies: preparedDependencies)
        self.rootModels = rootModels
        self.viewFactory = AppViewFactory(rootModels: rootModels)
    }

    static func prepared(
        pluginManager: PluginManager,
        repoManager: RepoManager
    ) -> AppScope {
        AppScope(
            preparedDependencies: .production(
                pluginManager: pluginManager,
                repoManager: repoManager
            )
        )
    }
}

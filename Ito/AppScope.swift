import Foundation

@MainActor
struct PreparedApplicationDependencies {
    let searchExecutor: any SearchPluginExecuting
    let recentSearchStore: any RecentSearchPersisting
    let searchDebounceMilliseconds: Int?
    let presentationLogger: any PresentationEventLogging

    static func production(pluginManager: PluginManager) -> Self {
        Self(
            searchExecutor: PluginManagerSearchExecutor(pluginManager: pluginManager),
            recentSearchStore: UserDefaultsRecentSearchStore(defaults: .standard),
            searchDebounceMilliseconds: SearchViewModel.automaticSearchDebounceMilliseconds,
            presentationLogger: OSLogPresentationEventLogger()
        )
    }
}

@MainActor
final class RootModelStore {
    private let makeSearchViewModel: () -> SearchViewModel
    private var storedSearchViewModel: SearchViewModel?

    init(preparedDependencies: PreparedApplicationDependencies) {
        makeSearchViewModel = {
            SearchViewModel(
                searchExecutor: preparedDependencies.searchExecutor,
                recentSearchStore: preparedDependencies.recentSearchStore,
                debounceMilliseconds: preparedDependencies.searchDebounceMilliseconds,
                presentationLogger: preparedDependencies.presentationLogger
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

    static func prepared(pluginManager: PluginManager) -> AppScope {
        AppScope(
            preparedDependencies: .production(pluginManager: pluginManager)
        )
    }
}

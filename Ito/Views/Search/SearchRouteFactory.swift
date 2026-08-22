import SwiftUI
import ito_runner

@MainActor
struct AppViewFactory {
    let rootModels: RootModelStore
    let searchRouteFactory: SearchRouteFactory
    private let repositoryManagement: PreparedRepositoryManagementDependencies
    private let pluginManager: any BrowsePluginManaging
    private let repositoryMessagePresenter: any RepositoryManagementMessagePresenting
    private let sourceDependencies: PreparedSourceDependencies
    private let sourceMessagePresenter: any SourceMessagePresenting

    init(
        rootModels: RootModelStore,
        repositoryManagement: PreparedRepositoryManagementDependencies,
        pluginManager: any BrowsePluginManaging,
        repositoryMessagePresenter: any RepositoryManagementMessagePresenting,
        sourceDependencies: PreparedSourceDependencies,
        sourceMessagePresenter: any SourceMessagePresenting,
        searchRouteFactory: SearchRouteFactory = SearchRouteFactory()
    ) {
        self.rootModels = rootModels
        self.repositoryManagement = repositoryManagement
        self.pluginManager = pluginManager
        self.repositoryMessagePresenter = repositoryMessagePresenter
        self.sourceDependencies = sourceDependencies
        self.sourceMessagePresenter = sourceMessagePresenter
        self.searchRouteFactory = searchRouteFactory
    }

    func makeSearchView() -> SearchView {
        SearchView(
            viewModel: rootModels.searchViewModel,
            routeFactory: searchRouteFactory
        )
    }

    func makeBrowseView() -> BrowseView {
        BrowseView(
            viewModel: rootModels.browseViewModel,
            makeRepositoriesView: makeRepositoriesView,
            makeSourceView: makeSourceView
        )
    }

    func makeSourceView(plugin: InstalledPlugin) -> SourceView {
        SourceView(
            viewModel: makeSourceViewModel(plugin: plugin),
            viewFactory: self
        )
    }

    func makeSourceViewModel(plugin: InstalledPlugin) -> SourceViewModel {
        SourceViewModel(
            plugin: plugin,
            runnerProvider: sourceDependencies.runnerProvider,
            pluginStatePublisher: sourceDependencies.pluginStatePublisher,
            fileDeletion: sourceDependencies.fileDeletion,
            messagePresenter: sourceMessagePresenter
        )
    }

    func makeListingView(destination: SourceListingDestination) -> ListingView {
        ListingView(
            viewModel: makeListingViewModel(destination: destination),
            routeFactory: searchRouteFactory
        )
    }

    func makeListingViewModel(destination: SourceListingDestination) -> ListingViewModel {
        ListingViewModel(destination: destination)
    }

    func makePluginSettingsView(destination: SourceSettingsDestination) -> PluginSettingsView {
        PluginSettingsView(
            viewModel: makePluginSettingsViewModel(destination: destination)
        )
    }

    func makePluginSettingsViewModel(
        destination: SourceSettingsDestination
    ) -> PluginSettingsViewModel {
        PluginSettingsViewModel(
            plugin: destination.plugin,
            schema: destination.schema,
            settingsStore: sourceDependencies.settingsStore,
            messagePresenter: sourceMessagePresenter
        )
    }

    func makeRepositoriesView() -> RepositoriesView {
        RepositoriesView(
            viewModel: RepositoriesViewModel(
                repositoryManager: repositoryManagement.repositoryListManager,
                messagePresenter: repositoryMessagePresenter
            ),
            makeRepoDetailViewModel: makeRepoDetailViewModel
        )
    }

    func makeRepoDetailViewModel(repositoryURL: String) -> RepoDetailViewModel {
        RepoDetailViewModel(
            repositoryURL: repositoryURL,
            repositoryManager: repositoryManagement.repositoryDetailManager,
            pluginManager: pluginManager,
            messagePresenter: repositoryMessagePresenter
        )
    }

    func makeDiscoverView() -> DiscoverView {
        DiscoverView(viewModel: rootModels.discoverViewModel)
    }

    func makeSettingsView() -> SettingsView {
        SettingsView(viewFactory: self)
    }

    @ViewBuilder
    func makeSettingsDestination(for destination: SettingsDestination) -> some View {
        switch destination {
        case .appearance:
            makeAppearanceSettingsView()
        case .library:
            makeLibrarySettingsView()
        case .privacy:
            makePrivacySettingsView()
        case .readerUnavailable:
            Text("Reader Settings View")
        case .storage:
            makeStorageSettingsView()
        case .networkUnavailable:
            Text("Network Settings View")
        case .extensionsUnavailable:
            Text("Manage Extensions View")
        case .debugLogs:
            makeDebugLogView()
        }
    }

    func makeAppearanceSettingsView() -> AppearanceSettingsView {
        AppearanceSettingsView(viewModel: rootModels.appearanceSettingsViewModel)
    }

    func makeLibrarySettingsView() -> LibrarySettingsView {
        LibrarySettingsView(viewModel: rootModels.librarySettingsViewModel)
    }

    func makePrivacySettingsView() -> PrivacySettingsView {
        PrivacySettingsView(viewModel: rootModels.privacySettingsViewModel)
    }

    func makeStorageSettingsView() -> StorageSettingsView {
        StorageSettingsView(viewModel: rootModels.storageSettingsViewModel)
    }

    func makeDebugLogView() -> DebugLogView {
        DebugLogView(viewModel: rootModels.debugLogViewModel)
    }
}

struct SearchRouteFactory {
    func route(for destination: SearchDestination) -> SearchDetailRoute {
        switch destination {
        case .manga(let pluginID, let context, let media):
            return .manga(
                pluginID: pluginID,
                runner: context.runner,
                media: media,
                loader: context.loadManga
            )
        case .anime(let pluginID, let context, let media):
            return .anime(
                pluginID: pluginID,
                runner: context.runner,
                media: media,
                loader: context.loadAnime
            )
        case .novel(let pluginID, let context, let media):
            return .novel(
                pluginID: pluginID,
                runner: context.runner,
                media: media,
                loader: context.loadNovel
            )
        }
    }

    func destination(for destination: SearchDestination) -> some View {
        SearchDestinationHost(route: route(for: destination))
    }
}

enum SearchDetailRoute {
    case manga(
        pluginID: String,
        runner: ItoRunner,
        media: Manga,
        loader: (Manga) async throws -> Manga
    )
    case anime(
        pluginID: String,
        runner: ItoRunner,
        media: Anime,
        loader: (Anime) async throws -> Anime
    )
    case novel(
        pluginID: String,
        runner: ItoRunner,
        media: Novel,
        loader: (Novel) async throws -> Novel
    )
}

private struct SearchDestinationHost: View {
    let route: SearchDetailRoute

    @ViewBuilder
    var body: some View {
        switch route {
        case .manga(let pluginID, let runner, let media, let loader):
            MediaDetailView(
                runner: runner,
                media: media,
                pluginId: pluginID,
                loader: loader
            )
        case .anime(let pluginID, let runner, let media, let loader):
            MediaDetailView(
                runner: runner,
                media: media,
                pluginId: pluginID,
                loader: loader
            )
        case .novel(let pluginID, let runner, let media, let loader):
            MediaDetailView(
                runner: runner,
                media: media,
                pluginId: pluginID,
                loader: loader
            )
        }
    }
}

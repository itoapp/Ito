import SwiftUI
import ito_runner

@MainActor
struct AppViewFactory {
    let rootModels: RootModelStore
    let searchRouteFactory: SearchRouteFactory

    init(
        rootModels: RootModelStore,
        searchRouteFactory: SearchRouteFactory = SearchRouteFactory()
    ) {
        self.rootModels = rootModels
        self.searchRouteFactory = searchRouteFactory
    }

    func makeSearchView() -> SearchView {
        SearchView(
            viewModel: rootModels.searchViewModel,
            routeFactory: searchRouteFactory
        )
    }

    func makeBrowseView() -> BrowseView {
        BrowseView(viewModel: rootModels.browseViewModel)
    }

    func makeDiscoverView() -> DiscoverView {
        DiscoverView(viewModel: rootModels.discoverViewModel)
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

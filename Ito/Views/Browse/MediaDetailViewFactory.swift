import SwiftUI
import ito_runner

@MainActor
struct MediaDetailReaderViewFactory {
    @ViewBuilder
    func destination(for destination: MediaDetailReaderDestination) -> some View {
        switch destination {
        case .manga(_, let runner, let pluginID, let media, let chapter):
            ReaderView(
                runner: runner,
                pluginId: pluginID,
                manga: media,
                currentChapter: chapter
            )
        case .anime(_, let runner, let pluginID, let media, let episode):
            VideoPlayerView(
                runner: runner,
                pluginId: pluginID,
                anime: media,
                episode: episode
            )
        case .novel(_, let runner, let pluginID, let media, let chapter):
            NovelReaderView(
                runner: runner,
                pluginId: pluginID,
                novel: media,
                currentChapter: chapter
            )
        }
    }
}

@MainActor
struct MediaDetailViewFactory {
    private let dependencies: PreparedMediaDetailDependencies
    private let messagePresenter: any MediaDetailMessagePresenting
    private let presentationLogger: any PresentationEventLogging
    let trackingViewFactory: TrackingViewFactory
    let readerViewFactory = MediaDetailReaderViewFactory()

    init(
        dependencies: PreparedMediaDetailDependencies,
        messagePresenter: any MediaDetailMessagePresenting,
        presentationLogger: any PresentationEventLogging,
        trackingViewFactory: TrackingViewFactory
    ) {
        self.dependencies = dependencies
        self.messagePresenter = messagePresenter
        self.presentationLogger = presentationLogger
        self.trackingViewFactory = trackingViewFactory
    }

    func makeMangaView(
        runner: ItoRunner,
        media: Manga,
        pluginID: String,
        loader: @escaping (Manga) async throws -> Manga
    ) -> MediaDetailView<Manga> {
        let context = MediaDetailRouteContext<Manga>(
            loadDetails: loader,
            searchForRelink: { query in
                try await runner.getSearchMangaList(
                    query: query,
                    page: 1,
                    filters: nil
                ).entries
            },
            makeReaderDestination: { media, chapter in
                .manga(
                    id: UUID(),
                    runner: runner,
                    pluginID: pluginID,
                    media: media,
                    chapter: chapter
                )
            }
        )
        return makeView(media: media, pluginID: pluginID, context: context)
    }

    func makeAnimeView(
        runner: ItoRunner,
        media: Anime,
        pluginID: String,
        loader: @escaping (Anime) async throws -> Anime
    ) -> MediaDetailView<Anime> {
        let context = MediaDetailRouteContext<Anime>(
            loadDetails: loader,
            searchForRelink: { query in
                try await runner.getSearchAnimeList(
                    query: query,
                    page: 1,
                    filters: nil
                ).entries
            },
            makeReaderDestination: { media, episode in
                .anime(
                    id: UUID(),
                    runner: runner,
                    pluginID: pluginID,
                    media: media,
                    episode: episode
                )
            }
        )
        return makeView(media: media, pluginID: pluginID, context: context)
    }

    func makeNovelView(
        runner: ItoRunner,
        media: Novel,
        pluginID: String,
        loader: @escaping (Novel) async throws -> Novel
    ) -> MediaDetailView<Novel> {
        let context = MediaDetailRouteContext<Novel>(
            loadDetails: loader,
            searchForRelink: { query in
                try await runner.getSearchNovelList(
                    query: query,
                    page: 1,
                    filters: nil
                ).entries
            },
            makeReaderDestination: { media, chapter in
                .novel(
                    id: UUID(),
                    runner: runner,
                    pluginID: pluginID,
                    media: media,
                    chapter: chapter
                )
            }
        )
        return makeView(media: media, pluginID: pluginID, context: context)
    }

    private func makeView<M: MediaDisplayable>(
        media: M,
        pluginID: String,
        context: MediaDetailRouteContext<M>
    ) -> MediaDetailView<M> {
        MediaDetailView(
            viewModel: MediaDetailViewModel(
                media: media,
                pluginID: pluginID,
                routeContext: context,
                dependencies: dependencies,
                messagePresenter: messagePresenter,
                presentationLogger: presentationLogger
            ),
            trackingViewFactory: trackingViewFactory,
            readerViewFactory: readerViewFactory
        )
    }
}

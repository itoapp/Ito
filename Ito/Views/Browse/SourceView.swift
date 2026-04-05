import SwiftUI
import Nuke
import NukeUI
import ito_runner

struct SourceView: View {
    let plugin: InstalledPlugin

    @State private var runner: ItoRunner?
    @State private var homeLayout: HomeLayout?

    // Fallback states for search
    @State private var searchMangas: [Manga] = []
    @State private var searchAnimes: [Anime] = []
    @State private var searchNovels: [Novel] = []

    @State private var isLoaded = false
    @State private var errorMessage: String?

    @State private var searchQuery: String = ""
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        Group {
            if !isLoaded && errorMessage == nil {
                ProgressView("Loading Source...")
            } else if let error = errorMessage {
                Text("Error: \(error)").foregroundColor(.red)
            } else {
                if let layout = homeLayout, searchQuery.isEmpty {
                    ScrollView {
                        VStack(spacing: 16) {
                            ForEach(layout.components.indices, id: \.self) { index in
                                let component = layout.components[index]
                                Section(header:
                                    HStack {
                                        if let listing = component.value.listing, let runner = runner {
                                            NavigationLink(destination: ListingView(plugin: plugin, runner: runner, listing: listing, title: component.title ?? listing.name)) {
                                                HStack {
                                                    Text(component.title ?? "")
                                                        .font(.title2)
                                                        .fontWeight(.bold)
                                                        .foregroundColor(.primary)
                                                    Image(systemName: "chevron.right")
                                                        .foregroundColor(.secondary)
                                                }
                                            }
                                        } else {
                                            Text(component.title ?? "")
                                                .font(.title2)
                                                .fontWeight(.bold)
                                        }
                                        Spacer()
                                    }
                                    .padding(.horizontal)
                                ) {
                                    renderComponent(component.value)
                                }
                            }
                        }
                        .padding(.vertical)
                    }
                } else {
                    renderSearchList()
                }
            }
        }
        .navigationTitle(plugin.info.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchQuery, prompt: "Search source...")
        .onChange(of: searchQuery) { newValue in
            performSearch(query: newValue)
        }
        .task {
            await loadPlugin()
        }
    }

    @ViewBuilder
    private func renderComponent(_ value: HomeComponentValue) -> some View {
        if let pluginRunner = runner {
            switch value {
            case .scroller(let mangas, _):
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(mangas, id: \.key) { manga in
                            MediaCardView(media: manga) { MediaDetailView(runner: pluginRunner, media: manga, pluginId: plugin.url.deletingPathExtension().lastPathComponent) { try await pluginRunner.getMangaUpdate(manga: $0) } }
                        }
                    }
                    .padding(.horizontal)
                }
            case .mangaList(_, _, let mangas, _):
                VStack {
                    ForEach(mangas, id: \.key) { manga in
                        MediaRowView(media: manga) { MediaDetailView(runner: pluginRunner, media: manga, pluginId: plugin.url.deletingPathExtension().lastPathComponent) { try await pluginRunner.getMangaUpdate(manga: $0) } }
                        Divider().padding(.leading, 72)
                    }
                }
            case .bigScroller(let mangas, _):
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(mangas, id: \.key) { manga in
                            MediaBigCardView(media: manga) { MediaDetailView(runner: pluginRunner, media: manga, pluginId: plugin.url.deletingPathExtension().lastPathComponent) { try await pluginRunner.getMangaUpdate(manga: $0) } }
                        }
                    }
                    .padding(.horizontal)
                }
            case .animeScroller(let animes, _):
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(animes, id: \.key) { anime in
                            MediaCardView(media: anime) { MediaDetailView(runner: pluginRunner, media: anime, pluginId: plugin.url.deletingPathExtension().lastPathComponent) { try await pluginRunner.getAnimeUpdate(anime: $0, needsDetails: true, needsEpisodes: true) } }
                        }
                    }
                    .padding(.horizontal)
                }
            case .animeList(_, _, let animes, _):
                VStack {
                    ForEach(animes, id: \.key) { anime in
                        MediaRowView(media: anime) { MediaDetailView(runner: pluginRunner, media: anime, pluginId: plugin.url.deletingPathExtension().lastPathComponent) { try await pluginRunner.getAnimeUpdate(anime: $0, needsDetails: true, needsEpisodes: true) } }
                        Divider().padding(.leading, 72)
                    }
                }
            case .animeBigScroller(let animes, _):
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(animes, id: \.key) { anime in
                            MediaBigCardView(media: anime) { MediaDetailView(runner: pluginRunner, media: anime, pluginId: plugin.url.deletingPathExtension().lastPathComponent) { try await pluginRunner.getAnimeUpdate(anime: $0, needsDetails: true, needsEpisodes: true) } }
                        }
                    }
                    .padding(.horizontal)
                }
            case .novelScroller(let novels, _):
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(novels, id: \.key) { novel in
                            MediaCardView(media: novel) { MediaDetailView(runner: pluginRunner, media: novel, pluginId: plugin.url.deletingPathExtension().lastPathComponent) { try await pluginRunner.getNovelUpdate(novel: $0) } }
                        }
                    }
                    .padding(.horizontal)
                }
            case .novelList(_, _, let novels, _):
                VStack {
                    ForEach(novels, id: \.key) { novel in
                        MediaRowView(media: novel) { MediaDetailView(runner: pluginRunner, media: novel, pluginId: plugin.url.deletingPathExtension().lastPathComponent) { try await pluginRunner.getNovelUpdate(novel: $0) } }
                        Divider().padding(.leading, 72)
                    }
                }
            case .novelBigScroller(let novels, _):
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(novels, id: \.key) { novel in
                            MediaBigCardView(media: novel) { MediaDetailView(runner: pluginRunner, media: novel, pluginId: plugin.url.deletingPathExtension().lastPathComponent) { try await pluginRunner.getNovelUpdate(novel: $0) } }
                        }
                    }
                    .padding(.horizontal)
                }
            default:
                Text("Unsupported component type.")
                    .foregroundColor(.secondary)
                    .padding()
            }
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func renderSearchList() -> some View {
        if let pluginRunner = runner {
            switch plugin.info.type {
            case .anime:
                List(searchAnimes, id: \.key) { anime in
                    MediaRowView(media: anime) { MediaDetailView(runner: pluginRunner, media: anime, pluginId: plugin.url.deletingPathExtension().lastPathComponent) { try await pluginRunner.getAnimeUpdate(anime: $0, needsDetails: true, needsEpisodes: true) } }
                }
                .listStyle(.plain)
            case .manga:
                List(searchMangas, id: \.key) { manga in
                    MediaRowView(media: manga) { MediaDetailView(runner: pluginRunner, media: manga, pluginId: plugin.url.deletingPathExtension().lastPathComponent) { try await pluginRunner.getMangaUpdate(manga: $0) } }
                }
                .listStyle(.plain)
            case .novel:
                List(searchNovels, id: \.key) { novel in
                    MediaRowView(media: novel) { MediaDetailView(runner: pluginRunner, media: novel, pluginId: plugin.url.deletingPathExtension().lastPathComponent) { try await pluginRunner.getNovelUpdate(novel: $0) } }
                }
                .listStyle(.plain)
            }
        } else {
            EmptyView()
        }
    }

    private func performSearch(query: String) {
        searchTask?.cancel()

        guard !query.isEmpty else {
            // Re-load default popular listing if search is cleared
            Task { await loadPlugin() }
            return
        }

        searchTask = Task {
            // Debounce
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let pluginRunner = self.runner else { return }

            do {
                switch plugin.info.type {
                case .anime:
                    let result = try await pluginRunner.getSearchAnimeList(query: query, page: 1, filters: [])
                    await MainActor.run { self.searchAnimes = result.entries }
                case .manga:
                    let result = try await pluginRunner.getSearchMangaList(query: query, page: 1, filters: [])
                    await MainActor.run { self.searchMangas = result.entries }
                case .novel:
                    let result = try await pluginRunner.getSearchNovelList(query: query, page: 1, filters: [])
                    await MainActor.run { self.searchNovels = result.entries }
                }
            } catch {
                print("Search failed: \(error)")
                await MainActor.run {
                    self.errorMessage = "Search error: \(error.localizedDescription)"
                }
            }
        }
    }

    private func loadPlugin() async {
        guard !isLoaded else { return }
        do {
            let pluginRunner = ItoRunner()
            await pluginRunner.setNetModule(AppNetModule())
            await pluginRunner.setStdModule(DefaultStdModule())
            let pluginId = plugin.url.deletingPathExtension().lastPathComponent
            await pluginRunner.setDefaultsModule(DefaultDefaultsModule(pluginId: pluginId))
            await pluginRunner.setHtmlModule(DefaultHtmlModule())
            await pluginRunner.setJsModule(DefaultJsModule())

            _ = try await pluginRunner.loadBundle(from: plugin.url)
            self.runner = pluginRunner

            let layout = try await pluginRunner.getHome()
            await MainActor.run {
                self.homeLayout = layout
                self.isLoaded = true
            }
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.isLoaded = true
            }
        }
    }
}

extension HomeComponentValue {
    var listing: Listing? {
        switch self {
        case .scroller(_, let listing): return listing
        case .mangaList(_, _, _, let listing): return listing
        case .mangaChapterList(_, _, let listing): return listing
        case .animeScroller(_, let listing): return listing
        case .animeList(_, _, _, let listing): return listing
        case .animeEpisodeList(_, _, let listing): return listing
        case .novelScroller(_, let listing): return listing
        case .novelList(_, _, _, let listing): return listing
        case .novelChapterList(_, _, let listing): return listing
        default: return nil
        }
    }
}

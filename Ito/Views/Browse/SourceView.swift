import OSLog
import SwiftUI
import Nuke
import NukeUI
import ito_runner

extension PluginInfo {
    public var isArchived: Bool { archived ?? false }

    public var archiveNotice: String {
        if let reason = archivedReason {
            return "This plugin is no longer maintained.\nReason: \(reason)"
        }
        return "This plugin is no longer maintained."
    }
}

struct SourceView: View {
    let plugin: InstalledPlugin

    @State private var runner: ItoRunner?
    @State private var homeLayout: HomeLayout?

    // Fallback states for search
    @State private var searchMangas: [Manga] = []
    @State private var searchAnimes: [Anime] = []
    @State private var searchNovels: [Novel] = []

    @State private var settingsSchema: SettingsSchema?
    @State private var showSettings = false

    @State private var isLoaded = false
    @State private var errorMessage: String?

    @State private var searchQuery: String = ""
    @State private var searchTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

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
                            if plugin.info.isArchived {
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack {
                                        Label {
                                            Text("Archived Plugin")
                                                .font(.headline)
                                                .foregroundColor(.primary)
                                        } icon: {
                                            Image(systemName: "archivebox.fill")
                                                .foregroundStyle(.orange)
                                        }
                                        Spacer()
                                        if let dateStr = plugin.info.archivedDate {
                                            Text(dateStr)
                                                .font(.subheadline)
                                                .foregroundStyle(.secondary)
                                        }
                                    }

                                    Text(.init(plugin.info.archiveNotice))
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .tint(.accentColor)
                                        .fixedSize(horizontal: false, vertical: true)

                                    Button(role: .destructive) {
                                        Task {
                                            do {
                                                try FileManager.default.removeItem(at: plugin.url)
                                            } catch {
                                                await MainActor.run {
                                                    withAnimation {
                                                        SnackBarManager.shared.showError("Failed to remove \(plugin.info.name): \(error.localizedDescription)")
                                                    }
                                                }
                                            }
                                            await PluginManager.shared.reloadInstalledPlugins()
                                            await MainActor.run {
                                                dismiss()
                                            }
                                        }
                                    } label: {
                                        Label("Remove Plugin", systemImage: "trash")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.large)
                                }
                                .padding()
                                .background(Color(.secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .padding(.horizontal)
                            }

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
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if settingsSchema != nil {
                    Button(action: { showSettings = true }) {
                        Image(systemName: "gear")
                    }
                }
            }
        }
        .sheet(isPresented: $showSettings, onDismiss: {
            Task {
                // Evict the cached runner so settings changes take effect on reload
                PluginManager.shared.evictRunner(for: plugin.id)
                isLoaded = false
                homeLayout = nil
                runner = nil
                await loadPlugin()
            }
        }) {
            if let schema = settingsSchema {
                PluginSettingsView(plugin: plugin, schema: schema)
            }
        }
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
            case .mangaChapterList(_, let entries, _):
                VStack(spacing: 0) {
                    ForEach(entries.indices, id: \.self) { idx in
                        let entry = entries[idx]
                        VStack(spacing: 2) {
                            MediaRowView(media: entry.manga) { MediaDetailView(runner: pluginRunner, media: entry.manga, pluginId: plugin.url.deletingPathExtension().lastPathComponent) { try await pluginRunner.getMangaUpdate(manga: $0) } }
                            HStack {
                                Text(entry.chapter.title ?? "Chapter \(entry.chapter.chapter.map { String(Int($0)) } ?? "—")")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.leading, 88)
                            .padding(.trailing)
                            .padding(.bottom, 8)
                        }
                        Divider().padding(.leading, 88)
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
            case .animeEpisodeList(_, let entries, _):
                VStack(spacing: 0) {
                    ForEach(entries.indices, id: \.self) { idx in
                        let entry = entries[idx]
                        VStack(spacing: 2) {
                            MediaRowView(media: entry.anime) { MediaDetailView(runner: pluginRunner, media: entry.anime, pluginId: plugin.url.deletingPathExtension().lastPathComponent) { try await pluginRunner.getAnimeUpdate(anime: $0, needsDetails: true, needsEpisodes: true) } }
                            HStack {
                                Text(entry.episode.title ?? "Episode \(entry.episode.episode.map { String(Int($0)) } ?? "—")")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.leading, 88)
                            .padding(.trailing)
                            .padding(.bottom, 8)
                        }
                        Divider().padding(.leading, 88)
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
            case .novelChapterList(_, let entries, _):
                VStack(spacing: 0) {
                    ForEach(entries.indices, id: \.self) { idx in
                        let entry = entries[idx]
                        VStack(spacing: 2) {
                            MediaRowView(media: entry.novel) { MediaDetailView(runner: pluginRunner, media: entry.novel, pluginId: plugin.url.deletingPathExtension().lastPathComponent) { try await pluginRunner.getNovelUpdate(novel: $0) } }
                            HStack {
                                Text(entry.chapter.title ?? "Chapter \(entry.chapter.chapter.map { String(Int($0)) } ?? "—")")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.leading, 88)
                            .padding(.trailing)
                            .padding(.bottom, 8)
                        }
                        Divider().padding(.leading, 88)
                    }
                }
            case .links(let links):
                VStack(spacing: 12) {
                    ForEach(links.indices, id: \.self) { idx in
                        let link = links[idx]
                        Button(action: {
                            // Link tap handler not directly opening Safari/media in layout unless wrapped in nav link, so this is just UI dummy for now if we don't have routing manager
                        }) {
                            HStack {
                                Text(link.title)
                                    .font(.body)
                                Spacer()
                                Image(systemName: "chevron.right")
                            }
                            .padding()
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(8)
                            .padding(.horizontal)
                        }
                        .foregroundColor(.primary)
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
            // Clear stale search results; the home layout is already loaded
            searchMangas = []
            searchAnimes = []
            searchNovels = []
            return
        }

        searchTask = Task {
            // Debounce
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let pluginRunner = self.runner else {
                AppLogger.ui.debug("🔍 [SourceView] Search skipped — cancelled or runner nil")
                return
            }

            do {
                AppLogger.ui.debug("\("🔍 [SourceView] Searching '\(query)")' on \(plugin.info.name)")
                switch plugin.info.type {
                case .anime:
                    let result = try await pluginRunner.getSearchAnimeList(query: query, page: 1, filters: [])
                    guard !Task.isCancelled else { return }
                    await MainActor.run { self.searchAnimes = result.entries }
                case .manga:
                    let result = try await pluginRunner.getSearchMangaList(query: query, page: 1, filters: [])
                    guard !Task.isCancelled else { return }
                    await MainActor.run { self.searchMangas = result.entries }
                case .novel:
                    let result = try await pluginRunner.getSearchNovelList(query: query, page: 1, filters: [])
                    guard !Task.isCancelled else { return }
                    await MainActor.run { self.searchNovels = result.entries }
                }
                AppLogger.ui.debug("\("🔍 [SourceView] Search complete for '\(query)")'")
            } catch is CancellationError {
                AppLogger.ui.debug("\("🔍 [SourceView] Search cancelled for '\(query)")'")
            } catch {
                AppLogger.ui.error("🔍 [SourceView] Search failed: \(error)")
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.errorMessage = "Search error: \(error.localizedDescription)"
                }
            }
        }
    }

    private func loadPlugin() async {
        guard !isLoaded else {
            AppLogger.ui.debug("📦 [SourceView] loadPlugin skipped — already loaded for \(plugin.info.name)")
            return
        }
        AppLogger.ui.debug("\("📦 [SourceView] loadPlugin START for \(plugin.info.name)") (id: \(plugin.id))")
        do {
            AppLogger.ui.debug("📦 [SourceView] Getting cached runner from PluginManager...")
            let pluginRunner = try await PluginManager.shared.getRunner(for: plugin.id)
            AppLogger.ui.debug("📦 [SourceView] Runner obtained")

            guard !Task.isCancelled else {
                AppLogger.ui.debug("📦 [SourceView] Task cancelled after getRunner")
                return
            }

            self.runner = pluginRunner

            AppLogger.ui.debug("📦 [SourceView] Fetching settings schema...")
            let schema = try? await pluginRunner.getSettings()

            guard !Task.isCancelled else {
                AppLogger.ui.debug("📦 [SourceView] Task cancelled after getSettings")
                return
            }

            AppLogger.ui.debug("📦 [SourceView] Fetching home layout...")
            let layout = try await pluginRunner.getHome()

            guard !Task.isCancelled else {
                AppLogger.ui.debug("📦 [SourceView] Task cancelled after getHome")
                return
            }

            AppLogger.ui.debug("\("📦 [SourceView] loadPlugin SUCCESS — \(layout.components.count)") components")
            await MainActor.run {
                self.settingsSchema = schema
                self.homeLayout = layout
                self.isLoaded = true
            }
        } catch is CancellationError {
            // Don't mark isLoaded — let a future .task re-attempt
            AppLogger.ui.debug("📦 [SourceView] loadPlugin CANCELLED for \(plugin.info.name)")
        } catch {
            AppLogger.ui.error("📦 [SourceView] loadPlugin FAILED for \(self.plugin.info.name): \(error)")
            await MainActor.run {
                SnackBarManager.shared.showError(error, title: "Failed to load \(self.plugin.info.name)")
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

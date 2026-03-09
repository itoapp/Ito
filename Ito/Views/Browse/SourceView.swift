import SwiftUI
import ito_runner

struct SourceView: View {
    let plugin: InstalledPlugin

    @State private var runner: ItoRunner?
    @State private var mangas: [Manga] = []
    @State private var animes: [Anime] = []
    @State private var isLoaded = false
    @State private var errorMessage: String? = nil
    
    @State private var searchQuery: String = ""
    @State private var searchTask: Task<Void, Never>? = nil

    var body: some View {
        Group {
            if !isLoaded && errorMessage == nil {
                ProgressView("Loading Source...")
            } else if let error = errorMessage {
                Text("Error: \(error)").foregroundColor(.red)
            } else {
                if plugin.info.type == .anime {
                    List(animes, id: \.key) { anime in
                        ZStack {
                            if let runner = self.runner {
                                NavigationLink(destination: AnimeView(runner: runner, anime: anime, pluginId: plugin.url.deletingPathExtension().lastPathComponent))
                                {
                                    EmptyView()
                                }
                                .opacity(0)
                            }

                            HStack(alignment: .top, spacing: 12) {
                                if let coverURL = anime.cover, let url = URL(string: coverURL) {
                                    AsyncImage(url: url) { phase in
                                        switch phase {
                                        case .empty:
                                            Color.gray.opacity(0.3)
                                                .frame(width: 60, height: 90)
                                                .cornerRadius(6)
                                        case .success(let image):
                                            image
                                                .resizable()
                                                .aspectRatio(contentMode: .fill)
                                                .frame(width: 60, height: 90)
                                                .cornerRadius(6)
                                                .clipped()
                                        case .failure:
                                            Color.red.opacity(0.3)
                                                .frame(width: 60, height: 90)
                                                .cornerRadius(6)
                                        @unknown default:
                                            EmptyView()
                                        }
                                    }
                                } else {
                                    Color.gray.opacity(0.3)
                                        .frame(width: 60, height: 90)
                                        .cornerRadius(6)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(anime.title)
                                        .font(.headline)
                                        .lineLimit(2)

                                    if let studios = anime.studios, !studios.isEmpty {
                                        Text(studios.joined(separator: ", "))
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                }

                                Spacer()
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listStyle(.plain)
                } else {
                    List(mangas, id: \.key) { manga in
                        ZStack {
                            if let runner = self.runner {
                                NavigationLink(destination: MangaView(runner: runner, manga: manga, pluginId: plugin.url.deletingPathExtension().lastPathComponent))
                                {
                                    EmptyView()
                                }
                                .opacity(0)
                            }

                            HStack(alignment: .top, spacing: 12) {
                                if let coverURL = manga.cover, let url = URL(string: coverURL) {
                                    AsyncImage(url: url) { phase in
                                        switch phase {
                                        case .empty:
                                            Color.gray.opacity(0.3)
                                                .frame(width: 60, height: 90)
                                                .cornerRadius(6)
                                        case .success(let image):
                                            image
                                                .resizable()
                                                .aspectRatio(contentMode: .fill)
                                                .frame(width: 60, height: 90)
                                                .cornerRadius(6)
                                                .clipped()
                                        case .failure:
                                            Color.red.opacity(0.3)
                                                .frame(width: 60, height: 90)
                                                .cornerRadius(6)
                                        @unknown default:
                                            EmptyView()
                                        }
                                    }
                                } else {
                                    Color.gray.opacity(0.3)
                                        .frame(width: 60, height: 90)
                                        .cornerRadius(6)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(manga.title)
                                        .font(.headline)
                                        .lineLimit(2)

                                    if let authors = manga.authors, !authors.isEmpty {
                                        Text(authors.joined(separator: ", "))
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                }

                                Spacer()
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listStyle(.plain)
                }
            }
        }
        .navigationTitle(plugin.url.deletingPathExtension().lastPathComponent.capitalized)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchQuery, prompt: "Search source...")
        .onChange(of: searchQuery) { newValue in
            performSearch(query: newValue)
        }
        .task {
            await loadPlugin()
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
                if plugin.info.type == .anime {
                    let result = try await pluginRunner.getSearchAnimeList(query: query, page: 1, filters: [])
                    await MainActor.run {
                        self.animes = result.entries
                    }
                } else {
                    let result = try await pluginRunner.getSearchMangaList(query: query, page: 1, filters: [])
                    await MainActor.run {
                        self.mangas = result.entries
                    }
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

            let listing = Listing(id: "views", name: "Popular", kind: 0)

            if plugin.info.type == .anime {
                let result = try await pluginRunner.getAnimeList(listing: listing, page: 1)
                await MainActor.run {
                    self.animes = result.entries
                    self.isLoaded = true
                }
            } else {
                let result = try await pluginRunner.getMangaList(listing: listing, page: 1)
                await MainActor.run {
                    self.mangas = result.entries
                    self.isLoaded = true
                }
            }
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.isLoaded = true
            }
        }
    }
}

import SwiftUI
import ito_runner

struct ListingView: View {
    let plugin: InstalledPlugin
    let runner: ItoRunner
    let listing: Listing
    let title: String

    @State private var page: Int32 = 1
    @State private var hasNextPage: Bool = true
    @State private var isLoading: Bool = false
    @State private var errorMessage: String? = nil

    // State for respective models
    @State private var mangas: [Manga] = []
    @State private var animes: [Anime] = []
    @State private var novels: [Novel] = []

    var body: some View {
        Group {
            if mangas.isEmpty && animes.isEmpty && novels.isEmpty && isLoading && errorMessage == nil {
                ProgressView("Loading \(title)...")
            } else if let error = errorMessage, mangas.isEmpty && animes.isEmpty && novels.isEmpty {
                Text(error).foregroundColor(.red)
            } else {
                List {
                    switch plugin.info.type {
                    case .anime:
                        ForEach(animes, id: \.key) { anime in
                            AnimeRowView(anime: anime, plugin: plugin, runner: runner)
                                .onAppear {
                                    if anime.key == animes.last?.key && hasNextPage && !isLoading {
                                        loadData()
                                    }
                                }
                        }
                    case .manga:
                        ForEach(mangas, id: \.key) { manga in
                            MangaRowView(manga: manga, plugin: plugin, runner: runner)
                                .onAppear {
                                    if manga.key == mangas.last?.key && hasNextPage && !isLoading {
                                        loadData()
                                    }
                                }
                        }
                    case .novel:
                        ForEach(novels, id: \.key) { novel in
                            NovelRowView(novel: novel, plugin: plugin, runner: runner)
                                .onAppear {
                                    if novel.key == novels.last?.key && hasNextPage && !isLoading {
                                        loadData()
                                    }
                                }
                        }
                    }

                    if isLoading && (!mangas.isEmpty || !animes.isEmpty || !novels.isEmpty) {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .padding()
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if mangas.isEmpty && animes.isEmpty && novels.isEmpty {
                loadData()
            }
        }
    }

    private func loadData() {
        guard !isLoading, hasNextPage else { return }
        isLoading = true
        errorMessage = nil

        Task {
            do {
                switch plugin.info.type {
                case .manga:
                    let result = try await runner.getMangaList(listing: listing, page: page)
                    await MainActor.run {
                        self.mangas.append(contentsOf: result.entries)
                        self.hasNextPage = result.hasNextPage
                        self.page += 1
                        self.isLoading = false
                    }
                case .anime:
                    let result = try await runner.getAnimeList(listing: listing, page: page)
                    await MainActor.run {
                        self.animes.append(contentsOf: result.entries)
                        self.hasNextPage = result.hasNextPage
                        self.page += 1
                        self.isLoading = false
                    }
                case .novel:
                    let result = try await runner.getNovelList(listing: listing, page: page)
                    await MainActor.run {
                        self.novels.append(contentsOf: result.entries)
                        self.hasNextPage = result.hasNextPage
                        self.page += 1
                        self.isLoading = false
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }
}

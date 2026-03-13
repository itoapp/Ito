import SwiftUI
import NukeUI
import Nuke

struct DiscoverView: View {
    @StateObject private var manager = DiscoverManager.shared
    @StateObject private var pluginManager = PluginManager.shared

    @State private var selectedType: DiscoverMediaType = .anime
    @State private var searchQuery = ""
    @State private var searchResults: [DiscoverMedia] = []
    @State private var isSearching = false
    @State private var searchHasNextPage = false
    @State private var searchPage = 1
    @State private var searchTask: Task<Void, Never>?

    @State private var showFilters = false
    @State private var activeFilters = DiscoverFilters()
    @State private var isFilterActive = false

    var body: some View {
        NavigationView {
            Group {
                if !searchQuery.isEmpty || isFilterActive {
                    searchResultsView
                } else {
                    homeView
                }
            }
            .navigationTitle("Discover")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showFilters = true
                    } label: {
                        Image(systemName: isFilterActive
                              ? "line.3.horizontal.decrease.circle.fill"
                              : "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel(isFilterActive ? "Filters, active" : "Filters")
                }
            }
            .searchable(text: $searchQuery, prompt: "Search \(selectedType == .anime ? "anime" : "manga")...")
            .onChange(of: searchQuery) { newValue in
                performSearch(query: newValue)
            }
            .sheet(isPresented: $showFilters) {
                DiscoverFilterView(
                    mediaType: selectedType,
                    filters: $activeFilters,
                    onApply: {
                        isFilterActive = !activeFilters.isEmpty
                        if isFilterActive {
                            performSearch(query: searchQuery)
                        }
                    },
                    onReset: {
                        activeFilters = DiscoverFilters()
                        isFilterActive = false
                    }
                )
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - Home View

    private var homeView: some View {
        ScrollView {
            VStack(spacing: 0) {
                typePicker
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 16)

                if manager.isLoadingHome && currentTrending.isEmpty {
                    ProgressView("Loading...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.top, 100)
                } else if currentTrending.isEmpty && currentPopular.isEmpty && currentTopRated.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "wifi.slash")
                            .font(.system(size: 48, weight: .thin))
                            .foregroundStyle(.secondary)
                        Text("Unable to load content")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Text("Check your connection and try again")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                        Button {
                            Task {
                                manager.clearCache(for: selectedType)
                                await manager.loadHomeSections(for: selectedType)
                            }
                        } label: {
                            Text("Try Again")
                                .font(.body.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 100)
                } else {
                    LazyVStack(spacing: 24) {
                        if !currentTrending.isEmpty {
                            discoverSection(title: "Trending Now", items: currentTrending)
                        }
                        if selectedType == .anime && !manager.seasonalAnime.isEmpty {
                            discoverSection(title: "Popular This Season", items: manager.seasonalAnime)
                        }
                        if !currentPopular.isEmpty {
                            discoverSection(title: "All-Time Popular", items: currentPopular)
                        }
                        if !currentTopRated.isEmpty {
                            discoverSection(title: "Top Rated", items: currentTopRated)
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
        }
        .refreshable {
            manager.clearCache(for: selectedType)
            await manager.loadHomeSections(for: selectedType)
        }
        .task {
            if currentTrending.isEmpty {
                await manager.loadHomeSections(for: selectedType)
            }
        }
        .onChange(of: selectedType) { newType in
            Task {
                if selectedType == .anime ? manager.trendingAnime.isEmpty : manager.trendingManga.isEmpty {
                    await manager.loadHomeSections(for: newType)
                }
            }
        }
    }

    // MARK: - Type Picker

    private var typePicker: some View {
        Picker("Type", selection: $selectedType) {
            Text("Anime").tag(DiscoverMediaType.anime)
            Text("Manga").tag(DiscoverMediaType.manga)
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Computed Properties

    private var currentTrending: [DiscoverMedia] {
        selectedType == .anime ? manager.trendingAnime : manager.trendingManga
    }

    private var currentPopular: [DiscoverMedia] {
        selectedType == .anime ? manager.popularAnime : manager.popularManga
    }

    private var currentTopRated: [DiscoverMedia] {
        selectedType == .anime ? manager.topRatedAnime : manager.topRatedManga
    }

    // MARK: - Section

    private func discoverSection(title: String, items: [DiscoverMedia]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2.weight(.bold))
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(items) { media in
                        NavigationLink(destination: DiscoverDetailView(media: media)) {
                            DiscoverCardView(media: media)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - Search Results

    private var searchResultsView: some View {
        Group {
            if isSearching && searchResults.isEmpty {
                ProgressView("Searching...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if searchResults.isEmpty && !searchQuery.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 48, weight: .thin))
                        .foregroundStyle(.secondary)
                    Text("No results found")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("Try different search terms or adjust your filters")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if isFilterActive {
                        activeFilterPills
                    }

                    ForEach(searchResults) { media in
                        NavigationLink(destination: DiscoverDetailView(media: media)) {
                            DiscoverSearchRow(media: media)
                        }
                        .onAppear {
                            if media.id == searchResults.last?.id && searchHasNextPage && !isSearching {
                                loadNextSearchPage()
                            }
                        }
                    }

                    if isSearching && !searchResults.isEmpty {
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
    }

    // MARK: - Active Filters

    private var activeFilterPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(activeFilters.genres, id: \.self) { genre in
                    filterPill(genre) {
                        activeFilters.genres.removeAll { $0 == genre }
                        isFilterActive = !activeFilters.isEmpty
                        performSearch(query: searchQuery)
                    }
                }
                ForEach(activeFilters.tags, id: \.self) { tag in
                    filterPill(tag) {
                        activeFilters.tags.removeAll { $0 == tag }
                        isFilterActive = !activeFilters.isEmpty
                        performSearch(query: searchQuery)
                    }
                }
                if let format = activeFilters.format {
                    filterPill(format) {
                        activeFilters.format = nil
                        isFilterActive = !activeFilters.isEmpty
                        performSearch(query: searchQuery)
                    }
                }
                if let status = activeFilters.status {
                    filterPill(status.replacingOccurrences(of: "_", with: " ").capitalized) {
                        activeFilters.status = nil
                        isFilterActive = !activeFilters.isEmpty
                        performSearch(query: searchQuery)
                    }
                }
            }
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
    }

    private func filterPill(_ label: String, onRemove: @escaping () -> Void) -> some View {
        Button(action: onRemove) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.caption.weight(.medium))
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .background(Color.accentColor.opacity(0.12))
            .foregroundStyle(Color.accentColor)
            .cornerRadius(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove \(label) filter")
    }

    // MARK: - Search Actions

    private func performSearch(query: String) {
        searchTask?.cancel()

        guard !query.isEmpty || isFilterActive else {
            searchResults = []
            return
        }

        searchTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }

            await MainActor.run { isSearching = true; searchPage = 1 }

            do {
                let result = try await manager.search(query: query, type: selectedType, filters: activeFilters, page: 1)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.searchResults = result.media
                    self.searchHasNextPage = result.hasNextPage
                    self.searchPage = 1
                    self.isSearching = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { self.isSearching = false }
            }
        }
    }

    private func loadNextSearchPage() {
        guard !isSearching, searchHasNextPage else { return }
        let nextPage = searchPage + 1

        Task {
            await MainActor.run { isSearching = true }
            do {
                let result = try await manager.search(query: searchQuery, type: selectedType, filters: activeFilters, page: nextPage)
                await MainActor.run {
                    self.searchResults.append(contentsOf: result.media)
                    self.searchHasNextPage = result.hasNextPage
                    self.searchPage = nextPage
                    self.isSearching = false
                }
            } catch {
                await MainActor.run { self.isSearching = false }
            }
        }
    }
}

// MARK: - Discover Card

struct DiscoverCardView: View {
    let media: DiscoverMedia

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                if let coverURL = media.coverImage, let url = URL(string: coverURL) {
                    LazyImage(url: url) { state in
                        if let image = state.image {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            // Skeleton loading state instead of spinner
                            Color(.secondarySystemFill)
                                .opacity(state.isLoading ? 0.5 : 1.0)
                        }
                    }
                    .processors([
                        .resize(size: CGSize(width: 240, height: 340), contentMode: .aspectFill, crop: true)
                    ])
                    .priority(.normal)
                    .frame(width: 120, height: 170)
                    .cornerRadius(10)
                    .clipped()
                } else {
                    Color(.secondarySystemFill)
                        .frame(width: 120, height: 170)
                        .cornerRadius(10)
                }

                if let score = media.averageScore {
                    Text("\(score)%")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(scoreColor(score).opacity(0.9))
                        .cornerRadius(6)
                        .padding(4)
                        .accessibilityLabel("Score: \(score) percent")
                }
            }

            Text(media.title)
                .font(.caption.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: 120, alignment: .leading)
        }
    }

    private func scoreColor(_ score: Int) -> Color {
        if score >= 75 { return .green }
        if score >= 50 { return .orange }
        return .red
    }
}

// MARK: - Search Row

struct DiscoverSearchRow: View {
    let media: DiscoverMedia

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let coverURL = media.coverImage, let url = URL(string: coverURL) {
                LazyImage(url: url) { state in
                    if let image = state.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color(.secondarySystemFill)
                            .opacity(state.isLoading ? 0.5 : 1.0)
                    }
                }
                .processors([
                    .resize(size: CGSize(width: 120, height: 170), contentMode: .aspectFill, crop: true)
                ])
                .priority(.normal)
                .frame(width: 60, height: 85)
                .cornerRadius(8)
            } else {
                Color(.secondarySystemFill)
                    .frame(width: 60, height: 85)
                    .cornerRadius(8)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(media.title)
                    .font(.headline)
                    .lineLimit(2)

                if let romaji = media.titleRomaji, romaji != media.title {
                    Text(romaji)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    if let format = media.format {
                        Text(format.replacingOccurrences(of: "_", with: " "))
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12))
                            .foregroundStyle(Color.accentColor)
                            .cornerRadius(6)
                    }
                    if let score = media.averageScore {
                        HStack(spacing: 2) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8))
                            Text("\(score)%")
                                .font(.caption2.weight(.medium))
                        }
                        .foregroundStyle(.secondary)
                    }
                    if let eps = media.episodes {
                        Text("\(eps) ep")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if let chs = media.chapters {
                        Text("\(chs) ch")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    DiscoverView()
}

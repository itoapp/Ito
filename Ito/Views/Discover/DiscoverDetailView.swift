import SwiftUI
import NukeUI
import Nuke
import ito_runner

private let detailHeroHeight: CGFloat = 340

private struct DetailNavTitleKey: PreferenceKey {
    static var defaultValue: Bool = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = nextValue()
    }
}

struct DiscoverDetailView: View {
    @State var media: DiscoverMedia

    @StateObject private var pluginManager = PluginManager.shared
    @State private var isDescriptionExpanded = false
    @State private var showNavTitle = false

    @State private var selectedPlugin: InstalledPlugin?
    @State private var pluginSearchResults: [PluginSearchResult] = []
    @State private var isSearchingPlugin = false
    @State private var pluginSearchError: String?
    @State private var themeDominant: Color?
    @State private var themeSecondary: Color?

    private var uniqueMediaKey: String { "anilist_\(media.id)" }

    private var matchingPlugins: [InstalledPlugin] {
        pluginManager.installedPlugins.values
            .filter { plugin in
                if media.type == "ANIME" {
                    return plugin.info.type == .anime
                } else {
                    return plugin.info.type == .manga
                }
            }
            .sorted { $0.info.name < $1.info.name }
    }

    private var cleanDescription: String? {
        guard let desc = media.description, !desc.isEmpty else { return nil }
        return desc.strippingHTML()
    }

    var body: some View {
        ZStack {
            if let themeDominant = themeDominant {
                themeDominant.ignoresSafeArea()
                Rectangle().fill(.regularMaterial).ignoresSafeArea()
            } else {
                Color(.systemBackground).ignoresSafeArea()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SharedHeroHeader(
                    title: media.title,
                    coverURL: media.bannerImage ?? media.coverImage,
                    authorOrStudio: media.titleRomaji != media.title ? media.titleRomaji : nil,
                    statusLabel: media.status?.replacingOccurrences(of: "_", with: " ").capitalized,
                    pluginId: media.averageScore != nil ? "★ \(media.averageScore!)%" : (media.format?.replacingOccurrences(of: "_", with: " ") ?? "Discover"),
                    onImageLoaded: { uiImage in
                        let key = uniqueMediaKey
                        Task {
                            await ThemeManager.shared.extractAndCache(image: uiImage, for: key)
                            if let theme = await ThemeManager.shared.getTheme(for: key) {
                                withAnimation(.easeIn(duration: 0.6)) {
                                    self.themeDominant = Color(hex: theme.dominantHex)
                                    self.themeSecondary = Color(hex: theme.secondaryHex)
                                }
                            }
                        }
                    }
                )
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: DetailNavTitleKey.self,
                            value: geo.frame(in: .global).maxY < 0
                        )
                    }
                )

                contentSection
            }
        }
        .background(Color.clear)
        }
        .coordinateSpace(name: "scroll")
        .onPreferenceChange(DetailNavTitleKey.self) { heroGone in
            withAnimation(.easeInOut(duration: 0.18)) { showNavTitle = heroGone }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if showNavTitle {
                    Text(media.title)
                        .font(.headline)
                        .lineLimit(1)
                        .transition(.opacity)
                }
            }
        }
        .task {
            if let theme = await ThemeManager.shared.getTheme(for: uniqueMediaKey) {
                self.themeDominant = Color(hex: theme.dominantHex)
                self.themeSecondary = Color(hex: theme.secondaryHex)
            }

            if let fetched = try? await DiscoverManager.shared.fetchMediaDetails(id: media.id) {
                await MainActor.run { self.media = fetched }
            }
        }
    }

    // MARK: - Content Section

    private var contentSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let genres = media.genres, !genres.isEmpty {
                tagsRow(tags: genres)
                    .padding(.top, 16)
            }

            if let desc = cleanDescription {
                descriptionSection(desc)
            }

            infoRow

            Divider().padding(.horizontal, 16)

            sourceSelectionSection

            if let recommendations = media.recommendations, !recommendations.isEmpty {
                Divider().padding(.horizontal, 16)
                recommendationsSection(recommendations)
            }
        }
        .padding(.bottom, 24)
        .background(Color.clear)
        .frame(maxWidth: UIScreen.main.bounds.width)
        .clipped()
    }

    // MARK: - Info Row

    private var infoRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                if let eps = media.episodes {
                    infoChip(label: "Episodes", value: "\(eps)")
                }
                if let chs = media.chapters {
                    infoChip(label: "Chapters", value: "\(chs)")
                }
                if let season = media.season, let year = media.seasonYear {
                    infoChip(label: "Season", value: "\(season.capitalized) \(year)")
                } else if let year = media.seasonYear {
                    infoChip(label: "Year", value: "\(year)")
                }
                if let type = media.format {
                    infoChip(label: "Format", value: type.replacingOccurrences(of: "_", with: " "))
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func infoChip(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline.weight(.semibold))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.itoCardBackground)
        .cornerRadius(10)
    }

    // MARK: - Tags

    private func tagsRow(tags: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tags, id: \.self) { tag in
                    Text(tag)
                        .font(.caption).lineLimit(1)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color(.tertiarySystemFill)).cornerRadius(14)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Description

    private func descriptionSection(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
                .font(.subheadline).foregroundStyle(.primary)
                .lineLimit(isDescriptionExpanded ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
                .animation(.easeInOut(duration: 0.2), value: isDescriptionExpanded)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isDescriptionExpanded.toggle() }
            } label: {
                Text(isDescriptionExpanded ? "Show less" : "Show more")
                    .font(.caption.weight(.semibold)).foregroundStyle(themeSecondary ?? Color.accentColor)
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Source Selection

    private var sourceSelectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Read with Plugin")
                .font(.title3.weight(.bold))
                .padding(.horizontal, 16)

            if matchingPlugins.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.system(size: 36, weight: .thin))
                        .foregroundStyle(.secondary)
                    Text("No \(media.type == "ANIME" ? "anime" : "manga") plugins installed")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Install plugins from the Browse tab to source content.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .padding(.horizontal, 16)
            } else {
                VStack(spacing: 0) {
                    ForEach(matchingPlugins, id: \.id) { plugin in
                        PluginSourceRow(
                            plugin: plugin,
                            isSelected: selectedPlugin?.id == plugin.id,
                            isSearching: isSearchingPlugin && selectedPlugin?.id == plugin.id
                        ) {
                            searchPlugin(plugin)
                        }
                        Divider().padding(.leading, 72)
                    }
                }

                if let error = pluginSearchError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 16)
                }

                if !pluginSearchResults.isEmpty {
                    pluginResultsSection
                }
            }
        }
    }

    // MARK: - Plugin Results

    private var pluginResultsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Results from \(selectedPlugin?.info.name ?? "Plugin")")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 8)

            VStack(spacing: 0) {
                ForEach(pluginSearchResults) { result in
                    NavigationLink(destination: result.destination) {
                        PluginResultRow(result: result)
                    }
                    Divider().padding(.leading, 72)
                }
            }
        }
    }

    // MARK: - Plugin Search

    private func searchPlugin(_ plugin: InstalledPlugin) {
        selectedPlugin = plugin
        pluginSearchResults = []
        pluginSearchError = nil
        isSearchingPlugin = true

        Task {
            do {
                let runner = try await PluginManager.shared.getRunner(for: plugin.id)
                let searchTitle = media.titleRomaji ?? media.title
                let pluginId = plugin.url.deletingPathExtension().lastPathComponent

                switch plugin.info.type {
                case .manga:
                    let result = try await runner.getSearchMangaList(query: searchTitle, page: 1, filters: [])
                    await MainActor.run {
                        self.pluginSearchResults = result.entries.prefix(5).map { manga in
                            PluginSearchResult(
                                id: manga.key,
                                title: manga.title,
                                cover: manga.cover,
                                subtitle: manga.authors?.joined(separator: ", "),
                                destination: AnyView(MediaDetailView(runner: runner, media: manga, pluginId: pluginId) { try await runner.getMangaUpdate(manga: $0) })
                            )
                        }
                        self.isSearchingPlugin = false
                    }
                case .anime:
                    let result = try await runner.getSearchAnimeList(query: searchTitle, page: 1, filters: [])
                    await MainActor.run {
                        self.pluginSearchResults = result.entries.prefix(5).map { anime in
                            PluginSearchResult(
                                id: anime.key,
                                title: anime.title,
                                cover: anime.cover,
                                subtitle: anime.studios?.joined(separator: ", "),
                                destination: AnyView(MediaDetailView(runner: runner, media: anime, pluginId: pluginId) { try await runner.getAnimeUpdate(anime: $0, needsDetails: true, needsEpisodes: true) })
                            )
                        }
                        self.isSearchingPlugin = false
                    }
                case .novel:
                    let result = try await runner.getSearchNovelList(query: searchTitle, page: 1, filters: [])
                    await MainActor.run {
                        self.pluginSearchResults = result.entries.prefix(5).map { novel in
                            PluginSearchResult(
                                id: novel.key,
                                title: novel.title,
                                cover: novel.cover,
                                subtitle: novel.authors?.joined(separator: ", "),
                                destination: AnyView(MediaDetailView(runner: runner, media: novel, pluginId: pluginId) { try await runner.getNovelUpdate(novel: $0) })
                            )
                        }
                        self.isSearchingPlugin = false
                    }
                }
            } catch {
                await MainActor.run {
                    self.pluginSearchError = "Search failed: \(error.localizedDescription)"
                    self.isSearchingPlugin = false
                }
            }
        }
    }

    // MARK: - Recommendations

    private func recommendationsSection(_ recommendations: [DiscoverMedia]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("More Like This")
                .font(.title3.weight(.bold))
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(recommendations) { recMedia in
                        NavigationLink(destination: DiscoverDetailView(media: recMedia)) {
                            DiscoverRecommendationCard(media: recMedia)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.top, 8)
    }
}

// MARK: - Recommendation Card

private struct DiscoverRecommendationCard: View {
    let media: DiscoverMedia

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let coverURL = media.coverImage, let url = URL(string: coverURL) {
                LazyImage(url: url) { state in
                    if let image = state.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else if state.error != nil {
                        Color.itoCardBackground
                    } else {
                        Color.itoCardBackground.overlay(ProgressView().tint(.gray))
                    }
                }
                .processors([.resize(width: 200)])
                .frame(width: 110, height: 160)
                .cornerRadius(8)
                .clipped()
            } else {
                ZStack {
                    Color.itoCardBackground
                    Image(systemName: "photo.on.rectangle.angled").foregroundStyle(.tertiary)
                }
                .frame(width: 110, height: 160)
                .cornerRadius(8)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(media.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: 110, alignment: .leading)

                if let score = media.averageScore {
                    Text("★ \(score)%")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .frame(width: 110)
    }
}

// MARK: - Plugin Source Row

private struct PluginSourceRow: View {
    let plugin: InstalledPlugin
    let isSelected: Bool
    let isSearching: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                if let iconData = plugin.iconData, let uiImage = UIImage(data: iconData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Image(systemName: "puzzlepiece.extension.fill")
                        .foregroundStyle(Color.accentColor).imageScale(.large)
                        .frame(width: 40, height: 40)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(plugin.info.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text("v\(plugin.info.version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if isSearching {
                    ProgressView().progressViewStyle(.circular)
                } else {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(isSelected ? Color.itoCardBackground : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

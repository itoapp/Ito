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
        return stripHTMLDiscover(desc)
    }

    var body: some View {
        GeometryReader { outerGeo in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    heroHeader(screenWidth: outerGeo.size.width)
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
                .frame(width: outerGeo.size.width)
            }
        }
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
            if let fetched = try? await DiscoverManager.shared.fetchMediaDetails(id: media.id) {
                await MainActor.run { self.media = fetched }
            }
        }
    }

    // MARK: - Hero Header

    private func heroHeader(screenWidth: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            coverBackground(screenWidth: screenWidth)
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .black.opacity(0.15), location: 0.4),
                    .init(color: .black.opacity(0.72), location: 1.0)
                ]),
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)

            HStack(alignment: .bottom, spacing: 14) {
                sharpCoverView
                heroMetadata
                    .padding(.bottom, 20)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .frame(width: screenWidth, height: detailHeroHeight)
        .clipped()
        .ignoresSafeArea(edges: .top)
    }

    @ViewBuilder
    private func coverBackground(screenWidth: CGFloat) -> some View {
        let bgURL = media.bannerImage ?? media.coverImage
        if let urlStr = bgURL, let url = URL(string: urlStr) {
            LazyImage(url: url) { state in
                if let image = state.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                        .blur(radius: 10, opaque: true)
                } else {
                    Color(.secondarySystemBackground)
                }
            }
            .processors([.resize(width: 400)])
            .frame(width: screenWidth, height: detailHeroHeight)
            .clipped()
            .ignoresSafeArea(edges: .top)
            .overlay(Color.black.opacity(0.35))
        } else {
            Color(.secondarySystemBackground)
                .frame(height: detailHeroHeight)
                .ignoresSafeArea(edges: .top)
        }
    }

    private var sharpCoverView: some View {
        Group {
            if let coverURL = media.coverImage, let url = URL(string: coverURL) {
                LazyImage(url: url) { state in
                    if let image = state.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else if state.error != nil {
                        Color(.secondarySystemFill)
                    } else {
                        Color(.secondarySystemFill).overlay(ProgressView().tint(.white))
                    }
                }
                .processors([.resize(width: 400)])
            } else {
                ZStack {
                    Color(.secondarySystemFill)
                    Image(systemName: "photo.on.rectangle.angled").foregroundStyle(.tertiary)
                }
            }
        }
        .frame(width: 130, height: 195)
        .cornerRadius(10)
        .clipped()
        .shadow(color: .black.opacity(0.5), radius: 14, x: 0, y: 6)
    }

    // MARK: - Hero Metadata

    private var heroMetadata: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(media.title)
                .font(.title2.weight(.bold))
                .foregroundColor(.white)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .shadow(color: .black.opacity(0.4), radius: 4, x: 0, y: 1)

            if let romaji = media.titleRomaji, romaji != media.title, !romaji.isEmpty {
                Text(romaji)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                if let format = media.format {
                    DiscoverHeroBadge(label: format.replacingOccurrences(of: "_", with: " "))
                }
                if let status = media.status {
                    DiscoverHeroBadge(label: status.replacingOccurrences(of: "_", with: " ").capitalized)
                }
                if let score = media.averageScore {
                    DiscoverHeroBadge(label: "★ \(score)%")
                }
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
        .background(Color(.systemBackground))
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
        .background(Color(.secondarySystemFill))
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
                .animation(.easeInOut(duration: 0.2), value: isDescriptionExpanded)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isDescriptionExpanded.toggle() }
            } label: {
                Text(isDescriptionExpanded ? "Show less" : "Show more")
                    .font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
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
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
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
                                destination: AnyView(MangaView(runner: runner, manga: manga, pluginId: pluginId))
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
                                destination: AnyView(AnimeView(runner: runner, anime: anime, pluginId: pluginId))
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
                                destination: AnyView(NovelView(runner: runner, novel: novel, pluginId: pluginId))
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
                        Color(.secondarySystemFill)
                    } else {
                        Color(.secondarySystemFill).overlay(ProgressView().tint(.gray))
                    }
                }
                .processors([.resize(width: 200)])
                .frame(width: 110, height: 160)
                .cornerRadius(8)
                .clipped()
            } else {
                ZStack {
                    Color(.secondarySystemFill)
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

// MARK: - Plugin Search Result Model

struct PluginSearchResult: Identifiable {
    let id: String
    let title: String
    let cover: String?
    let subtitle: String?
    let destination: AnyView
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
            .background(isSelected ? Color(.secondarySystemFill) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Plugin Result Row

private struct PluginResultRow: View {
    let result: PluginSearchResult

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let coverURL = result.cover, let url = URL(string: coverURL) {
                LazyImage(url: url) { state in
                    if let image = state.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color(.secondarySystemFill)
                    }
                }
                .processors([.resize(width: 100)])
                .frame(width: 50, height: 72)
                .cornerRadius(8)
                .clipped()
            } else {
                Color(.secondarySystemFill)
                    .frame(width: 50, height: 72)
                    .cornerRadius(8)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(result.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle = result.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

// MARK: - Hero Badge

private struct DiscoverHeroBadge: View {
    let label: String
    var body: some View {
        Text(label).font(.caption2.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.white.opacity(0.2)).foregroundColor(.white).cornerRadius(6)
    }
}

// MARK: - Helpers

private func stripHTMLDiscover(_ string: String) -> String {
    var result = string
    if let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) {
        let range = NSRange(result.startIndex..., in: result)
        result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
    }
    let entities: [(String, String)] = [
        ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
        ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "),
        ("<br>", "\n"), ("<br/>", "\n"), ("<br />", "\n")
    ]
    for (entity, replacement) in entities {
        result = result.replacingOccurrences(of: entity, with: replacement)
    }
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
}

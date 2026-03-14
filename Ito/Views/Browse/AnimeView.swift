import SwiftUI
import Nuke
import NukeUI
import ito_runner

// MARK: - Helpers

private struct IdentifiableEpisode: Identifiable {
    let id: String
    let episode: Anime.Episode
    init(_ episode: Anime.Episode) {
        self.id = episode.key
        self.episode = episode
    }
}

private let episodeDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .none
    return f
}()

private func stripHTML(_ string: String) -> String {
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

// MARK: - Episode Sort & Filter

private enum EpisodeSortOrder: String, CaseIterable {
    case episodeDescending = "Episode: High to Low"
    case episodeAscending  = "Episode: Low to High"
    case dateDescending    = "Date: Newest First"
    case dateAscending     = "Date: Oldest First"

    var icon: String {
        switch self {
        case .episodeDescending: return "arrow.down.to.line"
        case .episodeAscending:  return "arrow.up.to.line"
        case .dateDescending:    return "calendar.badge.clock"
        case .dateAscending:     return "calendar"
        }
    }
}

private enum EpisodeFilterOption: String, CaseIterable {
    case all       = "All"
    case unwatched = "Unwatched"
    case watched   = "Watched"

    var icon: String {
        switch self {
        case .all:       return "list.bullet"
        case .unwatched: return "circle"
        case .watched:   return "checkmark.circle.fill"
        }
    }
}

// MARK: - Constants

private let animeHeroHeight: CGFloat = 340

// MARK: - Nav Title Preference Key

private struct AnimeNavTitleKey: PreferenceKey {
    static var defaultValue: Bool = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = nextValue()
    }
}

// MARK: - AnimeView

struct AnimeView: View {
    let runner: ItoRunner
    @State var anime: Anime
    let pluginId: String

    @State private var isLoaded = false
    @State private var errorMessage: String?
    @State private var watchingEpisode: IdentifiableEpisode?
    @State private var selectedSeason: String?

    @State private var showTrackerSearch = false
    @State private var trackingMedia: AnilistMedia?
    @State private var isDescriptionExpanded = false
    @State private var showNavTitle = false

    // Episode sort & filter
    @State private var sortOrder: EpisodeSortOrder = .episodeDescending
    @State private var filterOption: EpisodeFilterOption = .all

    @ObservedObject var libraryManager = LibraryManager.shared
    @EnvironmentObject var progressManager: ReadProgressManager

    // MARK: Derived state

    private var isSaved: Bool { libraryManager.isSaved(id: anime.key) }
    private var isTracked: Bool { TrackerManager.shared.getAnilistId(for: anime.key) != nil }

    private var cleanDescription: String? {
        guard let desc = anime.description, !desc.isEmpty else { return nil }
        return stripHTML(desc)
    }

    /// Episodes for the currently selected season, with sort and filter applied.
    private var displayedEpisodes: [Anime.Episode] {
        guard let episodes = anime.episodes else { return [] }

        // Watch state filter — episodes are already scoped to the selected season
        // by the runner when selectedSeason changes and triggers a reload
        let filtered: [Anime.Episode]
        switch filterOption {
        case .all:
            filtered = episodes
        case .unwatched:
            filtered = episodes.filter {
                !progressManager.isRead(mangaId: anime.key, chapterId: $0.key, chapterNum: $0.episode)
            }
        case .watched:
            filtered = episodes.filter {
                progressManager.isRead(mangaId: anime.key, chapterId: $0.key, chapterNum: $0.episode)
            }
        }

        // Sort
        switch sortOrder {
        case .episodeDescending:
            return filtered.sorted {
                ($0.episode ?? -Float.infinity) > ($1.episode ?? -Float.infinity)
            }
        case .episodeAscending:
            return filtered.sorted {
                ($0.episode ?? Float.infinity) < ($1.episode ?? Float.infinity)
            }
        case .dateDescending:
            return filtered.sorted { ($0.dateUpdated ?? 0) > ($1.dateUpdated ?? 0) }
        case .dateAscending:
            return filtered.sorted { ($0.dateUpdated ?? 0) < ($1.dateUpdated ?? 0) }
        }
    }

    // MARK: Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                heroHeader
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: AnimeNavTitleKey.self,
                                value: geo.frame(in: .global).maxY < 0
                            )
                        }
                    )
                contentSection
            }
        }
        .onPreferenceChange(AnimeNavTitleKey.self) { heroGone in
            withAnimation(.easeInOut(duration: 0.18)) { showNavTitle = heroGone }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if showNavTitle {
                    Text(anime.title)
                        .font(.headline)
                        .lineLimit(1)
                        .transition(.opacity)
                }
            }
        }
        .sheet(isPresented: $showTrackerSearch) {
                    // UPDATED: Added `, _` to accept the status parameter
                    TrackerSearchSheet(title: anime.title, isAnime: true) { media, progress, _ in
                        TrackerManager.shared.link(localId: anime.key, anilistId: media.id)
                        if let prog = progress,
                           UserDefaults.standard.object(forKey: "Ito.AutoSyncAnilistToLocal") as? Bool ?? true {
                            ReadProgressManager.shared.markReadUpTo(mangaId: anime.key, maxChapterNum: Float(prog))
                        }
                    }
                }
                .sheet(item: $trackingMedia) { media in
                    NavigationView {
                        TrackerDetailsSheet(
                            media: media,
                            showCancelButton: true,
                            // UPDATED: Added `, _` to accept the status parameter
                            onSave: { progress, _ in
                                if let prog = progress,
                                   UserDefaults.standard.object(forKey: "Ito.AutoSyncAnilistToLocal") as? Bool ?? true {
                                    ReadProgressManager.shared.markReadUpTo(mangaId: anime.key, maxChapterNum: Float(prog))
                                }
                            },
                            onDelete: { TrackerManager.shared.unlink(localId: anime.key) }
                        )
                    }
        }
        .fullScreenCover(item: $watchingEpisode) { identified in
            VideoPlayerView(runner: runner, anime: anime, episode: identified.episode)
        }
        .task { await loadDetails() }
        .refreshable { await loadDetails(force: true) }
    }

    // MARK: - Hero Header

    private var heroHeader: some View {
        ZStack(alignment: .bottom) {
            coverBackground

            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .black.opacity(0.15), location: 0.4),
                    .init(color: .black.opacity(0.72), location: 1.0)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)

            HStack(alignment: .bottom, spacing: 14) {
                sharpCoverView
                heroMetadata.padding(.bottom, 20)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .frame(height: animeHeroHeight)
        .ignoresSafeArea(edges: .top)
    }

    @ViewBuilder
    private var coverBackground: some View {
        if let coverURL = anime.cover, let url = URL(string: coverURL) {
            LazyImage(url: url) { state in
                if let image = state.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                        .blur(radius: 28, opaque: true)
                } else {
                    Color(.secondarySystemBackground)
                }
            }
            .processors([.resize(width: 400)])
            .frame(maxWidth: .infinity)
            .frame(height: animeHeroHeight)
            .clipped()
            .ignoresSafeArea(edges: .top)
            .overlay(Color.black.opacity(0.35))
        } else {
            Color(.secondarySystemBackground)
                .frame(height: animeHeroHeight)
                .ignoresSafeArea(edges: .top)
        }
    }

    private var sharpCoverView: some View {
        Group {
            if let coverURL = anime.cover, let url = URL(string: coverURL) {
                LazyImage(url: url) { state in
                    if let image = state.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else if state.error != nil {
                        Color(.secondarySystemFill)
                    } else {
                        Color(.secondarySystemFill).overlay(ProgressView().tint(.white))
                    }
                }
                // Same processor as background — shares Nuke cache, one request
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

    private var heroMetadata: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(anime.title)
                .font(.title2).fontWeight(.bold)
                .foregroundColor(.white)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .shadow(color: .black.opacity(0.4), radius: 4, x: 0, y: 1)

            if let studios = anime.studios, !studios.isEmpty {
                Text(studios.joined(separator: ", "))
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(1)
            }

            HStack(spacing: 6) {
                if let label = statusLabel(for: anime.status) {
                    AnimeHeroBadge(label: label)
                }
                AnimeHeroBadge(label: pluginId.capitalized)
            }
        }
    }

    // MARK: - Content Section

    private var contentSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            actionButtons.padding(.horizontal, 16).padding(.top, 16)

            if let tags = anime.tags, !tags.isEmpty { tagsRow(tags: tags) }
            if let desc = cleanDescription { descriptionSection(desc) }

            Divider().padding(.horizontal, 16)

            episodeSection
        }
        .padding(.bottom, 16)
        .background(Color(.systemBackground))
    }

    // MARK: Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button {
                LibraryManager.shared.toggleSaveAnime(anime: anime, pluginId: pluginId)
            } label: {
                Label(isSaved ? "Saved" : "Save",
                      systemImage: isSaved ? "bookmark.fill" : "bookmark")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
            }
            .tint(isSaved ? .blue : .secondary)
            .buttonStyle(.bordered)
            .controlSize(.regular)

            if TrackerManager.shared.isAnilistAuthenticated {
                Button {
                    if isTracked {
                        let existingId = TrackerManager.shared.getAnilistId(for: anime.key)!
                        trackingMedia = AnilistMedia(
                            id: existingId, title: anime.title, titleRomaji: nil,
                            coverImage: anime.cover, format: "TV", episodes: nil, chapters: nil)
                    } else {
                        showTrackerSearch = true
                    }
                } label: {
                    Label(isTracked ? "Tracking" : "Track",
                          systemImage: isTracked ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .tint(isTracked ? .purple : .green)
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        }
    }

    // MARK: Tags

    private func tagsRow(tags: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tags, id: \.self) { tag in
                    Text(tag).font(.caption).lineLimit(1)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color(.tertiarySystemFill)).cornerRadius(12)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: Description

    private func descriptionSection(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).font(.subheadline).foregroundStyle(.primary)
                .lineLimit(isDescriptionExpanded ? nil : 3)
                .animation(.easeInOut(duration: 0.2), value: isDescriptionExpanded)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isDescriptionExpanded.toggle() }
            } label: {
                Text(isDescriptionExpanded ? "Show less" : "Show more")
                    .font(.caption).fontWeight(.semibold).foregroundStyle(.blue)
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Episode Section

    @ViewBuilder
    private var episodeSection: some View {
        if !isLoaded && errorMessage == nil {
            ProgressView("Loading episodes…").frame(maxWidth: .infinity).padding(.vertical, 32)
        } else if let error = errorMessage {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 36, weight: .thin)).foregroundStyle(.red)
                Text(error).font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.vertical, 32)
        } else if let episodes = anime.episodes, !episodes.isEmpty {
            episodeListHeader(allEpisodes: episodes, displayed: displayedEpisodes)
            episodeList(episodes: displayedEpisodes)
        } else {
            Text("No episodes found.").font(.subheadline).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 32)
        }
    }

    // MARK: Episode List Header

    private func episodeListHeader(allEpisodes: [Anime.Episode], displayed: [Anime.Episode]) -> some View {
        VStack(alignment: .leading, spacing: 12) {

            // Resume / Start — always from full unfiltered list
            if let target = resumeEpisode(from: allEpisodes) {
                let isResume = progressManager.getLastRead(mangaId: anime.key) != nil
                Button {
                    watchingEpisode = IdentifiableEpisode(target)
                } label: {
                    Label(isResume ? "Resume Watching" : "Start Watching",
                          systemImage: isResume ? "play.fill" : "play.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.blue)
                .padding(.horizontal, 16)
            }

            // Season picker — only shown when seasons exist
            if let seasons = anime.seasons, seasons.count > 1 {
                Picker("Season", selection: $selectedSeason) {
                    ForEach(seasons, id: \.key) { season in
                        Text(season.title).tag(season.key as String?)
                    }
                }
                .pickerStyle(.menu)
                .padding(.horizontal, 16)
            }

            // "Episodes · N" + filter menu
            let allCount = anime.episodes?.count ?? 0
            let isFiltered = filterOption != .all || sortOrder != .episodeDescending

            HStack(alignment: .center) {
                HStack(spacing: 5) {
                    Text("Episodes").font(.title3).fontWeight(.bold)
                    if filterOption == .all {
                        Text("· \(allCount)").font(.title3).foregroundStyle(.tertiary)
                    } else {
                        Text("· \(displayed.count) of \(allCount)")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Menu {
                    Section("Sort Order") {
                        ForEach(EpisodeSortOrder.allCases, id: \.self) { order in
                            Button {
                                withAnimation { sortOrder = order }
                            } label: {
                                Label(order.rawValue,
                                      systemImage: sortOrder == order ? "checkmark" : order.icon)
                            }
                        }
                    }

                    Section("Show") {
                        ForEach(EpisodeFilterOption.allCases, id: \.self) { option in
                            Button {
                                withAnimation { filterOption = option }
                            } label: {
                                Label(option.rawValue,
                                      systemImage: filterOption == option ? "checkmark" : option.icon)
                            }
                        }
                    }

                    if isFiltered {
                        Divider()
                        Button(role: .destructive) {
                            withAnimation {
                                sortOrder = .episodeDescending
                                filterOption = .all
                            }
                        } label: {
                            Label("Reset Filters", systemImage: "arrow.counterclockwise")
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isFiltered
                              ? "line.3.horizontal.decrease.circle.fill"
                              : "line.3.horizontal.decrease.circle")
                            .font(.system(size: 20))
                        if isFiltered {
                            Text("Filtered").font(.caption).fontWeight(.medium)
                        }
                    }
                    .foregroundStyle(isFiltered ? Color.blue : Color.secondary)
                    .animation(.easeInOut(duration: 0.15), value: isFiltered)
                }
            }
            .padding(.horizontal, 16)

            // Active filter pills
            if isFiltered {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if sortOrder != .episodeDescending {
                            AnimeActiveFilterPill(label: sortOrder.rawValue) {
                                withAnimation { sortOrder = .episodeDescending }
                            }
                        }
                        if filterOption != .all {
                            AnimeActiveFilterPill(label: filterOption.rawValue) {
                                withAnimation { filterOption = .all }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: Episode List

    private func episodeList(episodes: [Anime.Episode]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(episodes, id: \.key) { episode in
                let isWatched = progressManager.isRead(
                    mangaId: anime.key, chapterId: episode.key, chapterNum: episode.episode)
                EpisodeRowView(episode: episode, isWatched: isWatched) {
                    watchingEpisode = IdentifiableEpisode(episode)
                }
                Divider().padding(.leading, 16)
            }
        }
    }

    // MARK: - Helpers

    private func loadDetails(force: Bool = false) async {
        guard !isLoaded || force else { return }
        do {
            let updated = try await runner.getAnimeUpdate(
                anime: anime, needsDetails: true, needsEpisodes: true)
            await MainActor.run {
                anime = updated
                // Auto-select the current season, falling back to first
                if let first = updated.seasons?.first(where: { $0.isCurrent })
                    ?? updated.seasons?.first {
                    selectedSeason = first.key
                }
                isLoaded = true
                errorMessage = nil
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isLoaded = true
            }
        }
    }

    private func resumeEpisode(from episodes: [Anime.Episode]) -> Anime.Episode? {
        guard !episodes.isEmpty else { return nil }
        // Sort ascending by episode number so we always start from ep 1,
        // regardless of the order the plugin returns the array in.
        let ascending = episodes.sorted {
            ($0.episode ?? Float.infinity) < ($1.episode ?? Float.infinity)
        }
        // Return the first unwatched episode in ascending order
        if let firstUnwatched = ascending.first(where: {
            !progressManager.isRead(mangaId: anime.key, chapterId: $0.key, chapterNum: $0.episode)
        }) {
            return firstUnwatched
        }
        // All watched — return the last episode (highest number)
        return ascending.last
    }

    private func statusLabel(for status: Anime.Status) -> String? {
        switch status {
        case .Unknown:   return nil
        case .Ongoing:   return "Ongoing"
        case .Completed: return "Completed"
        case .Cancelled: return "Cancelled"
        case .Hiatus:    return "Hiatus"
        }
    }
}

// MARK: - Episode Row

private struct EpisodeRowView: View {
    let episode: Anime.Episode
    let isWatched: Bool
    let onTap: () -> Void

    @State private var isPressed = false

    private var episodeTitle: String {
        if let title = episode.title, !title.isEmpty { return title }
        if let num = episode.episode {
            let isWhole = num.truncatingRemainder(dividingBy: 1) == 0
            return "Episode \(isWhole ? String(Int(num)) : String(num))"
        }
        return "Episode —"
    }

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(episodeTitle)
                        .font(.subheadline)
                        .fontWeight(isWatched ? .regular : .semibold)
                        .foregroundStyle(isWatched ? Color.secondary : Color.primary)
                        .lineLimit(2)

                    HStack(spacing: 4) {
                        if let timestamp = episode.dateUpdated {
                            Text(episodeDateFormatter.string(
                                from: Date(timeIntervalSince1970: timestamp)))
                                .font(.caption).foregroundStyle(Color.secondary)
                        }
                        if let lang = episode.lang, !lang.isEmpty {
                            if episode.dateUpdated != nil {
                                Text("·").font(.caption).foregroundStyle(Color.secondary)
                            }
                            Text(lang.uppercased())
                                .font(.caption2).fontWeight(.semibold)
                                .foregroundStyle(Color.secondary)
                        }
                    }
                }

                Spacer()

                // Trailing: watched check or play icon
                if isWatched {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.secondary)
                } else {
                    Image(systemName: "play.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.blue)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(isPressed ? Color(.systemFill) : Color(.systemBackground))
            .contentShape(Rectangle())
        }
        .buttonStyle(AnimePressRecordingButtonStyle(isPressed: $isPressed))
    }
}

// MARK: - Reusable Components

private struct AnimePressRecordingButtonStyle: ButtonStyle {
    @Binding var isPressed: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { pressed in isPressed = pressed }
    }
}

private struct AnimeHeroBadge: View {
    let label: String
    var body: some View {
        Text(label).font(.caption2).fontWeight(.medium)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.white.opacity(0.2)).foregroundColor(.white).cornerRadius(5)
    }
}

private struct AnimeActiveFilterPill: View {
    let label: String
    let onRemove: () -> Void
    var body: some View {
        Button(action: onRemove) {
            HStack(spacing: 4) {
                Text(label).font(.caption).fontWeight(.medium)
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color.blue.opacity(0.12))
            .foregroundStyle(Color.blue)
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }
}

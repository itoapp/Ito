import SwiftUI
import Combine
import GRDB
import ito_runner

private struct NavTitleVisibilityKey: PreferenceKey {
    static var defaultValue: Bool = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = nextValue()
    }
}

public struct IdentifiableChapter<C: ChapterDisplayable>: Identifiable {
    public let id: String
    public let chapter: C
    public init(_ chapter: C) {
        self.id = chapter.key
        self.chapter = chapter
    }
}

public enum ChapterSortOrder: String, CaseIterable {
    case descending = "High to Low"
    case ascending  = "Low to High"
    case dateDescending = "Newest First"
    case dateAscending  = "Oldest First"

    public var icon: String {
        switch self {
        case .descending: return "arrow.down.to.line"
        case .ascending:  return "arrow.up.to.line"
        case .dateDescending: return "calendar.badge.clock"
        case .dateAscending:  return "calendar"
        }
    }
}

public enum ChapterFilterOption: String, CaseIterable {
    case all = "All"
    case unread = "Unread/Unwatched"
    case read = "Read/Watched"

    public var icon: String {
        switch self {
        case .all: return "list.bullet"
        case .unread: return "circle"
        case .read: return "checkmark.circle.fill"
        }
    }
}

@MainActor
public class MediaDetailViewModel<M: MediaDisplayable>: ObservableObject {
    public let objectWillChange = PassthroughSubject<Void, Never>()

    public var media: M { willSet { objectWillChange.send() } }
    public var isLoaded = false { willSet { objectWillChange.send() } }
    public var errorMessage: String? { willSet { objectWillChange.send() } }
    public var sortOrder: ChapterSortOrder = .descending { willSet { objectWillChange.send() } }
    public var filterOption: ChapterFilterOption = .all { willSet { objectWillChange.send() } }
    public var selectedGroup: String? { willSet { objectWillChange.send() } }

    public let pluginId: String
    private let loader: (M) async throws -> M

    public init(media: M, pluginId: String, loader: @escaping (M) async throws -> M) {
        self.media = media
        self.pluginId = pluginId
        self.loader = loader

        if let anime = media as? Anime {
            if let first = anime.seasons?.first(where: { $0.isCurrent }) ?? anime.seasons?.first {
                self.selectedGroup = first.key
            }
        }
    }

    public func loadDetails(force: Bool = false) async {
        guard !isLoaded || force else { return }
        do {
            let updated = try await loader(media)
            self.media = updated
            if let anime = updated as? Anime {
                if let first = anime.seasons?.first(where: { $0.isCurrent }) ?? anime.seasons?.first {
                    self.selectedGroup = first.key
                }
            }
            self.isLoaded = true
            self.errorMessage = nil

            // Advance baseline and clear badge if the item is in the library
            let isSaved = LibraryManager.shared.isSaved(id: media.key)
            if isSaved {
                let count = updated.chapterList?.count ?? 0
                let currentMediaKey = media.key
                Task {
                    do {
                        try await AppDatabase.shared.dbPool.write { db in
                            if var dbItem = try LibraryItem.fetchOne(db, key: currentMediaKey) {
                                dbItem.knownChapterCount = count
                                try dbItem.update(db)
                            }
                        }
                    } catch {
                        print("Failed to update knownChapterCount on appear: \(error)")
                    }
                }
                Task { @MainActor in
                    UpdateManager.shared.clearBadge(for: currentMediaKey)
                }
            }
        } catch {
            self.errorMessage = error.localizedDescription
            self.isLoaded = true
        }
    }

    public func displayedChapters(progressManager: ReadProgressManager) -> [M.Chapter] {
        guard let chapters = media.chapterList else { return [] }

        // Filter
        let filtered: [M.Chapter]
        switch filterOption {
        case .all:
            filtered = chapters
        case .unread:
            filtered = chapters.filter { !progressManager.isRead(mangaId: media.key, chapterId: $0.key, chapterNum: $0.chapterNumber) }
        case .read:
            filtered = chapters.filter { progressManager.isRead(mangaId: media.key, chapterId: $0.key, chapterNum: $0.chapterNumber) }
        }

        // Sort
        switch sortOrder {
        case .descending:
            return filtered.sorted { ($0.chapterNumber ?? -Float.infinity) > ($1.chapterNumber ?? -Float.infinity) }
        case .ascending:
            return filtered.sorted { ($0.chapterNumber ?? Float.infinity) < ($1.chapterNumber ?? Float.infinity) }
        case .dateDescending:
            return filtered.sorted { ($0.dateUpload ?? "") > ($1.dateUpload ?? "") }
        case .dateAscending:
            return filtered.sorted { ($0.dateUpload ?? "") < ($1.dateUpload ?? "") }
        }
    }

    public func resumeChapter(progressManager: ReadProgressManager) -> M.Chapter? {
        guard let chapters = media.chapterList, !chapters.isEmpty else { return nil }
        let ascending = chapters.sorted { ($0.chapterNumber ?? Float.infinity) < ($1.chapterNumber ?? Float.infinity) }
        if let firstUnread = ascending.first(where: {
            !progressManager.isRead(mangaId: media.key, chapterId: $0.key, chapterNum: $0.chapterNumber)
        }) {
            return firstUnread
        }
        return ascending.last
    }

    /// Returns `true` if a new item was saved (used by the view to decide sheet vs snackbar).
    @discardableResult
    public func toggleSave() -> Bool {
        let currentlySaved = LibraryManager.shared.isSaved(id: media.key)

        if let manga = media as? Manga {
            LibraryManager.shared.toggleSaveManga(manga: manga, pluginId: pluginId)
        } else if let anime = media as? Anime {
            LibraryManager.shared.toggleSaveAnime(anime: anime, pluginId: pluginId)
        } else if let novel = media as? Novel {
            LibraryManager.shared.toggleSaveNovel(novel: novel, pluginId: pluginId)
        }

        return !currentlySaved
    }
}

public struct MediaDetailView<M: MediaDisplayable>: View {
    let runner: ItoRunner
    @StateObject var viewModel: MediaDetailViewModel<M>

    @EnvironmentObject var progressManager: ReadProgressManager
    @ObservedObject var libraryManager = LibraryManager.shared

    @AppStorage(UserDefaultsKeys.alwaysShowCategoryPicker) private var alwaysShowCategoryPicker: Bool = false

    @State private var showTrackerSearch = false
    @State private var showNavTitle = false
    @State private var readingChapter: IdentifiableChapter<M.Chapter>?
    @State private var showCategoryAssignment = false
    @State private var themeDominant: Color?
    @State private var themeSecondary: Color?

    public init(runner: ItoRunner, media: M, pluginId: String, loader: @escaping (M) async throws -> M) {
        self.runner = runner
        self._viewModel = StateObject(wrappedValue: MediaDetailViewModel(media: media, pluginId: pluginId, loader: loader))
    }

    private var isSaved: Bool { libraryManager.isSaved(id: viewModel.media.key) }
    private var isTracked: Bool { TrackerManager.shared.trackerMappings[viewModel.media.key]?.isEmpty == false }

    public var body: some View {
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
                    title: viewModel.media.title,
                    coverURL: viewModel.media.cover,
                    authorOrStudio: viewModel.media.studios?.joined(separator: ", ") ?? viewModel.media.authors?.joined(separator: ", "),
                    statusLabel: viewModel.media.displayStatus,
                    pluginId: viewModel.pluginId,
                    onImageLoaded: { uiImage in
                        Task {
                            await ThemeManager.shared.extractAndCache(image: uiImage, for: viewModel.media.key)
                            if let theme = await ThemeManager.shared.getTheme(for: viewModel.media.key) {
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
                            key: NavTitleVisibilityKey.self,
                            value: geo.frame(in: .global).maxY < 0
                        )
                    }
                )

                SharedDetailContent(
                    isSaved: isSaved,
                    isTracked: isTracked,
                    tags: viewModel.media.tags,
                    cleanDescription: viewModel.media.description?.strippingHTML(),
                    themeSecondary: themeSecondary,
                    onSaveToggle: {
                        let didSaveNew = viewModel.toggleSave()
                        if didSaveNew {
                            let hasCustomCategories = libraryManager.categories.filter({ !$0.isSystemCategory }).count > 0
                            if alwaysShowCategoryPicker && hasCustomCategories {
                                showCategoryAssignment = true
                            } else {
                                SnackBarManager.shared.showSaved(itemId: viewModel.media.key)
                            }
                        }
                    },
                    onTrackToggle: TrackerManager.shared.authenticatedProviders.isEmpty ? nil : { showTrackerSearch = true }
                )

                chapterSection
            }
        }
        .background(Color.clear)
        }
        .onPreferenceChange(NavTitleVisibilityKey.self) { hidden in
            withAnimation(.easeInOut(duration: 0.18)) { showNavTitle = hidden }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if showNavTitle {
                    Text(viewModel.media.title).font(.headline).lineLimit(1).transition(.opacity)
                }
            }
        }
        .sheet(isPresented: $showTrackerSearch) {
            TrackerSheetOrchestrator(localId: viewModel.media.key, title: viewModel.media.title, isAnime: viewModel.media is Anime) { _, progress, _ in
                if let prog = progress, UserDefaults.standard.object(forKey: "Ito.AutoSyncTrackersToLocal") as? Bool ?? true {
                    ReadProgressManager.shared.markReadUpTo(mangaId: viewModel.media.key, maxChapterNum: Float(prog))
                }
            }
        }
        .fullScreenCover(item: $readingChapter) { wrapper in
            if let manga = viewModel.media as? Manga, let chapter = wrapper.chapter as? Manga.Chapter {
                ReaderView(runner: runner, pluginId: viewModel.pluginId, manga: manga, currentChapter: chapter)
            } else if let anime = viewModel.media as? Anime, let ep = wrapper.chapter as? Anime.Episode {
                VideoPlayerView(runner: runner, pluginId: viewModel.pluginId, anime: anime, episode: ep)
            } else if let novel = viewModel.media as? Novel, let ch = wrapper.chapter as? Novel.Chapter {
                NovelReaderView(runner: runner, pluginId: viewModel.pluginId, novel: novel, currentChapter: ch)
            } else {
                Text("Unsupported media type")
            }
        }
        .sheet(isPresented: $showCategoryAssignment) {
            NavigationView {
                CategoryAssignmentSheet(itemId: viewModel.media.key)
            }
        }
        .task {
            if let theme = await ThemeManager.shared.getTheme(for: viewModel.media.key) {
                self.themeDominant = Color(hex: theme.dominantHex)
                self.themeSecondary = Color(hex: theme.secondaryHex)
            }
            await viewModel.loadDetails()
        }
        .onAppear {
            let anilistId = TrackerManager.shared.getMediaId(for: viewModel.media.key, providerId: "anilist")
            let isAnime = viewModel.media is Anime
            let url = anilistId.flatMap { "https://anilist.co/\(isAnime ? "anime" : "manga")/\($0)" }
            let pluginName = PluginManager.shared.installedPlugins[viewModel.pluginId]?.info.name ?? "Unknown Plugin"

            DiscordRPCManager.shared.setActivity(
                details: viewModel.media.title,
                state: "Viewing Details",
                activityType: 3,
                detailsUrl: url,
                largeImageText: "Browsing at \(pluginName)",
                imageUrl: viewModel.media.cover,
                resetTimer: true
            )
        }
        .onDisappear {
            DiscordRPCManager.shared.clearActivity()
        }
        .refreshable { await viewModel.loadDetails(force: true) }
        .onChange(of: viewModel.selectedGroup) { _ in
            // Filtering episodes by season is handled locally in the view model if needed.
        }
    }

    @ViewBuilder
    private var chapterSection: some View {
        if !viewModel.isLoaded && viewModel.errorMessage == nil {
            ProgressView("Loading...").frame(maxWidth: .infinity).padding(.vertical, 32)
        } else if let error = viewModel.errorMessage {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 36, weight: .thin)).foregroundStyle(.red)
                Text(error).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.vertical, 32)
        } else if let chapters = viewModel.media.chapterList, !chapters.isEmpty {
            let displayed = viewModel.displayedChapters(progressManager: progressManager)
            chapterListHeader(allChapters: chapters, displayedChapters: displayed)
            chapterList(chapters: displayed)
        } else {
            Text("No content found.").font(.subheadline).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 32)
        }
    }

    private func chapterListHeader(allChapters: [M.Chapter], displayedChapters: [M.Chapter]) -> some View {
        VStack(alignment: .leading, spacing: 12) {

            if let target = viewModel.resumeChapter(progressManager: progressManager) {
                let isResume = progressManager.getLastRead(mangaId: viewModel.media.key) != nil
                Button {
                    readingChapter = IdentifiableChapter(target)
                } label: {
                    Label(
                        isResume ? "Resume" : "Start",
                        systemImage: viewModel.media is Anime ? "play.fill" : (isResume ? "book.fill" : "play.fill")
                    )
                    .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity)
                }
                .tint(themeSecondary ?? .blue)
                .buttonStyle(.borderedProminent).controlSize(.large).padding(.horizontal, 16)
            }

            if let anime = viewModel.media as? Anime, let seasons = anime.seasons, seasons.count > 1 {
                Picker("Season", selection: $viewModel.selectedGroup) {
                    ForEach(seasons, id: \.key) { season in
                        Text(season.title).tag(season.key as String?)
                    }
                }
                .pickerStyle(.menu)
                .padding(.horizontal, 16)
            }

            let titleStr = viewModel.media is Anime ? "Episodes" : "Chapters"
            let isFiltered = viewModel.filterOption != .all || viewModel.sortOrder != .descending

            HStack(alignment: .center) {
                HStack(spacing: 5) {
                    Text(titleStr).font(.title3).fontWeight(.bold)
                    if viewModel.filterOption == .all {
                        Text("· \(allChapters.count)").font(.title3).foregroundStyle(.tertiary)
                    } else {
                        Text("· \(displayedChapters.count) of \(allChapters.count)")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Menu {
                    Section("Sort Order") {
                        ForEach(ChapterSortOrder.allCases, id: \.self) { order in
                            Button {
                                withAnimation { viewModel.sortOrder = order }
                            } label: {
                                Label(order.rawValue, systemImage: viewModel.sortOrder == order ? "checkmark" : order.icon)
                            }
                        }
                    }

                    Section("Show") {
                        ForEach(ChapterFilterOption.allCases, id: \.self) { option in
                            Button {
                                withAnimation { viewModel.filterOption = option }
                            } label: {
                                Label(option.rawValue, systemImage: viewModel.filterOption == option ? "checkmark" : option.icon)
                            }
                        }
                    }

                    if isFiltered {
                        Divider()
                        Button(role: .destructive) {
                            withAnimation { viewModel.sortOrder = .descending; viewModel.filterOption = .all }
                        } label: {
                            Label("Reset Filters", systemImage: "arrow.counterclockwise")
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isFiltered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
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

            if isFiltered {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if viewModel.sortOrder != .descending {
                            ActiveFilterPill(label: viewModel.sortOrder.rawValue) {
                                withAnimation { viewModel.sortOrder = .descending }
                            }
                        }
                        if viewModel.filterOption != .all {
                            ActiveFilterPill(label: viewModel.filterOption.rawValue) {
                                withAnimation { viewModel.filterOption = .all }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func chapterList(chapters: [M.Chapter]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(chapters, id: \.key) { chapter in
                let isRead = progressManager.isRead(mangaId: viewModel.media.key, chapterId: chapter.key, chapterNum: chapter.chapterNumber)
                ChapterRowView(chapter: chapter, isRead: isRead) {
                    readingChapter = IdentifiableChapter(chapter)
                }
                Divider().padding(.leading, 16)
            }
        }
    }
}

private struct ActiveFilterPill: View {
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

import SwiftUI
import Nuke
import NukeUI
import ito_runner

// MARK: - Helpers

private struct IdentifiableChapter: Identifiable {
    let id: String
    let chapter: Manga.Chapter
    init(_ chapter: Manga.Chapter) {
        self.id = chapter.key
        self.chapter = chapter
    }
}

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

private let chapterDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .none
    return f
}()

// MARK: - Chapter Sort & Filter

private enum ChapterSortOrder: String, CaseIterable {
    case chapterDescending = "Chapter: High to Low"
    case chapterAscending  = "Chapter: Low to High"
    case dateDescending    = "Date: Newest First"
    case dateAscending     = "Date: Oldest First"

    var icon: String {
        switch self {
        case .chapterDescending: return "arrow.down.to.line"
        case .chapterAscending:  return "arrow.up.to.line"
        case .dateDescending:    return "calendar.badge.clock"
        case .dateAscending:     return "calendar"
        }
    }
}

private enum ChapterFilterOption: String, CaseIterable {
    case all    = "All"
    case unread = "Unread"
    case read   = "Read"

    var icon: String {
        switch self {
        case .all:    return "list.bullet"
        case .unread: return "circle"
        case .read:   return "checkmark.circle.fill"
        }
    }
}

// MARK: - Constants

private let heroHeight: CGFloat = 340

// MARK: - Nav Title Preference Key

private struct NavTitleVisibilityKey: PreferenceKey {
    static var defaultValue: Bool = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = nextValue()
    }
}

// MARK: - MangaView

struct MangaView: View {
    let runner: ItoRunner
    @State var manga: Manga
    let pluginId: String

    @State private var isLoaded = false
    @State private var errorMessage: String?
    @State private var readingChapter: IdentifiableChapter?

    @State private var showTrackerSearch = false
    @State private var trackingMedia: AnilistMedia?
    @State private var isDescriptionExpanded = false
    @State private var showNavTitle = false

    // Chapter sort & filter state
    @State private var sortOrder: ChapterSortOrder = .chapterDescending
    @State private var filterOption: ChapterFilterOption = .all

    @EnvironmentObject var progressManager: ReadProgressManager
    @ObservedObject var libraryManager = LibraryManager.shared

    private var isSaved: Bool { libraryManager.isSaved(id: manga.key) }
    private var isTracked: Bool { TrackerManager.shared.getAnilistId(for: manga.key) != nil }

    private var cleanDescription: String? {
        guard let desc = manga.description, !desc.isEmpty else { return nil }
        return stripHTML(desc)
    }

    /// Applies sort and filter to the raw chapter array from the source.
    private func displayedChapters(from chapters: [Manga.Chapter]) -> [Manga.Chapter] {
        let filtered: [Manga.Chapter]
        switch filterOption {
        case .all:
            filtered = chapters
        case .unread:
            filtered = chapters.filter {
                !progressManager.isRead(mangaId: manga.key, chapterId: $0.key, chapterNum: $0.chapter)
            }
        case .read:
            filtered = chapters.filter {
                progressManager.isRead(mangaId: manga.key, chapterId: $0.key, chapterNum: $0.chapter)
            }
        }

        // Sort — chapter.chapter is Float?, nil chapters sort to end
        switch sortOrder {
        case .chapterDescending:
            return filtered.sorted {
                ($0.chapter ?? -Float.infinity) > ($1.chapter ?? -Float.infinity)
            }
        case .chapterAscending:
            return filtered.sorted {
                ($0.chapter ?? Float.infinity) < ($1.chapter ?? Float.infinity)
            }
        case .dateDescending:
            return filtered.sorted {
                ($0.dateUpdated ?? 0) > ($1.dateUpdated ?? 0)
            }
        case .dateAscending:
            return filtered.sorted {
                ($0.dateUpdated ?? 0) < ($1.dateUpdated ?? 0)
            }
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
                                key: NavTitleVisibilityKey.self,
                                value: geo.frame(in: .global).maxY < 0
                            )
                        }
                    )
                contentSection
            }
        }
        .onPreferenceChange(NavTitleVisibilityKey.self) { heroGone in
            withAnimation(.easeInOut(duration: 0.18)) { showNavTitle = heroGone }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if showNavTitle {
                    Text(manga.title)
                        .font(.headline)
                        .lineLimit(1)
                        .transition(.opacity)
                }
            }
        }
        .sheet(isPresented: $showTrackerSearch) {
            TrackerSearchSheet(title: manga.title, isAnime: false) { media, progress in
                TrackerManager.shared.link(localId: manga.key, anilistId: media.id)
                if let prog = progress,
                   UserDefaults.standard.object(forKey: "Ito.AutoSyncAnilistToLocal") as? Bool ?? true {
                    ReadProgressManager.shared.markReadUpTo(mangaId: manga.key, maxChapterNum: Float(prog))
                }
            }
        }
        .sheet(item: $trackingMedia) { media in
            TrackerDetailsSheet(
                media: media,
                onSave: { progress in
                    if let prog = progress,
                       UserDefaults.standard.object(forKey: "Ito.AutoSyncAnilistToLocal") as? Bool ?? true {
                        ReadProgressManager.shared.markReadUpTo(mangaId: manga.key, maxChapterNum: Float(prog))
                    }
                },
                onDelete: { TrackerManager.shared.unlink(localId: manga.key) }
            )
        }
        .fullScreenCover(item: $readingChapter) { wrapper in
            ReaderView(runner: runner, manga: manga, currentChapter: wrapper.chapter)
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
        .frame(height: heroHeight)
        .ignoresSafeArea(edges: .top)
    }

    @ViewBuilder
    private var coverBackground: some View {
        if let coverURL = manga.cover, let url = URL(string: coverURL) {
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
            .frame(height: heroHeight)
            .clipped()
            .ignoresSafeArea(edges: .top)
            .overlay(Color.black.opacity(0.35))
        } else {
            Color(.secondarySystemBackground)
                .frame(height: heroHeight)
                .ignoresSafeArea(edges: .top)
        }
    }

    private var sharpCoverView: some View {
        Group {
            if let coverURL = manga.cover, let url = URL(string: coverURL) {
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

    private var heroMetadata: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(manga.title)
                .font(.title2).fontWeight(.bold)
                .foregroundColor(.white)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .shadow(color: .black.opacity(0.4), radius: 4, x: 0, y: 1)

            if let artist = manga.artist, !artist.isEmpty {
                Text(artist).font(.subheadline).foregroundColor(.white.opacity(0.8)).lineLimit(1)
            } else if let authors = manga.authors, !authors.isEmpty {
                Text(authors.joined(separator: ", "))
                    .font(.subheadline).foregroundColor(.white.opacity(0.8)).lineLimit(1)
            }

            HStack(spacing: 6) {
                if let label = statusLabel(for: manga.status) { HeroBadge(label: label) }
                HeroBadge(label: pluginId.capitalized)
            }
        }
    }

    // MARK: - Content Section

    private var contentSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            actionButtons.padding(.horizontal, 16).padding(.top, 16)

            if let tags = manga.tags, !tags.isEmpty { tagsRow(tags: tags) }
            if let desc = cleanDescription { descriptionSection(desc) }

            Divider().padding(.horizontal, 16)

            chapterSection
        }
        .padding(.bottom, 16)
        .background(Color(.systemBackground))
    }

    // MARK: Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button {
                LibraryManager.shared.toggleSaveManga(manga: manga, pluginId: pluginId)
            } label: {
                Label(isSaved ? "Saved" : "Save", systemImage: isSaved ? "bookmark.fill" : "bookmark")
                    .font(.subheadline.weight(.medium)).frame(maxWidth: .infinity)
            }
            .tint(isSaved ? .blue : .secondary).buttonStyle(.bordered).controlSize(.regular)

            if TrackerManager.shared.isAnilistAuthenticated {
                Button {
                    if isTracked {
                        let existingId = TrackerManager.shared.getAnilistId(for: manga.key)!
                        trackingMedia = AnilistMedia(id: existingId, title: manga.title,
                            titleRomaji: nil, coverImage: manga.cover,
                            format: "MANGA", episodes: nil, chapters: nil)
                    } else {
                        showTrackerSearch = true
                    }
                } label: {
                    Label(
                        isTracked ? "Tracking" : "Track",
                        systemImage: isTracked ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath"
                    )
                    .font(.subheadline.weight(.medium)).frame(maxWidth: .infinity)
                }
                .tint(isTracked ? .purple : .green).buttonStyle(.bordered).controlSize(.regular)
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

    // MARK: - Chapter Section

    @ViewBuilder
    private var chapterSection: some View {
        if !isLoaded && errorMessage == nil {
            ProgressView("Loading chapters…").frame(maxWidth: .infinity).padding(.vertical, 32)
        } else if let error = errorMessage {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 36, weight: .thin)).foregroundStyle(.red)
                Text(error).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.vertical, 32)
        } else if let chapters = manga.chapters, !chapters.isEmpty {
            let displayed = displayedChapters(from: chapters)
            chapterListHeader(allChapters: chapters, displayedChapters: displayed)
            chapterList(chapters: displayed)
        } else {
            Text("No chapters found.").font(.subheadline).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 32)
        }
    }

    // MARK: Chapter List Header

    private func chapterListHeader(allChapters: [Manga.Chapter], displayedChapters: [Manga.Chapter]) -> some View {
        VStack(alignment: .leading, spacing: 12) {

            // Resume / Start — always driven from full unfiltered list
            if let target = resumeReadingChapter(from: allChapters) {
                let isResume = progressManager.getLastRead(mangaId: manga.key) != nil
                Button {
                    readingChapter = IdentifiableChapter(target)
                } label: {
                    Label(
                        isResume ? "Resume Reading" : "Start Reading",
                        systemImage: isResume ? "book.fill" : "play.fill"
                    )
                    .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).padding(.horizontal, 16)
            }

            // "Chapters · N" + filter menu
            let isFiltered = filterOption != .all || sortOrder != .chapterDescending
            HStack(alignment: .center) {
                HStack(spacing: 5) {
                    Text("Chapters").font(.title3).fontWeight(.bold)
                    if filterOption == .all {
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
                                withAnimation { sortOrder = order }
                            } label: {
                                Label(order.rawValue,
                                      systemImage: sortOrder == order ? "checkmark" : order.icon)
                            }
                        }
                    }

                    Section("Show") {
                        ForEach(ChapterFilterOption.allCases, id: \.self) { option in
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
                            withAnimation { sortOrder = .chapterDescending; filterOption = .all }
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

            // Active filter pills — individually removable
            if isFiltered {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if sortOrder != .chapterDescending {
                            ActiveFilterPill(label: sortOrder.rawValue) {
                                withAnimation { sortOrder = .chapterDescending }
                            }
                        }
                        if filterOption != .all {
                            ActiveFilterPill(label: filterOption.rawValue) {
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

    // MARK: Chapter List

    private func chapterList(chapters: [Manga.Chapter]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(chapters, id: \.key) { chapter in
                let isRead = progressManager.isRead(
                    mangaId: manga.key, chapterId: chapter.key, chapterNum: chapter.chapter)
                ChapterRowView(chapter: chapter, isRead: isRead) {
                    readingChapter = IdentifiableChapter(chapter)
                }
                Divider().padding(.leading, 16)
            }
        }
    }

    // MARK: - Helpers

    private func loadDetails(force: Bool = false) async {
        guard !isLoaded || force else { return }
        do {
            let updated = try await runner.getMangaUpdate(manga: manga)
            await MainActor.run { manga = updated; isLoaded = true; errorMessage = nil }
        } catch {
            await MainActor.run { errorMessage = error.localizedDescription; isLoaded = true }
        }
    }

    private func resumeReadingChapter(from chapters: [Manga.Chapter]) -> Manga.Chapter? {
        guard !chapters.isEmpty else { return nil }
        if let firstUnread = chapters.reversed().first(where: {
            !progressManager.isRead(mangaId: manga.key, chapterId: $0.key, chapterNum: $0.chapter)
        }) { return firstUnread }
        return chapters.first
    }

    private func statusLabel(for status: Manga.Status) -> String? {
        switch status {
        case .Ongoing:   return "Ongoing"
        case .Completed: return "Completed"
        case .Cancelled: return "Cancelled"
        case .Hiatus:    return "Hiatus"
        case .Unknown:   return nil
        }
    }
}

// MARK: - Active Filter Pill

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

// MARK: - Hero Badge

private struct HeroBadge: View {
    let label: String
    var body: some View {
        Text(label).font(.caption2).fontWeight(.medium)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.white.opacity(0.2)).foregroundColor(.white).cornerRadius(5)
    }
}

// MARK: - Chapter Row

private struct ChapterRowView: View {
    let chapter: Manga.Chapter
    let isRead: Bool
    let onTap: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    chapterTitle
                    chapterSubtitle
                }
                Spacer()
                trailingIcon
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(isPressed ? Color(.systemFill) : Color(.systemBackground))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressRecordingButtonStyle(isPressed: $isPressed))
    }

    @ViewBuilder
    private var chapterTitle: some View {
        if let title = chapter.title, !title.isEmpty {
            Text(title).font(.subheadline)
                .fontWeight(isRead ? .regular : .semibold)
                .foregroundStyle(isRead ? Color.secondary : Color.primary)
                .lineLimit(2)
        } else if let num = chapter.chapter {
            let isWhole = num.truncatingRemainder(dividingBy: 1) == 0
            Text("Chapter \(isWhole ? String(Int(num)) : String(num))")
                .font(.subheadline)
                .fontWeight(isRead ? .regular : .semibold)
                .foregroundStyle(isRead ? Color.secondary : Color.primary)
                .lineLimit(1)
        } else {
            Text("Chapter —").font(.subheadline).fontWeight(.regular).foregroundStyle(Color.secondary)
        }
    }

    @ViewBuilder
    private var chapterSubtitle: some View {
        HStack(spacing: 4) {
            if let timestamp = chapter.dateUpdated {
                Text(chapterDateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp))))
                    .font(.caption).foregroundStyle(Color.secondary)
            }
            if let scanlator = chapter.scanlator, !scanlator.isEmpty {
                if chapter.dateUpdated != nil {
                    Text("·").font(.caption).foregroundStyle(Color.secondary)
                }
                Text(scanlator).font(.caption).foregroundStyle(Color.secondary).lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var trailingIcon: some View {
        if let paywalled = chapter.paywalled, paywalled {
            Image(systemName: "lock.fill").font(.caption).foregroundStyle(.yellow)
                .padding(6).background(Color.yellow.opacity(0.15)).clipShape(Circle())
        } else if isRead {
            Image(systemName: "checkmark.circle.fill").font(.subheadline).foregroundStyle(Color.secondary)
        }
    }
}

// MARK: - Press Recording Button Style

private struct PressRecordingButtonStyle: ButtonStyle {
    @Binding var isPressed: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { pressed in isPressed = pressed }
    }
}

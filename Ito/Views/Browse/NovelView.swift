import SwiftUI
import Nuke
import NukeUI
import ito_runner

// MARK: - Helpers

private struct IdentifiableNovelChapter: Identifiable {
    let id: String
    let chapter: Novel.Chapter
    init(_ chapter: Novel.Chapter) {
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

private enum NovelSortOrder: String, CaseIterable {
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

private enum NovelFilterOption: String, CaseIterable {
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

private struct NovelNavTitleVisibilityKey: PreferenceKey {
    static var defaultValue: Bool = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = nextValue()
    }
}

// MARK: - NovelView

struct NovelView: View {
    let runner: ItoRunner
    @State var novel: Novel
    let pluginId: String

    @State private var isLoaded = false
    @State private var errorMessage: String?
    @State private var readingChapter: IdentifiableNovelChapter?

    @State private var showTrackerSearch = false

    @State private var isDescriptionExpanded = false
    @State private var showNavTitle = false

    // Chapter sort & filter state
    @State private var sortOrder: NovelSortOrder = .chapterDescending
    @State private var filterOption: NovelFilterOption = .all

    @EnvironmentObject var progressManager: ReadProgressManager
    @ObservedObject var libraryManager = LibraryManager.shared

    private var isSaved: Bool { libraryManager.isSaved(id: novel.key) }
    private var isTracked: Bool { TrackerManager.shared.trackerMappings[novel.key]?.isEmpty == false }

    private var cleanDescription: String? {
        guard let desc = novel.description, !desc.isEmpty else { return nil }
        return stripHTML(desc)
    }

    /// Applies sort and filter to the raw chapter array from the source.
    private func displayedChapters(from chapters: [Novel.Chapter]) -> [Novel.Chapter] {
        let filtered: [Novel.Chapter]
        switch filterOption {
        case .all:
            filtered = chapters
        case .unread:
            filtered = chapters.filter {
                !progressManager.isRead(mangaId: novel.key, chapterId: $0.key, chapterNum: $0.chapter)
            }
        case .read:
            filtered = chapters.filter {
                progressManager.isRead(mangaId: novel.key, chapterId: $0.key, chapterNum: $0.chapter)
            }
        }

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
                SharedHeroHeader(
                    title: novel.title,
                    coverURL: novel.cover,
                    authorOrStudio: novel.artist ?? novel.authors?.joined(separator: ", "),
                    statusLabel: statusLabel(for: novel.status),
                    pluginId: pluginId
                )
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: NovelNavTitleVisibilityKey.self,
                            value: geo.frame(in: .global).maxY < 0
                        )
                    }
                )

                SharedDetailContent(
                    isSaved: isSaved,
                    isTracked: isTracked,
                    tags: novel.tags,
                    cleanDescription: cleanDescription,
                    onSaveToggle: {
                        LibraryManager.shared.toggleSaveNovel(novel: novel, pluginId: pluginId)
                    },
                    onTrackToggle: TrackerManager.shared.authenticatedProviders.isEmpty ? nil : {
                        showTrackerSearch = true
                    }
                )

                chapterSection
            }
        }
        .onPreferenceChange(NovelNavTitleVisibilityKey.self) { heroGone in
            withAnimation(.easeInOut(duration: 0.18)) { showNavTitle = heroGone }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if showNavTitle {
                    Text(novel.title)
                        .font(.headline)
                        .lineLimit(1)
                        .transition(.opacity)
                }
            }
        }
        .sheet(isPresented: $showTrackerSearch) {
            TrackerSheetOrchestrator(localId: novel.key, title: novel.title, isAnime: false) { _, progress, _ in
                if let prog = progress,
                   UserDefaults.standard.object(forKey: "Ito.AutoSyncTrackersToLocal") as? Bool ?? true {
                    ReadProgressManager.shared.markReadUpTo(mangaId: novel.key, maxChapterNum: Float(prog))
                }
            }
        }
        .fullScreenCover(item: $readingChapter) { wrapper in
            NovelReaderView(runner: runner, pluginId: pluginId, novel: novel, currentChapter: wrapper.chapter)
        }
        .task { await loadDetails() }
        .refreshable { await loadDetails(force: true) }
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
        } else if let chapters = novel.chapters, !chapters.isEmpty {
            let displayed = displayedChapters(from: chapters)
            chapterListHeader(allChapters: chapters, displayedChapters: displayed)
            chapterList(chapters: displayed)
        } else {
            Text("No chapters found.").font(.subheadline).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 32)
        }
    }

    // MARK: Chapter List Header

    private func chapterListHeader(allChapters: [Novel.Chapter], displayedChapters: [Novel.Chapter]) -> some View {
        VStack(alignment: .leading, spacing: 12) {

            if let target = resumeReadingChapter(from: allChapters) {
                let isResume = progressManager.getLastRead(mangaId: novel.key) != nil
                Button {
                    readingChapter = IdentifiableNovelChapter(target)
                } label: {
                    Label(
                        isResume ? "Resume Reading" : "Start Reading",
                        systemImage: isResume ? "book.fill" : "play.fill"
                    )
                    .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).padding(.horizontal, 16)
            }

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
                        ForEach(NovelSortOrder.allCases, id: \.self) { order in
                            Button {
                                withAnimation { sortOrder = order }
                            } label: {
                                Label(order.rawValue,
                                      systemImage: sortOrder == order ? "checkmark" : order.icon)
                            }
                        }
                    }

                    Section("Show") {
                        ForEach(NovelFilterOption.allCases, id: \.self) { option in
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

    private func chapterList(chapters: [Novel.Chapter]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(chapters, id: \.key) { chapter in
                let isRead = progressManager.isRead(
                    mangaId: novel.key, chapterId: chapter.key, chapterNum: chapter.chapter)
                NovelChapterRowView(chapter: chapter, isRead: isRead) {
                    readingChapter = IdentifiableNovelChapter(chapter)
                }
                Divider().padding(.leading, 16)
            }
        }
    }

    // MARK: - Helpers

    private func loadDetails(force: Bool = false) async {
        guard !isLoaded || force else { return }
        do {
            let updated = try await runner.getNovelUpdate(novel: novel)
            await MainActor.run { novel = updated; isLoaded = true; errorMessage = nil }
        } catch {
            await MainActor.run { errorMessage = error.localizedDescription; isLoaded = true }
        }
    }

    private func resumeReadingChapter(from chapters: [Novel.Chapter]) -> Novel.Chapter? {
        guard !chapters.isEmpty else { return nil }
        // Sort ascending by chapter number so we always start from chapter 1,
        // regardless of the order the plugin returns the array in.
        let ascending = chapters.sorted {
            ($0.chapter ?? Float.infinity) < ($1.chapter ?? Float.infinity)
        }
        if let firstUnread = ascending.first(where: {
            !progressManager.isRead(mangaId: novel.key, chapterId: $0.key, chapterNum: $0.chapter)
        }) { return firstUnread }
        // All read — return the last chapter (highest number)
        return ascending.last
    }

    private func statusLabel(for status: Novel.Status) -> String? {
        switch status {
        case .Ongoing:   return "Ongoing"
        case .Completed: return "Completed"
        case .Cancelled: return "Cancelled"
        case .Hiatus:    return "Hiatus"
        case .Unknown:   return nil
        }
    }
}

// MARK: - Reusable UI Components

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

// MARK: - Chapter Row

private struct NovelChapterRowView: View {
    let chapter: Novel.Chapter
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

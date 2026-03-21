import SwiftUI
import NukeUI
import Nuke
import ito_runner

// MARK: - Models

struct ChapterSegment: Identifiable, Equatable {
    let id = UUID()
    let chapter: Manga.Chapter
    let pages: [Page]

    static func == (lhs: ChapterSegment, rhs: ChapterSegment) -> Bool {
        lhs.id == rhs.id
    }
}

struct FlatPage: Identifiable {
    let id: String
    let segmentIndex: Int
    let chapter: Manga.Chapter
    let page: Page
    let globalIndex: Int
}

// MARK: - ReaderView

struct ReaderView: View {
    let runner: ItoRunner
    let pluginId: String
    let manga: Manga
    @State var currentChapter: Manga.Chapter

    @EnvironmentObject var progressManager: ReadProgressManager

    // Shared state
    @State private var isLoaded = false
    @State private var errorMessage: String?
    @State private var markedChapterKeys: Set<String> = []
    @State private var showSettings = false
    @State private var overrideViewer: Manga.Viewer = .Default
    @State private var showUI = true
    @AppStorage("Ito.PreloadImageCount") private var preloadImageCount: Int = 5

    // --- Paged mode state (RTL/LTR) ---
    @State private var pagedPages: [Page] = []
    @State private var pagedIndex: Int = 0
    @State private var prefetchedChapters: [String: [Page]] = [:]

    // --- Continuous mode state (Vertical/Webtoon) ---
    @State private var segments: [ChapterSegment] = []
    @State private var continuousPageIndex: Int = 0
    @State private var scrollTarget: Int?
    @State private var loadingNextChapter = false
    @State private var loadingPrevChapter = false

    // Prefetcher
    @State private var imagePrefetcher = ImagePrefetcher(
        pipeline: ImagePipeline.shared,
        destination: .diskCache,
        maxConcurrentRequestCount: 2
    )

    @Environment(\.dismiss) var dismiss

    private var isPaged: Bool {
        switch activeViewer {
        case .Ltr, .Rtl, .Default: return true
        case .Vertical, .Webtoon: return false
        }
    }

    private var activeViewer: Manga.Viewer {
        if overrideViewer != .Default { return overrideViewer }
        if manga.viewer != .Default { return manga.viewer }
        return .Rtl
    }

    // MARK: Body

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if !isLoaded && errorMessage == nil {
                ProgressView("Loading Chapter...")
                    .foregroundColor(.white)
            } else if let error = errorMessage {
                Text("Error: \(error)")
                    .foregroundColor(.red)
                    .padding()
            } else {
                readComponent
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showUI.toggle()
                        }
                    }
                    .ignoresSafeArea()
            }

            if showUI {
                VStack {
                    ReaderHeaderView(
                        title: manga.title,
                        chapterTitle: currentChapter.title ?? "Chapter \(currentChapter.chapter ?? 0)",
                        safeAreaTop: safeAreaTop,
                        onDismiss: { dismiss() }
                    )

                    Spacer()

                    ReaderFooterView(
                        displayIndex: isPaged ? pagedIndex : continuousPageIndex,
                        displayTotal: isPaged ? pagedPages.count : flatPages.count,
                        hasPrev: chapterBefore(currentChapter) != nil,
                        hasNext: chapterAfter(currentChapter) != nil,
                        overrideViewer: $overrideViewer,
                        safeAreaBottom: safeAreaBottom,
                        onPrevChapter: { goToPreviousChapter() },
                        onNextChapter: { goToNextChapter() },
                        onPrevPage: { prevPage() },
                        onNextPage: { nextPage() },
                        onSettings: { showSettings.toggle() }
                    )
                }
                .transition(.opacity)
                .ignoresSafeArea(edges: .bottom)
            }
        }
        .navigationBarHidden(true)
        .statusBarHidden(!showUI)
        .sheet(isPresented: $showSettings) {
            ReaderSettingsView(
                viewer: $overrideViewer,
                defaultViewer: manga.viewer,
                preloadCount: $preloadImageCount
            )
        }
        .task { await loadInitialChapter() }
        .onDisappear { imagePrefetcher.stopPrefetching() }
    }
    // MARK: - Reader Components

    @ViewBuilder
    private var readComponent: some View {
        if isPaged {
            pagedReader
        } else {
            continuousReader
        }
    }

    // MARK: - Paged Reader (RTL/LTR)

    private var pagedReader: some View {
        TabView(selection: $pagedIndex) {
            if let prev = chapterBefore(currentChapter) {
                loadingChapterView(chapter: prev, isNext: false, isButton: true)
                    .tag(-1)
            }

            ForEach(pagedPages, id: \.index) { page in
                pageImage(for: page)
                    .tag(Int(page.index))
            }

            if let next = chapterAfter(currentChapter) {
                loadingChapterView(chapter: next, isNext: true, isButton: true)
                    .tag(pagedPages.count)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .id(currentChapter.key) // <--- ADD THIS LINE HERE
        .environment(
            \.layoutDirection,
            (activeViewer == .Rtl || activeViewer == .Default) ? .rightToLeft : .leftToRight
        )
        .onChange(of: pagedIndex) { newIndex in
            if newIndex == pagedPages.count, let next = chapterAfter(currentChapter) {
                pagedGoToChapter(next)
            } else if newIndex == -1, let prev = chapterBefore(currentChapter) {
                pagedGoToChapter(prev)
            }

            prefetchPagedImages(around: newIndex)
        }
    }

    // MARK: - Continuous Reader (Vertical/Webtoon)

    private var flatPages: [FlatPage] {
        var result: [FlatPage] = []
        var globalIdx = 0
        for (segIdx, segment) in segments.enumerated() {
            for page in segment.pages {
                result.append(FlatPage(
                    id: "\(segment.chapter.key)_\(page.index)",
                    segmentIndex: segIdx,
                    chapter: segment.chapter,
                    page: page,
                    globalIndex: globalIdx
                ))
                globalIdx += 1
            }
        }
        return result
    }

    private var continuousReader: some View {
        let allPages = flatPages

        return ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: activeViewer == .Webtoon ? 0 : 8) {
                    if let prev = previousChapterForFirstSegment {
                        Button(action: {
                            Task { await prependPreviousChapter(prev) }
                        }) {
                            loadingChapterView(chapter: prev, isNext: false, isButton: !loadingPrevChapter)
                        }
                        .disabled(loadingPrevChapter)
                    }

                    ForEach(allPages) { flatPage in
                        VStack(spacing: 0) {
                            if flatPage.page.index == 0 && flatPage.segmentIndex > 0 {
                                chapterDivider(for: flatPage.chapter)
                            }

                            pageImage(for: flatPage.page)
                                .id(flatPage.globalIndex)
                                .onAppear {
                                    continuousPageIndex = flatPage.globalIndex

                                    if flatPage.chapter.key != currentChapter.key {
                                        currentChapter = flatPage.chapter
                                        markChapterRead(flatPage.chapter)
                                    }

                                    prefetchContinuousImages(around: flatPage.globalIndex, allPages: allPages)
                                }
                        }
                    }

                    if loadingNextChapter {
                        ProgressView()
                            .tint(.white)
                            .frame(maxWidth: .infinity, minHeight: 200)
                    } else if let next = nextChapterForLastSegment {
                        Color.clear
                            .frame(height: 1)
                            .onAppear {
                                Task { await appendNextChapter(next) }
                            }
                    }
                }
            }
            .onChange(of: scrollTarget) { target in
                if let target = target {
                    withAnimation { proxy.scrollTo(target, anchor: .top) }
                    scrollTarget = nil
                }
            }
        }
    }

    // MARK: - Shared Views

    private func chapterDivider(for chapter: Manga.Chapter) -> some View {
        VStack(spacing: 14) {
            Rectangle()
                .fill(Color.white.opacity(0.2))
                .frame(height: 1)
                .padding(.horizontal, 24)

            VStack(spacing: 6) {
                Text("Next Chapter")
                    .font(.caption2.weight(.medium))
                    .foregroundColor(.white.opacity(0.35))
                    .textCase(.uppercase)

                Text(chapter.title ?? "Chapter \(chapter.chapter ?? 0)")
                    .font(.headline)
                    .foregroundColor(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
            }

            Rectangle()
                .fill(Color.white.opacity(0.2))
                .frame(height: 1)
                .padding(.horizontal, 24)
        }
        .padding(.vertical, 40)
    }

    @ViewBuilder
    private func loadingChapterView(chapter: Manga.Chapter, isNext: Bool, isButton: Bool)
        -> some View {
        VStack(spacing: 16) {
            if !isButton {
                ProgressView().tint(.white)
            } else {
                Image(systemName: isNext ? "arrow.down.circle" : "arrow.up.circle")
                    .font(.system(size: 40))
                    .foregroundColor(.white)
            }
            Text(
                isNext
                    ? (isButton ? "Tap to Load Next Chapter" : "Loading Next Chapter...")
                    : (isButton ? "Tap to Load Previous Chapter" : "Loading Previous Chapter...")
            )
            .foregroundColor(.white)
            .font(.headline)
            Text(chapter.title ?? "Chapter \(chapter.chapter ?? 0)")
                .foregroundColor(.gray)
                .font(.subheadline)
        }
        .frame(maxWidth: .infinity, minHeight: 400, maxHeight: .infinity, alignment: .center)
        .padding(40)
    }

    @ViewBuilder
    private func pageImage(for page: Page) -> some View {
        switch page.content {
        case .url(let urlStr):
            MangaImage(urlStr: urlStr, headers: page.headers)
        case .text(let text):
            Text(text)
                .foregroundColor(.white)
                .padding()
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

// MARK: - Data Loading

extension ReaderView {

    func loadInitialChapter() async {
        guard !isLoaded else { return }
        do {
            let pageResult = try await runner.getPageList(manga: manga, chapter: currentChapter)
            let sorted = pageResult.sorted(by: { $0.index < $1.index })
            await MainActor.run {
                if isPaged {
                    pagedPages = sorted
                    pagedIndex = 0
                } else {
                    segments = [ChapterSegment(chapter: currentChapter, pages: sorted)]
                    continuousPageIndex = 0
                }
                isLoaded = true
                markChapterRead(currentChapter)
            }

            if isPaged {
                await prefetchAdjacentChapters()
            }
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.isLoaded = true
            }
        }
    }

    func prefetchAdjacentChapters() async {
        if let next = chapterAfter(currentChapter), prefetchedChapters[next.key] == nil {
            do {
                let pages = try await runner.getPageList(manga: manga, chapter: next)
                let sorted = pages.sorted(by: { $0.index < $1.index })
                await MainActor.run { prefetchedChapters[next.key] = sorted }
            } catch {
                print("[Reader] Failed to pre-fetch next chapter: \(error)")
            }
        }
        if let prev = chapterBefore(currentChapter), prefetchedChapters[prev.key] == nil {
            do {
                let pages = try await runner.getPageList(manga: manga, chapter: prev)
                let sorted = pages.sorted(by: { $0.index < $1.index })
                await MainActor.run { prefetchedChapters[prev.key] = sorted }
            } catch {
                print("[Reader] Failed to pre-fetch previous chapter: \(error)")
            }
        }
    }

    func appendNextChapter(_ chapter: Manga.Chapter) async {
        guard !loadingNextChapter else { return }
        await MainActor.run { loadingNextChapter = true }

        do {
            let pageResult = try await runner.getPageList(manga: manga, chapter: chapter)
            await MainActor.run {
                let sorted = pageResult.sorted(by: { $0.index < $1.index })
                segments.append(ChapterSegment(chapter: chapter, pages: sorted))
                loadingNextChapter = false
            }
        } catch {
            await MainActor.run { loadingNextChapter = false }
            print("[Reader] Failed to load next chapter: \(error)")
        }
    }

    func prependPreviousChapter(_ chapter: Manga.Chapter) async {
        guard !loadingPrevChapter else { return }
        await MainActor.run { loadingPrevChapter = true }

        do {
            let pageResult = try await runner.getPageList(manga: manga, chapter: chapter)
            await MainActor.run {
                let sorted = pageResult.sorted(by: { $0.index < $1.index })
                segments.insert(ChapterSegment(chapter: chapter, pages: sorted), at: 0)
                continuousPageIndex += sorted.count
                loadingPrevChapter = false
            }
        } catch {
            await MainActor.run { loadingPrevChapter = false }
            print("[Reader] Failed to load previous chapter: \(error)")
        }
    }

    func markChapterRead(_ chapter: Manga.Chapter) {
        let chapterTitleStr = chapter.title ?? chapter.key
        HistoryManager.shared.addManga(manga, chapterTitle: chapterTitleStr, pluginId: pluginId)

        guard !markedChapterKeys.contains(chapter.key) else { return }
        markedChapterKeys.insert(chapter.key)
        progressManager.markAsRead(
            mangaId: manga.key, chapterId: chapter.key, chapterNum: chapter.chapter
        )

        Task {
            if let chapterFloat = chapter.chapter {
                await TrackerManager.shared.updateProgress(localId: manga.key, progress: Int(chapterFloat))
            } else {
                let titleOrFallback = chapter.title ?? chapter.key
                let words = titleOrFallback.components(separatedBy: .whitespacesAndNewlines)

                // Parse first valid number isolated by spaces
                if let numberWord = words.first(where: { $0.rangeOfCharacter(from: .decimalDigits) != nil }) {
                    let numbersOnly = numberWord.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
                    if let chapNum = Int(numbersOnly) {
                        await TrackerManager.shared.updateProgress(localId: manga.key, progress: chapNum)
                    }
                }
            }
        }
    }
}

// MARK: - Navigation

extension ReaderView {

    func prevPage() {
        if isPaged {
            guard pagedIndex > 0 else { return }
            pagedIndex -= 1
        } else {
            guard continuousPageIndex > 0 else { return }
            continuousPageIndex -= 1
            scrollTarget = continuousPageIndex
        }
    }

    func nextPage() {
        if isPaged {
            guard pagedIndex < pagedPages.count - 1 else { return }
            pagedIndex += 1
        } else {
            let total = flatPages.count
            guard continuousPageIndex < total - 1 else { return }
            continuousPageIndex += 1
            scrollTarget = continuousPageIndex
        }
    }

    func goToNextChapter() {
        guard let next = chapterAfter(currentChapter) else { return }
        if isPaged {
            pagedGoToChapter(next)
        } else {
            continuousGoToChapter(next)
        }
    }

    func goToPreviousChapter() {
        guard let prev = chapterBefore(currentChapter) else { return }
        if isPaged {
            pagedGoToChapter(prev)
        } else {
            continuousGoToChapter(prev)
        }
    }

    func continuousGoToChapter(_ chapter: Manga.Chapter) {
        currentChapter = chapter
        segments = []
        continuousPageIndex = 0
        scrollTarget = nil
        isLoaded = false
        Task { await loadInitialChapter() }
    }

    func pagedGoToChapter(_ chapter: Manga.Chapter) {
        if let cached = prefetchedChapters[chapter.key] {
            currentChapter = chapter
            pagedPages = cached
            pagedIndex = 0
            markChapterRead(chapter)
            Task { await prefetchAdjacentChapters() }
        } else {
            currentChapter = chapter
            pagedPages = []
            pagedIndex = 0
            isLoaded = false
            Task { await loadInitialChapter() }
        }
    }

    // MARK: Image Preloading

    func prefetchPagedImages(around index: Int) {
        guard preloadImageCount > 0, !pagedPages.isEmpty else { return }
        let start = index + 1
        let end = min(index + preloadImageCount, pagedPages.count - 1)
        guard start <= end else { return }
        prefetchPages(Array(pagedPages[start...end]))
    }

    func prefetchContinuousImages(around globalIndex: Int, allPages: [FlatPage]) {
        guard preloadImageCount > 0, !allPages.isEmpty else { return }
        let start = globalIndex + 1
        let end = min(globalIndex + preloadImageCount, allPages.count - 1)
        guard start <= end else { return }
        prefetchPages(allPages[start...end].map { $0.page })
    }

    private func prefetchPages(_ pages: [Page]) {
        var requests: [ImageRequest] = []
        for page in pages {
            if case .url(let urlStr) = page.content, let url = URL(string: urlStr) {
                var urlRequest = URLRequest(url: url)
                if let headers = page.headers, !headers.isEmpty {
                    for (key, value) in headers {
                        urlRequest.setValue(value, forHTTPHeaderField: key)
                    }
                } else {
                    urlRequest.setValue(
                        "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1",
                        forHTTPHeaderField: "User-Agent"
                    )
                    urlRequest.setValue(urlStr, forHTTPHeaderField: "Referer")
                }
                requests.append(ImageRequest(urlRequest: urlRequest))
            }
        }
        if !requests.isEmpty {
            imagePrefetcher.startPrefetching(with: requests)
        }
    }
}

// MARK: - Chapter Navigation Helpers

extension ReaderView {

    var nextChapterForLastSegment: Manga.Chapter? {
        guard let last = segments.last else { return nil }
        return chapterAfter(last.chapter)
    }

    var previousChapterForFirstSegment: Manga.Chapter? {
        guard let first = segments.first else { return nil }
        return chapterBefore(first.chapter)
    }

    func chapterAfter(_ chapter: Manga.Chapter) -> Manga.Chapter? {
        guard let chapters = manga.chapters else { return nil }

        let currentNum = chapter.chapter ?? -10000

        // 1. Find all chapters with a strictly higher number
        let validNextChapters = chapters.filter { ($0.chapter ?? -10000) > currentNum + 0.0001 }

        // 2. Find the lowest chapter number among those future chapters
        guard let nextNum = validNextChapters.map({ $0.chapter ?? -10000 }).min() else { return nil }

        // 3. Match it with your existing preferred scanlator logic
        return bestSource(for: nextNum, in: chapters)
    }

    func chapterBefore(_ chapter: Manga.Chapter) -> Manga.Chapter? {
        guard let chapters = manga.chapters else { return nil }

        let currentNum = chapter.chapter ?? -10000

        // 1. Find all chapters with a strictly lower number
        let validPrevChapters = chapters.filter { ($0.chapter ?? -10000) < currentNum - 0.0001 }

        // 2. Find the highest chapter number among those past chapters
        guard let prevNum = validPrevChapters.map({ $0.chapter ?? -10000 }).max() else { return nil }

        return bestSource(for: prevNum, in: chapters)
    }

    func bestSource(for chapterNum: Float32, in chapters: [Manga.Chapter]) -> Manga.Chapter? {
        let sources = chapters.filter { abs(($0.chapter ?? -10000) - chapterNum) < 0.0001 }
        if let match = sources.first(where: { $0.scanlator == currentChapter.scanlator }) {
            return match
        }
        return sources.first
    }

    var safeAreaTop: CGFloat {
        let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        return windowScene?.windows.first?.safeAreaInsets.top ?? 44
    }

    var safeAreaBottom: CGFloat {
        let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        return windowScene?.windows.first?.safeAreaInsets.bottom ?? 34
    }
}

// MARK: - Reader Settings

struct ReaderSettingsView: View {
    @Binding var viewer: Manga.Viewer
    let defaultViewer: Manga.Viewer
    @Binding var preloadCount: Int

    @Environment(\.dismiss) var dismiss

    private let preloadOptions = [0, 3, 5, 10, 15, 20]

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Reading Mode")) {
                    Picker("Mode", selection: $viewer) {
                        Text("Default (Automatic)").tag(Manga.Viewer.Default)
                        Text("Right to Left").tag(Manga.Viewer.Rtl)
                        Text("Left to Right").tag(Manga.Viewer.Ltr)
                        Text("Vertical").tag(Manga.Viewer.Vertical)
                        Text("Webtoon").tag(Manga.Viewer.Webtoon)
                    }
                    .pickerStyle(.inline)
                }

                Section(
                    header: Text("Preloading"),
                    footer: Text("Number of images ahead of your current position to preload. Higher values use more data but reduce loading times.")
                ) {
                    Picker("Preload Images", selection: $preloadCount) {
                        ForEach(preloadOptions, id: \.self) { count in
                            if count == 0 {
                                Text("Off").tag(count)
                            } else {
                                Text("\(count) images").tag(count)
                            }
                        }
                    }
                }

                Section(footer: Text("Manga requested default: \(modeName(defaultViewer))")) {}
            }
            .navigationTitle("Reader Settings")
            .navigationBarItems(
                trailing: Button("Done") { dismiss() }
            )
        }
    }

    private func modeName(_ mode: Manga.Viewer) -> String {
        switch mode {
        case .Default: return "None specified"
        case .Rtl: return "Right to Left"
        case .Ltr: return "Left to Right"
        case .Vertical: return "Vertical"
        case .Webtoon: return "Webtoon"
        }
    }
}

// MARK: - Reader HUD Components

private struct ReaderHeaderView: View {
    let title: String
    let chapterTitle: String
    let safeAreaTop: CGFloat
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Text(chapterTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .environment(\.colorScheme, .dark)

            Spacer()

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.body.weight(.bold))
                    .foregroundColor(.white)
                    .padding(12)
                    .background(.ultraThinMaterial, in: Circle())
                    .environment(\.colorScheme, .dark)
            }
        }
        .padding(.horizontal)
        .padding(.top, safeAreaTop)
    }
}

private struct ReaderFooterView: View {
    let displayIndex: Int
    let displayTotal: Int
    let hasPrev: Bool
    let hasNext: Bool
    @Binding var overrideViewer: Manga.Viewer
    let safeAreaBottom: CGFloat

    let onPrevChapter: () -> Void
    let onNextChapter: () -> Void
    let onPrevPage: () -> Void
    let onNextPage: () -> Void
    let onSettings: () -> Void

    var body: some View {
        HStack {
            if hasPrev {
                Button(action: onPrevChapter) {
                    Image(systemName: "backward.end.fill")
                        .font(.body.weight(.semibold))
                        .foregroundColor(.white)
                }
            } else {
                Color.clear.frame(width: 16, height: 16)
            }

            Spacer()

            Button(action: onSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundColor(.white)
            }

            Spacer()

            HStack(spacing: 24) {
                Button(action: onPrevPage) {
                    Image(systemName: "chevron.left")
                        .font(.title3.weight(.bold))
                        .foregroundColor(displayIndex > 0 ? .white : .white.opacity(0.3))
                }
                .disabled(displayIndex == 0)

                Text("\(displayTotal == 0 ? 0 : displayIndex + 1) / \(displayTotal)")
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundColor(.white)
                    .frame(minWidth: 60, alignment: .center)

                Button(action: onNextPage) {
                    Image(systemName: "chevron.right")
                        .font(.title3.weight(.bold))
                        .foregroundColor(
                            displayIndex < displayTotal - 1 ? .white : .white.opacity(0.3))
                }
                .disabled(displayIndex >= displayTotal - 1)
            }

            Spacer()

            Menu {
                Picker("Reading Mode", selection: $overrideViewer) {
                    Text("Auto").tag(Manga.Viewer.Default)
                    Text("Right to Left").tag(Manga.Viewer.Rtl)
                    Text("Left to Right").tag(Manga.Viewer.Ltr)
                    Text("Vertical").tag(Manga.Viewer.Vertical)
                    Text("Webtoon").tag(Manga.Viewer.Webtoon)
                }
            } label: {
                Image(systemName: "book.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundColor(.white)
            }

            Spacer()

            if hasNext {
                Button(action: onNextChapter) {
                    Image(systemName: "forward.end.fill")
                        .font(.body.weight(.semibold))
                        .foregroundColor(.white)
                }
            } else {
                Color.clear.frame(width: 16, height: 16)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, 20)
        .padding(.bottom, safeAreaBottom > 0 ? safeAreaBottom : 16)
    }
}

// MARK: - Manga Image Loader

struct MangaImage: View {
    let urlStr: String
    let headers: [String: String]?

    var body: some View {
        if let url = URL(string: urlStr) {
            LazyImage(request: ImageRequest(urlRequest: createRequest(url: url))) { state in
                if let image = state.image {
                    image
                        .resizable()
                        .scaledToFit()
                } else if let error = state.error {
                    VStack {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(.red)
                            .font(.largeTitle)
                        Text(error.localizedDescription)
                            .font(.caption)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                            .padding()
                    }
                    .frame(maxWidth: .infinity, minHeight: 400, alignment: .center)
                    .padding(40)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 400, alignment: .center)
                        .padding(40)
                }
            }
        }
    }

    private func createRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)

        if let customHeaders = headers, !customHeaders.isEmpty {
            for (key, value) in customHeaders {
                request.setValue(value, forHTTPHeaderField: key)
            }
        } else {
            request.setValue(
                "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1",
                forHTTPHeaderField: "User-Agent")
            request.setValue(urlStr, forHTTPHeaderField: "Referer")
        }

        return request
    }
}

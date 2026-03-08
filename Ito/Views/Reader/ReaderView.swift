import SwiftUI
import ito_runner

struct ReaderView: View {
    let runner: ItoRunner
    let manga: Manga
    @State var currentChapter: Manga.Chapter

    @EnvironmentObject var progressManager: ReadProgressManager

    @State private var pages: [Page] = []
    @State private var isLoaded = false
    @State private var errorMessage: String? = nil

    // Reader Settings
    @State private var showSettings = false
    @State private var overrideViewer: Manga.Viewer = .Default

    // HUD State
    @State private var showUI = true
    @State private var currentPageIndex = 0
    @State private var scrollTarget: Int? = nil  // Only used for programmatic ScrollView jumps
    @State private var autoLoadTask: Task<Void, Never>? = nil
    @Environment(\.dismiss) var dismiss

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
                    .ignoresSafeArea()  // Let the images take full screen
            }

            // HUD Overlays
            if showUI {
                VStack {
                    headerView
                    Spacer()
                    footerView
                }
                .transition(.opacity)
                .ignoresSafeArea(edges: .bottom)  // Let footer go to the bottom edge, but keep header out of safe nav bar logic
            }
        }
        .navigationBarHidden(true)  // Hide default iOS navigation bar
        .statusBarHidden(!showUI)  // Hide time/battery when reading
        .sheet(isPresented: $showSettings) {
            ReaderSettingsView(viewer: $overrideViewer, defaultViewer: manga.viewer)
        }
        .task {
            await loadPages()
        }
    }

    private var activeViewer: Manga.Viewer {
        if overrideViewer != .Default {
            return overrideViewer
        } else if manga.viewer != .Default {
            return manga.viewer
        }
        return .Rtl  // System default if manga has no preference
    }

    // MARK: - HUD Views

    private var headerView: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(manga.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Text(currentChapter.title ?? "Chapter \(currentChapter.chapter ?? 0)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .environment(\.colorScheme, .dark)

            Spacer()

            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .padding(12)
                    .background(.ultraThinMaterial, in: Circle())
                    .environment(\.colorScheme, .dark)
            }
        }
        .padding(.horizontal)
        .padding(.top, safeAreaTop)
    }

    private var footerView: some View {
        HStack {
            if let prev = previousChapter {
                Button(action: { goToChapter(prev) }) {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                }
            } else {
                Color.clear.frame(width: 16, height: 16)
            }

            Spacer()

            Button(action: { showSettings.toggle() }) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
            }

            Spacer()

            // Pagination Controls
            HStack(spacing: 24) {
                Button(action: { prevPage() }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(currentPageIndex > 0 ? .white : .white.opacity(0.3))
                }
                .disabled(currentPageIndex == 0)

                Text("\(pages.isEmpty ? 0 : currentPageIndex + 1) / \(pages.count)")
                    .font(.system(size: 14, weight: .bold).monospacedDigit())
                    .foregroundColor(.white)
                    .frame(minWidth: 60, alignment: .center)

                Button(action: { nextPage() }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(
                            currentPageIndex < pages.count - 1 ? .white : .white.opacity(0.3))
                }
                .disabled(currentPageIndex >= pages.count - 1)
            }

            Spacer()

            // Quick Reader Mode Toggle
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
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
            }

            Spacer()

            if let next = nextChapter {
                Button(action: { goToChapter(next) }) {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 16, weight: .semibold))
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

    // MARK: - Reader Components

    @ViewBuilder
    private var readComponent: some View {
        switch activeViewer {
        case .Ltr, .Rtl, .Default:
            TabView(selection: $currentPageIndex) {
                if let prev = previousChapter {
                    loadingChapterView(chapter: prev, isNext: false, isButton: false)
                        .tag(-1)
                }

                ForEach(pages, id: \.index) { page in
                    pageImage(for: page)
                        .tag(Int(page.index))
                }

                if let next = nextChapter {
                    loadingChapterView(chapter: next, isNext: true, isButton: false)
                        .tag(pages.count)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .environment(
                \.layoutDirection,
                (activeViewer == .Rtl || activeViewer == .Default) ? .rightToLeft : .leftToRight
            )
            .onChange(of: currentPageIndex) { newIndex in
                if newIndex == pages.count, let next = nextChapter {
                    goToChapter(next)
                } else if newIndex == -1, let prev = previousChapter {
                    goToChapter(prev)
                }
            }

        case .Vertical, .Webtoon:
            // For ScrollViews, we use ScrollViewReader to allow jumping to indexes (from footer arrows)
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: activeViewer == .Webtoon ? 0 : 8) {
                        if let prev = previousChapter {
                            Button(action: {
                                print(
                                    "[Reader] Previous Chapter Tapped: \(prev.title ?? "Unknown")")
                                goToChapter(prev)
                            }) {
                                loadingChapterView(chapter: prev, isNext: false, isButton: true)
                            }
                        }

                        ForEach(pages, id: \.index) { page in
                            pageImage(for: page)
                                .id(Int(page.index))  // Required for ScrollViewReader
                                .onAppear {
                                    print("[Reader] Page \(page.index + 1) Appeared on screen.")
                                    // Update the page indicator when scrolling
                                    self.currentPageIndex = Int(page.index)
                                }
                        }

                        if let next = nextChapter {
                            if !pages.isEmpty && isLoaded {
                                loadingChapterView(chapter: next, isNext: true, isButton: false)
                                    .onAppear {
                                        print(
                                            "[Reader] Next Chapter View Appeared: \(next.title ?? "Unknown")"
                                        )
                                        autoLoadTask?.cancel()
                                        autoLoadTask = Task {
                                            try? await Task.sleep(nanoseconds: 400_000_000)
                                            if !Task.isCancelled {
                                                await MainActor.run {
                                                    goToChapter(next)
                                                }
                                            }
                                        }
                                    }
                                    .onDisappear {
                                        print(
                                            "[Reader] Next Chapter View Disappeared, cancelling auto-load."
                                        )
                                        autoLoadTask?.cancel()
                                        autoLoadTask = nil
                                    }
                            } else {
                                Button(action: {
                                    print(
                                        "[Reader] Next Chapter Tapped: \(next.title ?? "Unknown")")
                                    goToChapter(next)
                                }) {
                                    loadingChapterView(chapter: next, isNext: true, isButton: true)
                                }
                            }
                        }
                    }
                }
                .onChange(of: scrollTarget) { target in
                    if let target = target {
                        print("[Reader] Programmatically scrolling to page index \(target)")
                        withAnimation {
                            proxy.scrollTo(target, anchor: .top)
                        }
                        scrollTarget = nil
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func loadingChapterView(chapter: Manga.Chapter, isNext: Bool, isButton: Bool)
        -> some View
    {
        VStack(spacing: 16) {
            if !isButton {
                ProgressView()
                    .tint(.white)
            } else {
                Image(systemName: isNext ? "arrow.down.circle" : "arrow.up.circle")
                    .font(.system(size: 40))
                    .foregroundColor(.white)
            }
            Text(
                isNext
                    ? "Loading Next Chapter..."
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

    private func loadPages() async {
        guard !isLoaded else { return }
        do {
            let pageResult = try await runner.getPageList(manga: manga, chapter: currentChapter)
            await MainActor.run {
                self.pages = pageResult.sorted(by: { $0.index < $1.index })
                self.isLoaded = true
                self.progressManager.markAsRead(mangaId: manga.key, chapterId: currentChapter.key, chapterNum: currentChapter.chapter)
                
                // Track progress
                if TrackerManager.shared.isAnilistAuthenticated {
                    Task {
                        // Extract chapter number
                        let titleOrFallback = currentChapter.title ?? currentChapter.key
                        let numbers = titleOrFallback.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
                        if let chapNum = Int(numbers) {
                            do {
                                if let mediaId = try await TrackerManager.shared.searchAnilistMedia(title: manga.title, isAnime: false) {
                                    try await TrackerManager.shared.updateProgress(mediaId: mediaId, progress: chapNum)
                                }
                            } catch {
                                print("📖 [DEBUG-TRACKER] Failed to update progress: \(error)")
                            }
                        } else if let num = currentChapter.chapter {
                            do {
                                if let mediaId = try await TrackerManager.shared.searchAnilistMedia(title: manga.title, isAnime: false) {
                                    try await TrackerManager.shared.updateProgress(mediaId: mediaId, progress: Int(num))
                                }
                            } catch {
                                print("📖 [DEBUG-TRACKER] Failed to update progress: \(error)")
                            }
                        }
                    }
                }
            }
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.isLoaded = true
            }
        }
    }

    // MARK: - Actions

    private func prevPage() {
        if currentPageIndex > 0 {
            currentPageIndex -= 1
            scrollTarget = currentPageIndex
        }
    }

    private func nextPage() {
        if currentPageIndex < pages.count - 1 {
            currentPageIndex += 1
            scrollTarget = currentPageIndex
        }
    }

    private func goToChapter(_ nextChap: Manga.Chapter) {
        print("[Reader] goToChapter called for: \(nextChap.title ?? "Unknown")")
        currentChapter = nextChap
        isLoaded = false
        pages = []
        currentPageIndex = 0
        scrollTarget = nil
        Task {
            await loadPages()
        }
    }

    // MARK: - Helpers

    private var nextChapter: Manga.Chapter? {
        guard let chapters = manga.chapters,
              let currentIndex = chapters.firstIndex(where: { $0.key == currentChapter.key })
        else { return nil }
        
        let currentNum = currentChapter.chapter ?? -10000
        
        // Scan backwards for the next chapter (higher number)
        var targetIndex = currentIndex - 1
        while targetIndex >= 0 {
            let candidate = chapters[targetIndex]
            let candNum = candidate.chapter ?? -10000
            
            // Check for a distinct, higher chapter number
            if candNum > currentNum + 0.0001 {
                return bestSource(for: candNum, in: chapters)
            }
            targetIndex -= 1
        }
        return nil
    }

    private var previousChapter: Manga.Chapter? {
        guard let chapters = manga.chapters,
              let currentIndex = chapters.firstIndex(where: { $0.key == currentChapter.key })
        else { return nil }
        
        let currentNum = currentChapter.chapter ?? -10000
        
        // Scan forwards for the previous chapter (lower number)
        var targetIndex = currentIndex + 1
        while targetIndex < chapters.count {
            let candidate = chapters[targetIndex]
            let candNum = candidate.chapter ?? -10000
            
            if candNum < currentNum - 0.0001 {
                return bestSource(for: candNum, in: chapters)
            }
            targetIndex += 1
        }
        return nil
    }
    
    private func bestSource(for chapterNum: Float32, in chapters: [Manga.Chapter]) -> Manga.Chapter? {
        // Gather all sources for this chapter number
        let sources = chapters.filter { abs(($0.chapter ?? -10000) - chapterNum) < 0.0001 }
        
        let currentScanlator = currentChapter.scanlator
        
        // 1. Try to find match with same scanlator (handles nil==nil)
        if let match = sources.first(where: { $0.scanlator == currentScanlator }) {
            return match
        }
        
        // 2. Default to first available
        return sources.first
    }

    private var safeAreaTop: CGFloat {
        let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        return windowScene?.windows.first?.safeAreaInsets.top ?? 44
    }

    private var safeAreaBottom: CGFloat {
        let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        return windowScene?.windows.first?.safeAreaInsets.bottom ?? 34
    }
}

// Separate view for the settings sheet
struct ReaderSettingsView: View {
    @Binding var viewer: Manga.Viewer
    let defaultViewer: Manga.Viewer

    @Environment(\.dismiss) var dismiss

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

                Section(footer: Text("Manga requested default: \(modeName(defaultViewer))")) {}
            }
            .navigationTitle("Reader Settings")
            .navigationBarItems(
                trailing: Button("Done") {
                    dismiss()
                })
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

// Custom Async Image Loader to handle Headers / User-Agent if needed
struct MangaImage: View {
    let urlStr: String
    let headers: [String: String]?

    @State private var uiImage: UIImage? = nil
    @State private var isLoading = false
    @State private var loadError: Error? = nil

    var body: some View {
        Group {
            if let image = uiImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else if let error = loadError {
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
                    .onAppear {
                        loadImage()
                    }
            }
        }
    }

    private func loadImage() {
        guard let url = URL(string: urlStr), !isLoading, uiImage == nil else { return }

        isLoading = true
        var request = URLRequest(url: url)
        
        if let customHeaders = headers, !customHeaders.isEmpty {
            for (key, value) in customHeaders {
                request.setValue(value, forHTTPHeaderField: key)
            }
        } else {
            // Default fallback
            request.setValue(
                "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1",
                forHTTPHeaderField: "User-Agent")
            request.setValue(urlStr, forHTTPHeaderField: "Referer")
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                self.isLoading = false
                if let error = error {
                    print("MangaImage failed to load \(urlStr): \(error)")
                    self.loadError = error
                    return
                }

                if let httpResponse = response as? HTTPURLResponse,
                    !(200...299).contains(httpResponse.statusCode)
                {
                    let err = URLError(URLError.Code(rawValue: httpResponse.statusCode))
                    print("MangaImage HTTP error \(httpResponse.statusCode) for \(urlStr)")
                    self.loadError = err
                    return
                }

                if let data = data, let img = UIImage(data: data) {
                    self.uiImage = img
                } else {
                    self.loadError = URLError(.cannotDecodeRawData)
                }
            }
        }.resume()
    }
}

import SwiftUI
import os
import ito_runner

struct NovelReaderView: View {
    let runner: ItoRunner
    let pluginId: String
    let novel: Novel
    @State var currentChapter: Novel.Chapter

    @EnvironmentObject var progressManager: ReadProgressManager

    struct LoadedChapter: Identifiable, Equatable {
        let id = UUID()
        let chapter: Novel.Chapter
        let pages: [Page]

        static func == (lhs: LoadedChapter, rhs: LoadedChapter) -> Bool {
            lhs.id == rhs.id
        }
    }

    @State private var loadedChapters: [LoadedChapter] = []
    @State private var isLoaded = false
    @State private var isLoadingNext = false
    @State private var errorMessage: String?

    // Appearance settings
    @AppStorage("Ito.NovelFontSize") private var fontSize: Double = 18.0
    @AppStorage("Ito.NovelLineSpacing") private var lineSpacing: Double = 8.0
    @AppStorage("Ito.NovelFontFamily") private var fontFamily: NovelFont = .system
    @AppStorage("Ito.NovelTheme") private var theme: NovelTheme = .system
    @AppStorage("Ito.NovelIsPaging") private var isPaging: Bool = false
    @AppStorage("Ito.NovelPrefetchChapters") private var prefetchChapters: Bool = true

    @State private var showUI = true
    @State private var showSettings = false

    @Environment(\.dismiss) var dismiss

    var body: some View {
        ZStack {
            // Background
            theme.backgroundColor.edgesIgnoringSafeArea(.all)

            if !isLoaded && errorMessage == nil {
                VStack {
                    ProgressView("Loading Chapter...")
                }
            } else if let error = errorMessage {
                VStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.red)
                        .font(.largeTitle)
                    Text("Failed to load chapter")
                        .font(.headline)
                        .padding(.top)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                    Button("Try Again") {
                        isLoaded = false
                        errorMessage = nil
                        Task { await loadInitialChapter() }
                    }
                    .padding()
                }
            } else {
                if isPaging {
                    NovelPagingReaderView(
                        loadedChapters: loadedChapters,
                        fontSize: fontSize,
                        fontFamily: fontFamily,
                        lineSpacing: lineSpacing,
                        theme: theme,
                        prefetchChapters: prefetchChapters,
                        onLoadNextChapter: {
                            Task { await loadNextChapter() }
                        },
                        currentChapter: $currentChapter
                    )
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showUI.toggle()
                        }
                    }
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: CGFloat(lineSpacing)) {
                            ForEach(loadedChapters) { loadedChapter in
                                let chapterTitleText = {
                                    if let num = loadedChapter.chapter.chapter {
                                        if let title = loadedChapter.chapter.title, !title.isEmpty {
                                            return "Chapter \(num.formatted()) - \(title)"
                                        }
                                        return "Chapter \(num.formatted())"
                                    }
                                    return loadedChapter.chapter.title ?? "Unknown Chapter"
                                }()

                                Text(chapterTitleText)
                                    .font(.system(size: CGFloat(fontSize) + 6, weight: .bold, design: fontFamily.fontDesign))
                                    .foregroundColor(theme.textColor)
                                    .padding(.vertical)
                                    .padding(.horizontal)
                                    .onAppear {
                                        // Update HUD & History when scrolling to this chapter's title
                                        if currentChapter.key != loadedChapter.chapter.key {
                                            currentChapter = loadedChapter.chapter
                                            updateTracking(for: loadedChapter.chapter)
                                        }
                                    }

                                let pagesArray = loadedChapter.pages
                                ForEach(Array(pagesArray.enumerated()), id: \.element.index) { idx, page in
                                    pageText(for: page)
                                        .onAppear {
                                            // Seamless reading trigger (fetch when within 5 paragraphs of the end)
                                            if prefetchChapters, 
                                               loadedChapter.id == loadedChapters.last?.id, 
                                               idx >= pagesArray.count - 5 {
                                                Task { await loadNextChapter() }
                                            }
                                        }
                                }
                            }

                            if isLoadingNext {
                                HStack {
                                    Spacer()
                                    ProgressView()
                                        .padding()
                                    Spacer()
                                }
                            }

                            Color.clear.frame(height: safeAreaBottom + 80)
                        }
                    }
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showUI.toggle()
                        }
                    }
                }
            }

            if showUI {
                VStack {
                    NovelReaderHeaderView(
                        title: novel.title,
                        chapterTitle: {
                            if let num = currentChapter.chapter {
                                if let title = currentChapter.title, !title.isEmpty {
                                    return "Chapter \(num.formatted()) - \(title)"
                                }
                                return "Chapter \(num.formatted())"
                            }
                            return currentChapter.title ?? "Unknown Chapter"
                        }(),
                        safeAreaTop: safeAreaTop,
                        onDismiss: { dismiss() }
                    )

                    Spacer()

                    NovelReaderFooterView(
                        hasPrev: previousChapter != nil,
                        hasNext: nextChapter != nil,
                        safeAreaBottom: safeAreaBottom,
                        onPrevChapter: { if let prev = previousChapter { goToChapter(prev) } },
                        onNextChapter: { if let next = nextChapter { goToChapter(next) } },
                        onSettings: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                showSettings = true
                            }
                        }
                    )
                }
                .transition(.opacity)
                .ignoresSafeArea(edges: .bottom)
            }

            if showSettings {
                Color.black.opacity(0.4)
                    .edgesIgnoringSafeArea(.all)
                    .onTapGesture {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            showSettings = false
                        }
                    }
                    .transition(.opacity)
                    .zIndex(10)

                VStack(spacing: 0) {
                    Spacer()

                    NovelReaderSettingsView(
                        fontSize: $fontSize,
                        lineSpacing: $lineSpacing,
                        fontFamily: $fontFamily,
                        theme: $theme,
                        isPaging: $isPaging,
                        prefetchChapters: $prefetchChapters
                    )
                    .frame(height: 280)
                    .padding(.bottom, safeAreaBottom)
                    .background(Color(UIColor.systemBackground))
                    .cornerRadius(24)
                    .environment(\.colorScheme, .dark)
                }
                .edgesIgnoringSafeArea(.bottom)
                .transition(.move(edge: .bottom))
                .zIndex(11)
            }
        }
        .navigationBarHidden(true)
        .statusBarHidden(!showUI)
        .task {
            await loadInitialChapter()
        }
        .onAppear {
            let anilistId = TrackerManager.shared.getMediaId(for: novel.key, providerId: "anilist")
            let url = anilistId.flatMap { "https://anilist.co/manga/\($0)" }
            let pluginName = PluginManager.shared.installedPlugins[pluginId]?.info.name ?? "Unknown Plugin"
            let scanlator = currentChapter.scanlator ?? "Official"

            DiscordRPCManager.shared.setActivity(
                details: novel.title,
                state: "Reading \(currentChapter.title ?? "Chapter \(currentChapter.chapter ?? 0)")",
                activityType: 3,
                detailsUrl: url,
                largeImageText: "Reading from \(scanlator) at \(pluginName)",
                imageUrl: novel.cover,
                resetTimer: true
            )
        }
        .onChange(of: currentChapter.key) { _ in
            let anilistId = TrackerManager.shared.getMediaId(for: novel.key, providerId: "anilist")
            let url = anilistId.flatMap { "https://anilist.co/manga/\($0)" }
            let pluginName = PluginManager.shared.installedPlugins[pluginId]?.info.name ?? "Unknown Plugin"
            let scanlator = currentChapter.scanlator ?? "Official"

            DiscordRPCManager.shared.setActivity(
                details: novel.title,
                state: "Reading \(currentChapter.title ?? "Chapter \(currentChapter.chapter ?? 0)")",
                activityType: 3,
                detailsUrl: url,
                largeImageText: "Reading from \(scanlator) at \(pluginName)",
                imageUrl: novel.cover,
                resetTimer: false
            )
        }
        .onDisappear {
            DiscordRPCManager.shared.clearActivity()
        }
    }

    @ViewBuilder
    private func pageText(for page: Page) -> some View {
        switch page.content {
        case .text(let text):
            Text(text)
                .font(.system(size: CGFloat(fontSize), design: fontFamily.fontDesign))
                .foregroundColor(theme.textColor)
                .padding(.horizontal)
                .padding(.vertical, 4)
        case .url(let urlStr):
            // Fallback if a novel plugin returns an image inline
            MangaImage(urlStr: urlStr, headers: page.headers)
                .padding(.horizontal)
        }
    }
}

// MARK: - Helpers & Actions
extension NovelReaderView {
    func loadInitialChapter() async {
        guard !isLoaded else { return }
        do {
            let pageResult = try await runner.getChapterContent(novel: novel, chapter: currentChapter)
            await MainActor.run {
                self.loadedChapters = [LoadedChapter(chapter: currentChapter, pages: pageResult.sorted(by: { $0.index < $1.index }))]
                self.isLoaded = true
                self.updateTracking(for: currentChapter)
            }
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.isLoaded = true
            }
        }
    }

    func loadNextChapter() async {
        guard let lastLoaded = loadedChapters.last?.chapter else { return }
        guard let next = getNextChapter(after: lastLoaded) else {
            AppLogger.ui.debug("[NovelReaderView] loadNextChapter: nextChapter is nil (end of novel?)")
            return
        }
        guard !isLoadingNext else {
            return
        }
        AppLogger.ui.debug("[NovelReaderView] loadNextChapter: triggering fetch for \(next.title ?? next.key)")
        isLoadingNext = true
        do {
            let pageResult = try await runner.getChapterContent(novel: novel, chapter: next)
            await MainActor.run {
                AppLogger.ui.debug("[NovelReaderView] loadNextChapter: success, appending \(pageResult.count) pages.")
                let newChapter = LoadedChapter(chapter: next, pages: pageResult.sorted(by: { $0.index < $1.index }))
                self.loadedChapters.append(newChapter)
                
                self.isLoadingNext = false
            }
        } catch {
            await MainActor.run {
                AppLogger.ui.debug("[NovelReaderView] loadNextChapter: failed with error: \(error.localizedDescription)")
                self.isLoadingNext = false
            }
        }
    }

    private func updateTracking(for chap: Novel.Chapter) {
        let chapterTitleStr = chap.title ?? chap.key
        HistoryManager.shared.addNovel(novel, chapterKey: chap.key, chapterTitle: chapterTitleStr, pluginId: pluginId)
        self.progressManager.markAsRead(mangaId: novel.key, chapterId: chap.key, chapterNum: chap.chapter)

        // Track progress
        Task {
            if let chapterFloat = chap.chapter {
                await TrackerManager.shared.updateProgress(localId: novel.key, progress: Int(chapterFloat))
            } else {
                let titleOrFallback = chap.title ?? chap.key
                let words = titleOrFallback.components(separatedBy: .whitespacesAndNewlines)
                if let numberWord = words.first(where: { $0.rangeOfCharacter(from: .decimalDigits) != nil }) {
                    let numbersOnly = numberWord.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
                    if let chapNum = Int(numbersOnly) {
                        await TrackerManager.shared.updateProgress(localId: novel.key, progress: chapNum)
                    }
                }
            }
        }
    }

    func goToChapter(_ nextChap: Novel.Chapter) {
        currentChapter = nextChap
        isLoaded = false
        loadedChapters = []
        Task {
            await loadInitialChapter()
        }
    }

    var nextChapter: Novel.Chapter? {
        getNextChapter(after: currentChapter)
    }

    var previousChapter: Novel.Chapter? {
        getPreviousChapter(before: currentChapter)
    }

    func getNextChapter(after chap: Novel.Chapter) -> Novel.Chapter? {
        guard let chapters = novel.chapters else { return nil }
        
        if let currentNum = chap.chapter {
            // Find the closest chapter with a higher number
            let candidates = chapters.filter { ($0.chapter ?? -10000) > currentNum + 0.0001 }
            if let next = candidates.min(by: { ($0.chapter ?? -10000) < ($1.chapter ?? -10000) }) {
                return next
            }
        }
        
        // Fallback: array index
        guard let currentIndex = chapters.firstIndex(where: { $0.key == chap.key }) else { return nil }
        
        // Try looking at previous index (descending order assumption)
        if currentIndex - 1 >= 0 {
            return chapters[currentIndex - 1]
        }
        // Try looking at next index (ascending order assumption)
        if currentIndex + 1 < chapters.count {
            return chapters[currentIndex + 1]
        }
        
        return nil
    }

    func getPreviousChapter(before chap: Novel.Chapter) -> Novel.Chapter? {
        guard let chapters = novel.chapters else { return nil }
        
        if let currentNum = chap.chapter {
            // Find the closest chapter with a lower number
            let candidates = chapters.filter { ($0.chapter ?? -10000) < currentNum - 0.0001 }
            if let prev = candidates.max(by: { ($0.chapter ?? -10000) < ($1.chapter ?? -10000) }) {
                return prev
            }
        }
        
        // Fallback: array index
        guard let currentIndex = chapters.firstIndex(where: { $0.key == chap.key }) else { return nil }
        
        // Try looking at next index (descending order assumption)
        if currentIndex + 1 < chapters.count {
            return chapters[currentIndex + 1]
        }
        // Try looking at previous index (ascending order assumption)
        if currentIndex - 1 >= 0 {
            return chapters[currentIndex - 1]
        }
        
        return nil
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

// MARK: - Novel Reader HUD Components

private struct NovelReaderHeaderView: View {
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

private struct NovelReaderFooterView: View {
    let hasPrev: Bool
    let hasNext: Bool
    let safeAreaBottom: CGFloat

    let onPrevChapter: () -> Void
    let onNextChapter: () -> Void
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

// MARK: - Novel Reader Settings Models & View

enum NovelTheme: String, CaseIterable, Identifiable {
    case system = "System"
    case white = "White"
    case cream = "Cream"
    case mint = "Mint"
    case sepia = "Sepia"
    case dark = "Dark"
    var id: String { rawValue }

    var backgroundColor: Color {
        switch self {
        case .system: return Color(UIColor.systemBackground)
        case .white: return Color.white
        case .cream: return Color(red: 0.96, green: 0.93, blue: 0.86)
        case .mint: return Color(red: 0.88, green: 0.93, blue: 0.93)
        case .sepia: return Color(red: 0.85, green: 0.77, blue: 0.68)
        case .dark: return Color(white: 0.1)
        }
    }

    var textColor: Color {
        switch self {
        case .system: return Color.primary
        case .white: return Color.black
        case .cream: return Color(red: 0.2, green: 0.2, blue: 0.2)
        case .mint: return Color(red: 0.15, green: 0.2, blue: 0.25)
        case .sepia: return Color(red: 0.27, green: 0.20, blue: 0.13)
        case .dark: return Color(white: 0.85)
        }
    }
}

enum SettingsTab {
    case typography
    case theme
    case reading
}

enum NovelFont: String, CaseIterable, Identifiable {
    case system = "System"
    case serif = "Serif"
    case monospaced = "Monospace"
    case rounded = "Rounded"
    var id: String { rawValue }

    var fontDesign: Font.Design {
        switch self {
        case .system: return .default
        case .serif: return .serif
        case .monospaced: return .monospaced
        case .rounded: return .rounded
        }
    }
}

struct NovelReaderSettingsView: View {
    @Binding var fontSize: Double
    @Binding var lineSpacing: Double
    @Binding var fontFamily: NovelFont
    @Binding var theme: NovelTheme
    @Binding var isPaging: Bool
    @Binding var prefetchChapters: Bool

    @State private var activeTab: SettingsTab = .typography
    @State private var brightness: CGFloat = UIScreen.main.brightness

    var body: some View {
        VStack(spacing: 20) {
            // Drag Handle
            Capsule()
                .fill(Color(UIColor.tertiaryLabel))
                .frame(width: 40, height: 5)
                .padding(.top, 12)

            // Core Controls
            if activeTab == .typography {
                typographyTab
            } else if activeTab == .theme {
                themeTab
            } else {
                readingTab
            }

            Spacer()

            // Bottom Toolbar (Footer)
            HStack {
                Spacer()

                Button(action: { activeTab = .typography }) {
                    Image(systemName: "textformat")
                        .font(.title2)
                        .frame(width: 60, height: 44)
                        .foregroundColor(activeTab == .typography ? .primary : Color(UIColor.tertiaryLabel))
                }

                Spacer()

                Button(action: { activeTab = .theme }) {
                    Image(systemName: "sun.max.fill")
                        .font(.title2)
                        .frame(width: 60, height: 44)
                        .foregroundColor(activeTab == .theme ? .primary : Color(UIColor.tertiaryLabel))
                }

                Spacer()

                Button(action: { activeTab = .reading }) {
                    Image(systemName: "book.fill")
                        .font(.title2)
                        .frame(width: 60, height: 44)
                        .foregroundColor(activeTab == .reading ? .primary : Color(UIColor.tertiaryLabel))
                }

                Spacer()
            }
            .padding(.bottom, 24)
        }
        .background(Color(UIColor.systemBackground))
    }

    private var typographyTab: some View {
        HStack(spacing: 16) {
            // Left Column: Font Size Stepper
            VStack(spacing: 0) {
                Button(action: { fontSize += 2 }) {
                    Text("A⁺")
                        .font(.title2.weight(.bold))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(UIColor.secondarySystemBackground))
                }

                Divider()

                Button(action: { if fontSize > 10 { fontSize -= 2 } }) {
                    Text("A⁻")
                        .font(.title2.weight(.bold))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(UIColor.tertiarySystemBackground))
                }
            }
            .foregroundColor(.primary)
            .frame(width: 70, height: 140)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

            // Right Column
            VStack(spacing: 16) {
                // Top Row: Font Family Selector
                Menu {
                    ForEach(NovelFont.allCases) { f in
                        Button(f.rawValue) { fontFamily = f }
                    }
                } label: {
                    HStack {
                        Image(systemName: "textformat")
                            .font(.title3)
                            .foregroundColor(.primary)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Reading fonts")
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(.primary)
                            Text(fontFamily.rawValue)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .frame(height: 62)
                    .background(Color(UIColor.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                // Bottom Row: Navigation Mode Toggle
                HStack(spacing: 4) {
                    Button(action: { isPaging = false }) {
                        VStack(spacing: 4) {
                            Image(systemName: "arrow.up.and.down")
                            Text("Scrolling")
                                .font(.caption.weight(.medium))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(!isPaging ? Color(UIColor.secondarySystemBackground) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .foregroundColor(!isPaging ? .primary : .secondary)
                    }

                    Button(action: { isPaging = true }) {
                        VStack(spacing: 4) {
                            Image(systemName: "arrow.left.and.right")
                            Text("Paging")
                                .font(.caption.weight(.medium))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(isPaging ? Color(UIColor.secondarySystemBackground) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .foregroundColor(isPaging ? .primary : .secondary)
                    }
                }
                .padding(4)
                .frame(height: 62)
                .background(Color(UIColor.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color(UIColor.secondarySystemBackground), lineWidth: 2)
                )
            }
        }
        .padding(.horizontal)
    }

    private var themeTab: some View {
        VStack(spacing: 20) {
            // Theme Color Selector
            HStack(spacing: 0) {
                ForEach(NovelTheme.allCases) { t in
                    Spacer()
                    Button(action: { theme = t }) {
                        ZStack {
                            if t == .system {
                                ZStack {
                                    Circle().fill(Color.white).frame(width: 44, height: 44)
                                    Circle().fill(Color.black).mask(HStack(spacing: 0) { Spacer(); Rectangle() })
                                }
                                .overlay(Circle().stroke(Color.gray.opacity(0.3), lineWidth: 1))
                            } else {
                                Circle()
                                    .fill(t.backgroundColor)
                                    .frame(width: 44, height: 44)
                            }

                            if t == .dark {
                                Image(systemName: "moon.stars.fill")
                                    .foregroundColor(.gray)
                            }

                            if theme == t {
                                Circle()
                                    .stroke(Color.primary, lineWidth: 2)
                                    .frame(width: 50, height: 50)

                                Image(systemName: "checkmark")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor((t == .dark || t == .system) ? .gray : .black)
                            }
                        }
                        .frame(width: 50, height: 50)
                    }
                    Spacer()
                }
            }
            .padding(.vertical, 16)
            .background(Color(UIColor.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

            // Custom Brightness Slider
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(UIColor.secondarySystemBackground))
                        .frame(height: 60)

                    Capsule()
                        .fill(Color(UIColor.systemGray3))
                        .frame(width: max(60, geo.size.width * brightness), height: 60)

                    HStack {
                        Image(systemName: "sun.min.fill")
                            .font(.title3)
                            .foregroundColor(Color(UIColor.tertiaryLabel))

                        Spacer()

                        Image(systemName: "sun.max.fill")
                            .font(.title3)
                            .foregroundColor(.primary)
                    }
                    .padding(.horizontal, 20)
                }
                .contentShape(Capsule())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let percent = value.location.x / geo.size.width
                            let newBrightness = max(0, min(1, percent))

                            if abs(brightness - newBrightness) > 0.01 {
                                brightness = newBrightness
                                UIScreen.main.brightness = newBrightness
                            }
                        }
                )
            }
            .frame(height: 60)
            .onAppear {
                brightness = UIScreen.main.brightness
            }
        }
        .padding(.horizontal)
    }

    private var readingTab: some View {
        VStack(spacing: 20) {
            Toggle(isOn: $prefetchChapters) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Seamless Reading")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text("Automatically fetch and append the next chapter as you approach the end of the current one.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .tint(Color.primary)
            .padding()
            .background(Color(UIColor.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            Spacer()
        }
        .padding(.horizontal)
    }
}

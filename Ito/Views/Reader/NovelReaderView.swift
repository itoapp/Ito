import SwiftUI
import ito_runner

struct NovelReaderView: View {
    let runner: ItoRunner
    let pluginId: String
    let novel: Novel
    @State var currentChapter: Novel.Chapter

    @EnvironmentObject var progressManager: ReadProgressManager

    @State private var pages: [Page] = []
    @State private var isLoaded = false
    @State private var errorMessage: String?

    // Appearance settings
    @AppStorage("Ito.NovelFontSize") private var fontSize: Double = 18.0
    @AppStorage("Ito.NovelLineSpacing") private var lineSpacing: Double = 8.0

    @Environment(\.dismiss) var dismiss

    var body: some View {
        ZStack {
            // Background
            Color(UIColor.systemBackground).edgesIgnoringSafeArea(.all)

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
                        Task { await loadPages() }
                    }
                    .padding()
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: CGFloat(lineSpacing)) {
                        Text(currentChapter.title ?? "Chapter \(currentChapter.chapter ?? 0)")
                            .font(.title)
                            .fontWeight(.bold)
                            .padding(.vertical)
                            .padding(.horizontal)

                        ForEach(pages, id: \.index) { page in
                            pageText(for: page)
                        }

                        // Bottom Navigation
                        HStack {
                            if previousChapter != nil {
                                Button(action: {
                                    if let prev = previousChapter {
                                        goToChapter(prev)
                                    }
                                }) {
                                    HStack {
                                        Image(systemName: "chevron.left")
                                        Text("Previous")
                                    }
                                    .padding()
                                    .frame(maxWidth: .infinity)
                                    .background(Color.secondary.opacity(0.2))
                                    .cornerRadius(8)
                                }
                            }

                            if nextChapter != nil {
                                Button(action: {
                                    if let next = nextChapter {
                                        goToChapter(next)
                                    }
                                }) {
                                    HStack {
                                        Text("Next")
                                        Image(systemName: "chevron.right")
                                    }
                                    .padding()
                                    .frame(maxWidth: .infinity)
                                    .background(Color.blue)
                                    .foregroundColor(.white)
                                    .cornerRadius(8)
                                }
                            }
                        }
                        .padding()
                        .padding(.bottom, safeAreaBottom + 40) // padding for safe area
                    }
                }
            }

            // Overlay Top Bar
            VStack {
                HStack {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.title3)
                            .padding(12)
                            .background(Color(UIColor.secondarySystemBackground).opacity(0.8))
                            .clipShape(Circle())
                    }
                    Spacer()

                    // Simple appearance controls overlay
                    Menu {
                        Button(action: { fontSize += 2 }) { Label("Increase Font Size", systemImage: "plus.magnifyingglass") }
                        Button(action: { if fontSize > 10 { fontSize -= 2 } }) { Label("Decrease Font Size", systemImage: "minus.magnifyingglass") }
                        Divider()
                        Button(action: { lineSpacing += 4 }) { Label("Increase Spacing", systemImage: "arrow.up.and.down") }
                        Button(action: { if lineSpacing > 0 { lineSpacing -= 4 } }) { Label("Decrease Spacing", systemImage: "arrow.down.to.line.compact") }
                    } label: {
                        Image(systemName: "textformat.size")
                            .font(.title3)
                            .padding(12)
                            .background(Color(UIColor.secondarySystemBackground).opacity(0.8))
                            .clipShape(Circle())
                    }
                }
                .padding()
                Spacer()
            }
        }
        .task {
            await loadPages()
        }
    }

    @ViewBuilder
    private func pageText(for page: Page) -> some View {
        switch page.content {
        case .text(let text):
            Text(text)
                .font(.system(size: CGFloat(fontSize)))
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
    func loadPages() async {
        guard !isLoaded else { return }
        do {
            let pageResult = try await runner.getChapterContent(novel: novel, chapter: currentChapter)
            await MainActor.run {
                self.pages = pageResult.sorted(by: { $0.index < $1.index })
                self.isLoaded = true

                let chapterTitleStr = currentChapter.title ?? currentChapter.key
                HistoryManager.shared.addNovel(novel, chapterTitle: chapterTitleStr, pluginId: pluginId)
                self.progressManager.markAsRead(mangaId: novel.key, chapterId: currentChapter.key, chapterNum: currentChapter.chapter)

                // Track progress
                Task {
                    if let chapterFloat = currentChapter.chapter {
                        await TrackerManager.shared.updateProgress(localId: novel.key, progress: Int(chapterFloat))
                    } else {
                        let titleOrFallback = currentChapter.title ?? currentChapter.key
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
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.isLoaded = true
            }
        }
    }

    func goToChapter(_ nextChap: Novel.Chapter) {
        currentChapter = nextChap
        isLoaded = false
        pages = []
        Task {
            await loadPages()
        }
    }

    var nextChapter: Novel.Chapter? {
        guard let chapters = novel.chapters,
              let currentIndex = chapters.firstIndex(where: { $0.key == currentChapter.key })
        else { return nil }

        let currentNum = currentChapter.chapter ?? -10000

        var targetIndex = currentIndex - 1
        while targetIndex >= 0 {
            let candidate = chapters[targetIndex]
            let candNum = candidate.chapter ?? -10000

            if candNum > currentNum + 0.0001 {
                return candidate
            }
            targetIndex -= 1
        }
        return nil
    }

    var previousChapter: Novel.Chapter? {
        guard let chapters = novel.chapters,
              let currentIndex = chapters.firstIndex(where: { $0.key == currentChapter.key })
        else { return nil }

        let currentNum = currentChapter.chapter ?? -10000

        var targetIndex = currentIndex + 1
        while targetIndex < chapters.count {
            let candidate = chapters[targetIndex]
            let candNum = candidate.chapter ?? -10000

            if candNum < currentNum - 0.0001 {
                return candidate
            }
            targetIndex += 1
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

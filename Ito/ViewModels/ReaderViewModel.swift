import Foundation
import Combine
import ito_runner

@MainActor
public final class ReaderViewModel<M: MediaDisplayable, C: ChapterDisplayable>: ObservableObject {
    @Published public var media: M
    @Published public var currentChapter: C

    public let pluginId: String
    private let progressManager: ReadProgressManager
    private let trackerManager: TrackerManager
    private let historyManager: HistoryManager

    nonisolated deinit {}

    public init(
        media: M,
        currentChapter: C,
        pluginId: String,
        progressManager: ReadProgressManager,
        trackerManager: TrackerManager,
        historyManager: HistoryManager
    ) {
        self.media = media
        self.currentChapter = currentChapter
        self.pluginId = pluginId
        self.progressManager = progressManager
        self.trackerManager = trackerManager
        self.historyManager = historyManager
    }

    public func markChapterRead() {
        let chapterTitleStr = currentChapter.title ?? currentChapter.key

        if let manga = media as? Manga {
            historyManager.addManga(
                manga,
                chapterKey: currentChapter.key,
                chapterTitle: chapterTitleStr,
                pluginId: pluginId
            )
        } else if let anime = media as? Anime {
            historyManager.addAnime(
                anime,
                episodeKey: currentChapter.key,
                episodeTitle: chapterTitleStr,
                pluginId: pluginId
            )
        } else if let novel = media as? Novel {
            historyManager.addNovel(
                novel,
                chapterKey: currentChapter.key,
                chapterTitle: chapterTitleStr,
                pluginId: pluginId
            )
        }

        Task {
            let identity = MediaIdentity(pluginId: pluginId, itemId: media.key)
            try await progressManager.markAsRead(
                media: identity,
                chapterId: currentChapter.key,
                chapterNum: currentChapter.chapterNumber
            )
            if let chapterFloat = currentChapter.chapterNumber {
                await trackerManager.updateProgress(media: identity, progress: Int(chapterFloat))
            } else {
                let titleOrFallback = currentChapter.title ?? currentChapter.key
                let words = titleOrFallback.components(separatedBy: .whitespacesAndNewlines)
                if let numberWord = words.first(where: { $0.rangeOfCharacter(from: .decimalDigits) != nil }) {
                    let numbersOnly = numberWord.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
                    if let chapNum = Int(numbersOnly) {
                        await trackerManager.updateProgress(media: identity, progress: chapNum)
                    }
                }
            }
        }
    }

    public func chapterAfter() -> M.Chapter? {
        guard let chapters = media.chapterList else { return nil }
        let currentNum = currentChapter.chapterNumber ?? -10000
        let validNextChapters = chapters.filter { ($0.chapterNumber ?? -10000) > currentNum + 0.0001 }
        guard let nextNum = validNextChapters.map({ $0.chapterNumber ?? -10000 }).min() else { return nil }
        return bestSource(for: nextNum, in: chapters)
    }

    public func chapterBefore() -> M.Chapter? {
        guard let chapters = media.chapterList else { return nil }
        let currentNum = currentChapter.chapterNumber ?? -10000
        let validPrevChapters = chapters.filter { ($0.chapterNumber ?? -10000) < currentNum - 0.0001 }
        guard let prevNum = validPrevChapters.map({ $0.chapterNumber ?? -10000 }).max() else { return nil }
        return bestSource(for: prevNum, in: chapters)
    }

    private func bestSource(for chapterNum: Float32, in chapters: [M.Chapter]) -> M.Chapter? {
        let sources = chapters.filter { abs(($0.chapterNumber ?? -10000) - chapterNum) < 0.0001 }
        if let match = sources.first(where: { $0.scanlator == currentChapter.scanlator }) {
            return match
        }
        return sources.first
    }
}

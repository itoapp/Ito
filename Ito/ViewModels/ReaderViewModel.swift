import Foundation
import Combine
import ito_runner

@MainActor
public class ReaderViewModel<M: MediaDisplayable, C: ChapterDisplayable>: ObservableObject {
    public let objectWillChange = PassthroughSubject<Void, Never>()

    public var media: M { willSet { objectWillChange.send() } }
    public var currentChapter: C { willSet { objectWillChange.send() } }

    public let pluginId: String
    private let progressManager = ReadProgressManager.shared

    public init(media: M, currentChapter: C, pluginId: String) {
        self.media = media
        self.currentChapter = currentChapter
        self.pluginId = pluginId
    }

    public func markChapterRead() {
        let chapterTitleStr = currentChapter.title ?? currentChapter.key

        if let manga = media as? Manga {
            HistoryManager.shared.addManga(manga, chapterKey: currentChapter.key, chapterTitle: chapterTitleStr, pluginId: pluginId)
        } else if let anime = media as? Anime {
            HistoryManager.shared.addAnime(anime, episodeKey: currentChapter.key, episodeTitle: chapterTitleStr, pluginId: pluginId)
        } else if let novel = media as? Novel {
            HistoryManager.shared.addNovel(novel, chapterKey: currentChapter.key, chapterTitle: chapterTitleStr, pluginId: pluginId)
        }

        progressManager.markAsRead(
            mangaId: media.key, chapterId: currentChapter.key, chapterNum: currentChapter.chapterNumber
        )

        Task {
            if let chapterFloat = currentChapter.chapterNumber {
                await TrackerManager.shared.updateProgress(localId: media.key, progress: Int(chapterFloat))
            } else {
                let titleOrFallback = currentChapter.title ?? currentChapter.key
                let words = titleOrFallback.components(separatedBy: .whitespacesAndNewlines)
                if let numberWord = words.first(where: { $0.rangeOfCharacter(from: .decimalDigits) != nil }) {
                    let numbersOnly = numberWord.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
                    if let chapNum = Int(numbersOnly) {
                        await TrackerManager.shared.updateProgress(localId: media.key, progress: chapNum)
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

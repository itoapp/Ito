import Foundation
import Combine
import ito_runner

public struct HistoryEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: String { item.id }
    public let item: LibraryItem
    public var lastReadAt: Date
    public var chapterTitle: String?

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

@MainActor
public class HistoryManager: ObservableObject {
    public static let shared = HistoryManager()

    @Published public private(set) var history: [HistoryEntry] = []

    private let defaultsKey = "ito_reading_history"

    private init() {
        loadHistory()
    }

    public func addManga(_ manga: Manga, chapterTitle: String, pluginId: String) {
        guard let payload = try? JSONEncoder().encode(manga) else { return }
        let item = LibraryItem(id: manga.key, title: manga.title, coverUrl: manga.cover, pluginId: pluginId, isAnime: false, pluginType: .manga, rawPayload: payload, anilistId: nil)
        addToHistory(item: item, chapterTitle: chapterTitle)
    }

    public func addNovel(_ novel: Novel, chapterTitle: String, pluginId: String) {
        guard let payload = try? JSONEncoder().encode(novel) else { return }
        let item = LibraryItem(id: novel.key, title: novel.title, coverUrl: novel.cover, pluginId: pluginId, isAnime: false, pluginType: .novel, rawPayload: payload, anilistId: nil)
        addToHistory(item: item, chapterTitle: chapterTitle)
    }

    public func addAnime(_ anime: Anime, episodeTitle: String, pluginId: String) {
        guard let payload = try? JSONEncoder().encode(anime) else { return }
        let item = LibraryItem(id: anime.key, title: anime.title, coverUrl: anime.cover, pluginId: pluginId, isAnime: true, pluginType: .anime, rawPayload: payload, anilistId: nil)
        addToHistory(item: item, chapterTitle: episodeTitle)
    }

    private func addToHistory(item: LibraryItem, chapterTitle: String) {
        let isIncognito = UserDefaults.standard.bool(forKey: "Ito.IncognitoMode")
        if isIncognito { return }

        if let index = history.firstIndex(where: { $0.id == item.id }) {
            history[index].lastReadAt = Date()
            history[index].chapterTitle = chapterTitle
        } else {
            let entry = HistoryEntry(item: item, lastReadAt: Date(), chapterTitle: chapterTitle)
            history.append(entry)
        }

        // sort descending
        history.sort(by: { $0.lastReadAt > $1.lastReadAt })

        // keep at most 100 entries
        if history.count > 100 {
            history.removeLast(history.count - 100)
        }

        saveHistory()
    }

    public func clearHistory() {
        history.removeAll()
        saveHistory()
    }

    private func loadHistory() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey) {
            if let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
                self.history = decoded
            }
        }
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

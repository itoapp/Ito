import Combine
import Foundation
import SwiftUI
import ito_runner

public struct LibraryItem: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let coverUrl: String?
    public let pluginId: String
    public let isAnime: Bool
    public var pluginType: PluginType? // Added to support Novel without breaking old saves

    // We store the raw payload so we can easily instantiate an Anime/Manga object when the user clicks it.
    public let rawPayload: Data

    // AniList Tracker Mapping
    public var anilistId: Int?

    public var effectiveType: PluginType {
        if let pt = pluginType { return pt }
        return isAnime ? .anime : .manga
    }

    public static func == (lhs: LibraryItem, rhs: LibraryItem) -> Bool {
        return lhs.id == rhs.id && lhs.anilistId == rhs.anilistId
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(anilistId)
    }
}

@MainActor
public class LibraryManager: ObservableObject {
    public static let shared = LibraryManager()

    @Published public private(set) var items: [LibraryItem] = []

    private let defaultsKey = "ito_library_items"

    private init() {
        loadLibrary()
    }

    public func isSaved(id: String) -> Bool {
        return items.contains(where: { $0.id == id })
    }

    public func removeItem(withId id: String) {
        if let index = items.firstIndex(where: { $0.id == id }) {
            items.remove(at: index)
            saveLibrary()
        }
    }

    public func toggleSaveManga(manga: Manga, pluginId: String) {
        if isSaved(id: manga.key) {
            items.removeAll(where: { $0.id == manga.key })
        } else {
            if let payload = try? JSONEncoder().encode(manga) {
                let item = LibraryItem(id: manga.key, title: manga.title, coverUrl: manga.cover, pluginId: pluginId, isAnime: false, pluginType: .manga, rawPayload: payload, anilistId: nil)
                items.append(item)
            }
        }
        saveLibrary()
    }

    public func toggleSaveNovel(novel: Novel, pluginId: String) {
        if isSaved(id: novel.key) {
            items.removeAll(where: { $0.id == novel.key })
        } else {
            if let payload = try? JSONEncoder().encode(novel) {
                let item = LibraryItem(id: novel.key, title: novel.title, coverUrl: novel.cover, pluginId: pluginId, isAnime: false, pluginType: .novel, rawPayload: payload, anilistId: nil)
                items.append(item)
            }
        }
        saveLibrary()
    }

    public func toggleSaveAnime(anime: Anime, pluginId: String) {
        if isSaved(id: anime.key) {
            items.removeAll(where: { $0.id == anime.key })
        } else {
            if let payload = try? JSONEncoder().encode(anime) {
                let item = LibraryItem(id: anime.key, title: anime.title, coverUrl: anime.cover, pluginId: pluginId, isAnime: true, pluginType: .anime, rawPayload: payload, anilistId: nil)
                items.append(item)
            }
        }
        saveLibrary()
    }

    public func setAnilistId(for itemId: String, anilistId: Int) {
        if let index = items.firstIndex(where: { $0.id == itemId }) {
            var updatedItem = items[index]
            updatedItem.anilistId = anilistId
            items[index] = updatedItem
            saveLibrary()
        }
    }

    public func removeAnilistId(for itemId: String) {
        if let index = items.firstIndex(where: { $0.id == itemId }) {
            var updatedItem = items[index]
            updatedItem.anilistId = nil
            items[index] = updatedItem
            saveLibrary()
        }
    }

    public func getAnilistId(for itemId: String) -> Int? {
        return items.first(where: { $0.id == itemId })?.anilistId
    }

    private func loadLibrary() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey) {
            if let decoded = try? JSONDecoder().decode([LibraryItem].self, from: data) {
                self.items = decoded
            }
        }
    }

    private func saveLibrary() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

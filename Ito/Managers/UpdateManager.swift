import Combine
import Foundation
import SwiftUI
import ito_runner

@MainActor
public class UpdateManager: ObservableObject {
    public static let shared = UpdateManager()

    /// Maps LibraryItem ID to the number of unread chapters/episodes
    @Published public private(set) var unreadCounts: [String: Int] = [:]

    /// Indicates if a refresh operation is currently actively running
    @Published public private(set) var isRefreshing: Bool = false

    /// Determinate Progress Tracking
    @Published public private(set) var totalItemsToCheck: Int = 0
    @Published public private(set) var itemsCheckedCurrentRun: Int = 0

    private let defaultsKey = "Ito.UpdateCounts"

    private init() {
        loadState()
    }

    // MARK: - Core Refresh Flow

    @MainActor
    public func checkForUpdates() async {
        guard !isRefreshing else {
            print("🔄 [UpdateManager] Already refreshing, skipping.")
            return
        }

        let items = LibraryManager.shared.items
        guard !items.isEmpty else {
            print("🔄 [UpdateManager] No library items to check.")
            return
        }

        print("🔄 [UpdateManager] Starting update check for \(items.count) items...")

        // Wait for PluginManager to finish loading plugins on cold start
        var waitAttempts = 0
        while PluginManager.shared.installedPlugins.isEmpty && waitAttempts < 20 {
            print("🔄 [UpdateManager] Waiting for plugins to load... (attempt \(waitAttempts + 1))")
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            waitAttempts += 1
        }

        guard !PluginManager.shared.installedPlugins.isEmpty else {
            print("🔄 [UpdateManager] No plugins loaded after waiting, aborting.")
            return
        }

        print("🔄 [UpdateManager] Plugins loaded, proceeding with \(PluginManager.shared.installedPlugins.count) plugins.")
        isRefreshing = true
        totalItemsToCheck = items.count
        itemsCheckedCurrentRun = 0

        // Process items sequentially — ItoRunner's WASM runtime is single-threaded
        // and deadlocks when multiple calls hit the same runner concurrently.
        for item in items {
            print("🔄 [UpdateManager] Checking: \(item.title)")
            await self.checkSingleItem(item)
        }

        print("🔄 [UpdateManager] Finished. Unread counts: \(unreadCounts)")
        isRefreshing = false
        saveState()
    }

    private func checkSingleItem(_ item: LibraryItem) async {
        print("🔄 [UpdateManager] Checking: \(item.title) (type: \(item.effectiveType))")
        do {
            let runner = try await PluginManager.shared.getRunner(for: item.pluginId)
            print("🔄 [UpdateManager] Got runner for: \(item.title)")

            var latestCount = 0
            var unreadCount = 0

            switch item.effectiveType {
            case .manga:
                let baseManga = try JSONDecoder().decode(Manga.self, from: item.rawPayload)
                print("🔄 [UpdateManager] Fetching manga update for: \(item.title)")
                let fullManga = try await runner.getMangaUpdate(manga: baseManga)
                latestCount = fullManga.chapters?.count ?? 0
                unreadCount = calculateUnread(mangaId: item.id, chapters: fullManga.chapters ?? [])

            case .anime:
                let baseAnime = try JSONDecoder().decode(Anime.self, from: item.rawPayload)
                print("🔄 [UpdateManager] Fetching anime update for: \(item.title)")
                let fullAnime = try await runner.getAnimeUpdate(anime: baseAnime, needsDetails: false, needsEpisodes: true)
                latestCount = fullAnime.episodes?.count ?? 0
                unreadCount = calculateUnread(animeId: item.id, episodes: fullAnime.episodes ?? [])

            case .novel:
                let baseNovel = try JSONDecoder().decode(Novel.self, from: item.rawPayload)
                print("🔄 [UpdateManager] Fetching novel update for: \(item.title)")
                let fullNovel = try await runner.getNovelUpdate(novel: baseNovel)
                latestCount = fullNovel.chapters?.count ?? 0
                unreadCount = calculateUnread(novelId: item.id, chapters: fullNovel.chapters ?? [])
            }

            print("🔄 [UpdateManager] \(item.title): \(latestCount) total, \(unreadCount) unread")

                if unreadCount > 0 {
                    self.unreadCounts[item.id] = unreadCount
                } else {
                    self.unreadCounts.removeValue(forKey: item.id)
                }
                self.itemsCheckedCurrentRun += 1
                print("🔄 [UpdateManager] Progress: \(self.itemsCheckedCurrentRun)/\(self.totalItemsToCheck)")

        } catch {
            print("🔄 [UpdateManager] ❌ Failed for \(item.title): \(error)")
            self.itemsCheckedCurrentRun += 1
        }
    }

    // MARK: - Unread Calculation Helpers

    private func calculateUnread(mangaId: String, chapters: [Manga.Chapter]) -> Int {
        // Deduplicate by chapter number to handle multi-source series
        var seenNumbers = Set<Float>()
        var uniqueChapters: [Manga.Chapter] = []
        for chapter in chapters {
            if let num = chapter.chapter {
                if seenNumbers.insert(num).inserted {
                    uniqueChapters.append(chapter)
                }
            } else {
                uniqueChapters.append(chapter) // no number, keep as unique
            }
        }
        var unread = 0
        for chapter in uniqueChapters {
            if !ReadProgressManager.shared.isRead(mangaId: mangaId, chapterId: chapter.key, chapterNum: chapter.chapter) {
                unread += 1
            }
        }
        return unread
    }

    private func calculateUnread(animeId: String, episodes: [Anime.Episode]) -> Int {
        var seenNumbers = Set<Float>()
        var uniqueEpisodes: [Anime.Episode] = []
        for episode in episodes {
            if let num = episode.episode {
                if seenNumbers.insert(num).inserted {
                    uniqueEpisodes.append(episode)
                }
            } else {
                uniqueEpisodes.append(episode)
            }
        }
        var unread = 0
        for episode in uniqueEpisodes {
            if !ReadProgressManager.shared.isRead(mangaId: animeId, chapterId: episode.key, chapterNum: episode.episode) {
                unread += 1
            }
        }
        return unread
    }

    private func calculateUnread(novelId: String, chapters: [Novel.Chapter]) -> Int {
        var seenNumbers = Set<Float>()
        var uniqueChapters: [Novel.Chapter] = []
        for chapter in chapters {
            if let num = chapter.chapter {
                if seenNumbers.insert(num).inserted {
                    uniqueChapters.append(chapter)
                }
            } else {
                uniqueChapters.append(chapter)
            }
        }
        var unread = 0
        for chapter in uniqueChapters {
            if !ReadProgressManager.shared.isRead(mangaId: novelId, chapterId: chapter.key, chapterNum: chapter.chapter) {
                unread += 1
            }
        }
        return unread
    }

    // MARK: - State Management

    @MainActor
    public func decrementBadge(for itemId: String) {
        guard let current = unreadCounts[itemId], current > 0 else { return }
        let newCount = current - 1
        if newCount <= 0 {
            unreadCounts.removeValue(forKey: itemId)
        } else {
            unreadCounts[itemId] = newCount
        }
        saveState()
    }

    /// Fully removes the badge for a given item (used after bulk operations like AniList sync)
    @MainActor
    public func clearBadge(for itemId: String) {
        if unreadCounts[itemId] != nil {
            unreadCounts.removeValue(forKey: itemId)
            saveState()
        }
    }

    private func loadState() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([String: Int].self, from: data) {
            self.unreadCounts = decoded
        }
    }

    private func saveState() {
        if let encoded = try? JSONEncoder().encode(unreadCounts) {
            UserDefaults.standard.set(encoded, forKey: defaultsKey)
        }
    }
}

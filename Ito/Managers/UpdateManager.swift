import Combine
import Foundation
import SwiftUI
import GRDB
import ito_runner

@MainActor
public class UpdateManager: ObservableObject {
    public static let shared = UpdateManager()

    /// Maps LibraryItem ID to the number of new chapters/episodes since last read
    @Published public private(set) var newChapterCounts: [String: Int] = [:]

    /// Indicates if a refresh operation is currently actively running
    @Published public private(set) var isRefreshing: Bool = false

    /// Determinate Progress Tracking
    @Published public private(set) var totalItemsToCheck: Int = 0
    @Published public private(set) var itemsCheckedCurrentRun: Int = 0

    private let defaultsKey = "Ito.NewChapterCounts"

    private let dbPool = AppDatabase.shared.dbPool

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

        _ = await runSmartUpdate(items: items, isBackground: false)
    }

    /// Entry point for BGAppRefreshTask.
    /// Returns the items that have new chapters and their new chapter count.
    @MainActor
    public func checkForUpdatesInBackground() async -> [(LibraryItem, Int)] {
        guard !isRefreshing else { return [] }

        print("🔄 [UpdateManager] Starting background update check.")
        let items: [LibraryItem]
        do {
            items = try await dbPool.read { db in
                try LibraryItem.fetchAll(db)
            }
        } catch {
            print("🔄 [UpdateManager] Background error fetching items: \(error)")
            return []
        }

        return await runSmartUpdate(items: items, isBackground: true)
    }

    @MainActor
    private func runSmartUpdate(items: [LibraryItem], isBackground: Bool) async -> [(LibraryItem, Int)] {
        print("🔄 [UpdateManager] Starting smart update check for \(items.count) total items...")

        // Wait for PluginManager to finish loading plugins on cold start
        var waitAttempts = 0
        while PluginManager.shared.installedPlugins.isEmpty && waitAttempts < 20 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            waitAttempts += 1
        }

        guard !PluginManager.shared.installedPlugins.isEmpty else {
            print("🔄 [UpdateManager] No plugins loaded, aborting.")
            return []
        }

        isRefreshing = true
        var updatedItemsWithCounts: [(LibraryItem, Int)] = []

        // 1. Filter out completed/cancelled if setting is on
        let skipCompleted = UserDefaults.standard.bool(forKey: UserDefaultsKeys.skipCompleted)
        var candidates = items
        if skipCompleted {
            candidates = candidates.filter { item in
                let status = item.status?.lowercased() ?? ""
                return status != "completed" && status != "cancelled"
            }
        }

        // 2. Score items
        var scoredItems: [(item: LibraryItem, score: Int)] = candidates.map { item in
            let score = calculateScore(for: item)
            return (item, score)
        }

        scoredItems.sort { $0.score > $1.score }

        // 3. Dynamic Batch Size (only for background updates)
        let maxBatchSize = max(5, items.count / 4)
        let batchItems = isBackground && items.count > 10
            ? Array(scoredItems.prefix(maxBatchSize).map(\.item))
            : scoredItems.map(\.item)

        totalItemsToCheck = batchItems.count
        itemsCheckedCurrentRun = 0

        print("🔄 [UpdateManager] Batch size: \(batchItems.count)")

        // 4. Check Items
        for item in batchItems {
            if Task.isCancelled { break }

            print("🔄 [UpdateManager] Checking: \(item.title)")
            if let newCount = await checkSingleItem(item) {
                updatedItemsWithCounts.append((item, newCount))
            }
            itemsCheckedCurrentRun += 1
            print("🔄 [UpdateManager] Progress: \(itemsCheckedCurrentRun)/\(totalItemsToCheck)")

            // Be gentle on source networks for big manual updates
            if !isBackground {
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            }
        }

        print("🔄 [UpdateManager] Finished smart update. Found \(updatedItemsWithCounts.count) new updates.")
        isRefreshing = false
        saveState()
        return updatedItemsWithCounts
    }

    private func calculateScore(for item: LibraryItem) -> Int {
        var baseStatusScore = 7 // Unknown/nil
        if let status = item.status?.lowercased() {
            if status.contains("ongoing") { baseStatusScore = 10 } else if status.contains("hiatus") { baseStatusScore = 3 }
        }

        let hoursSinceChecked: Int
        if let lastChecked = item.lastCheckedAt {
            let diff = Calendar.current.dateComponents([.hour], from: lastChecked, to: Date()).hour ?? 0
            hoursSinceChecked = min(24, max(0, diff))
        } else {
            hoursSinceChecked = 24
        }

        var recentUpdateBonus = 0
        if let lastUpdated = item.lastUpdatedAt {
            let daysSinceUpdate = Calendar.current.dateComponents([.day], from: lastUpdated, to: Date()).day ?? 999
            if daysSinceUpdate <= 7 {
                recentUpdateBonus = 30
            }
        }

        return baseStatusScore + hoursSinceChecked + recentUpdateBonus
    }

    private func checkSingleItem(_ item: LibraryItem) async -> Int? {
        do {
            let runner = try await PluginManager.shared.getRunner(for: item.pluginId)

            var freshCount = 0
            var newStatus: String?

            switch item.effectiveType {
            case .manga:
                let baseManga = try JSONDecoder().decode(Manga.self, from: item.rawPayload)
                let fullManga = try await runner.getMangaUpdate(manga: baseManga)
                freshCount = fullManga.chapters?.count ?? 0
                newStatus = String(describing: fullManga.status)
            case .anime:
                let baseAnime = try JSONDecoder().decode(Anime.self, from: item.rawPayload)
                let fullAnime = try await runner.getAnimeUpdate(anime: baseAnime, needsDetails: false, needsEpisodes: true)
                freshCount = fullAnime.episodes?.count ?? 0
                newStatus = String(describing: fullAnime.status)
            case .novel:
                let baseNovel = try JSONDecoder().decode(Novel.self, from: item.rawPayload)
                let fullNovel = try await runner.getNovelUpdate(novel: baseNovel)
                freshCount = fullNovel.chapters?.count ?? 0
                newStatus = String(describing: fullNovel.status)
            }

            let isInitialCheck = item.knownChapterCount == nil
            let knownCount = item.knownChapterCount ?? freshCount
            let newChapters = isInitialCheck ? 0 : max(0, freshCount - knownCount)
            let finalStatus = newStatus

            print("🔄 [UpdateManager] \(item.title): \(freshCount) total, \(knownCount) known -> \(newChapters) new")

            try await dbPool.write { db in
                if var dbItem = try LibraryItem.fetchOne(db, key: item.id) {
                    dbItem.lastCheckedAt = Date()
                    if newChapters > 0 {
                        dbItem.lastUpdatedAt = Date()
                    }
                    if let status = finalStatus {
                        dbItem.status = status
                    }
                    try dbItem.update(db)

                    // Also trigger the LibraryManager list refresh by modifying the active payload?
                    // Actually, LibraryManager reacts to database changes via ValueObservation
                }
            }

            if newChapters > 0 {
                newChapterCounts[item.id] = newChapters
                return newChapters
            } else {
                newChapterCounts.removeValue(forKey: item.id)
            }

            return nil

        } catch {
            print("🔄 [UpdateManager] ❌ Failed for \(item.title): \(error)")
            return nil
        }
    }

    // MARK: - State Management

    @MainActor
    public func clearBadge(for itemId: String) {
        if newChapterCounts[itemId] != nil {
            newChapterCounts.removeValue(forKey: itemId)
            saveState()
        }
    }

    private func loadState() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([String: Int].self, from: data) {
            self.newChapterCounts = decoded
        }
    }

    private func saveState() {
        if let encoded = try? JSONEncoder().encode(newChapterCounts) {
            UserDefaults.standard.set(encoded, forKey: defaultsKey)
        }
    }
}

import OSLog
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

    private let dbPool: DatabasePool

    internal init(
        dbPool: DatabasePool = AppDatabase.shared.dbPool,
        loadsPersistedState: Bool = true
    ) {
        self.dbPool = dbPool
        if loadsPersistedState {
            loadState()
        }
    }

    // MARK: - Core Refresh Flow

    @MainActor
    public func checkForUpdates() async {
        guard !isRefreshing else {
            AppLogger.update.debug("🔄 [UpdateManager] Already refreshing, skipping.")
            return
        }

        let items = LibraryManager.shared.items
        guard !items.isEmpty else {
            AppLogger.update.debug("🔄 [UpdateManager] No library items to check.")
            return
        }

        _ = await runSmartUpdate(items: items, isBackground: false)
    }

    /// Entry point for BGAppRefreshTask.
    /// Returns the items that have new chapters and their new chapter count.
    @MainActor
    public func checkForUpdatesInBackground() async -> [(LibraryItem, Int)] {
        guard !isRefreshing else { return [] }

        AppLogger.update.debug("🔄 [UpdateManager] Starting background update check.")
        let items: [LibraryItem]
        do {
            items = try await dbPool.read { db in
                try LibraryItem.fetchAll(db)
            }
        } catch {
            AppLogger.update.error("🔄 [UpdateManager] Background error fetching items: \(error)")
            return []
        }

        return await runSmartUpdate(items: items, isBackground: true)
    }

    @MainActor
    private func runSmartUpdate(items: [LibraryItem], isBackground: Bool) async -> [(LibraryItem, Int)] {
        AppLogger.update.debug("\("🔄 [UpdateManager] Starting smart update check for \(items.count)") total items...")

        // Wait for PluginManager to finish loading plugins on cold start
        var waitAttempts = 0
        while PluginManager.shared.installedPlugins.isEmpty && waitAttempts < 20 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            waitAttempts += 1
        }

        guard !PluginManager.shared.installedPlugins.isEmpty else {
            AppLogger.update.debug("🔄 [UpdateManager] No plugins loaded, aborting.")
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

        AppLogger.update.debug("🔄 [UpdateManager] Batch size: \(batchItems.count)")

        // 4. Check Items
        for item in batchItems {
            if Task.isCancelled { break }

            AppLogger.update.debug("🔄 [UpdateManager] Checking: \(item.title)")
            if let newCount = await checkSingleItem(item) {
                updatedItemsWithCounts.append((item, newCount))
            }
            itemsCheckedCurrentRun += 1
            AppLogger.update.debug("🔄 [UpdateManager] Progress: \(self.itemsCheckedCurrentRun)/\(self.totalItemsToCheck)")

            // Be gentle on source networks for big manual updates
            if !isBackground {
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            }
        }

        AppLogger.update.debug("\("🔄 [UpdateManager] Finished smart update. Found \(updatedItemsWithCounts.count)") new updates.")
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

            let delta = await processUpdate(for: item) {
                switch item.effectiveType {
                case .manga:
                    let baseManga = try JSONDecoder().decode(Manga.self, from: item.rawPayload)
                    let fullManga = try await runner.getMangaUpdate(manga: baseManga)
                    return SuccessfulUpdate(
                        freshCount: fullManga.chapters?.count ?? 0,
                        status: String(describing: fullManga.status)
                    )
                case .anime:
                    let baseAnime = try JSONDecoder().decode(Anime.self, from: item.rawPayload)
                    let fullAnime = try await runner.getAnimeUpdate(
                        anime: baseAnime,
                        needsDetails: false,
                        needsEpisodes: true
                    )
                    return SuccessfulUpdate(
                        freshCount: fullAnime.episodes?.count ?? 0,
                        status: String(describing: fullAnime.status)
                    )
                case .novel:
                    let baseNovel = try JSONDecoder().decode(Novel.self, from: item.rawPayload)
                    let fullNovel = try await runner.getNovelUpdate(novel: baseNovel)
                    return SuccessfulUpdate(
                        freshCount: fullNovel.chapters?.count ?? 0,
                        status: String(describing: fullNovel.status)
                    )
                }
            }

            guard let delta, delta > 0 else { return nil }
            return delta

        } catch {
            AppLogger.update.error("\("🔄 [UpdateManager] ❌ Failed for \(item.title)"): \(error)")
            return nil
        }
    }

    internal struct SuccessfulUpdate: Sendable {
        let freshCount: Int
        let status: String?
    }

    /// Persists a fetched update and derives badge state only from committed database state.
    internal func processUpdate(
        for item: LibraryItem,
        checkedAt: Date = Date(),
        fetchUpdate: () async throws -> SuccessfulUpdate
    ) async -> Int? {
        do {
            let update = try await fetchUpdate()
            let committed = try await dbPool.write { db -> (oldCount: Int?, delta: Int)? in
                guard var dbItem = try LibraryItem.fetchOne(db, key: item.id) else {
                    return nil
                }

                let oldCount = dbItem.knownChapterCount
                let delta = oldCount.map { max(0, update.freshCount - $0) } ?? 0
                dbItem.knownChapterCount = update.freshCount
                dbItem.lastCheckedAt = checkedAt
                if delta > 0 {
                    dbItem.lastUpdatedAt = checkedAt
                }
                if let status = update.status {
                    dbItem.status = status
                }
                try dbItem.update(db)
                return (oldCount, delta)
            }

            guard let committed else {
                newChapterCounts.removeValue(forKey: item.id)
                return nil
            }

            AppLogger.update.debug(
                "🔄 [UpdateManager] \(item.title): \(String(describing: committed.oldCount)) known, \(update.freshCount) fresh/persisted -> \(committed.delta) new"
            )
            if committed.delta > 0 {
                newChapterCounts[item.id] = committed.delta
            } else {
                newChapterCounts.removeValue(forKey: item.id)
            }
            return committed.delta
        } catch {
            AppLogger.update.error("🔄 [UpdateManager] ❌ Failed for \(item.title): \(error)")
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

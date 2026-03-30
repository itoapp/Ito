import Combine
import Foundation
import GRDB
import SwiftUI
import ito_runner

@MainActor
public class LibraryManager: ObservableObject, LibraryManaging {
    public static let shared = LibraryManager()

    @Published public private(set) var categories: [LibraryCategory] = []
    @Published public private(set) var items: [LibraryItem] = []
    @Published public private(set) var links: [ItemCategoryLink] = []

    @Published public var isLoading: Bool = true

    private var categoryObserver: DatabaseCancellable?
    private var itemObserver: DatabaseCancellable?
    private var linkObserver: DatabaseCancellable?
    private let dbPool: DatabasePool

    private init() {
        self.dbPool = AppDatabase.shared.dbPool
        Task {
            await migrateLegacyDataSafely()
            startObservation()
        }
    }

    // MARK: - Phase 2: The Bulletproof Migration
    private func migrateLegacyDataSafely() async {
        do {
            let legacyKey = UserDefaultsKeys.legacyLibraryItems
            let backupKey = UserDefaultsKeys.backupLibraryItems

            try await dbPool.write { db in
                // 1. The Guard: check if the "Uncategorized" category exists
                if try LibraryCategory.filter(Column("isSystemCategory") == true).fetchCount(db) > 0 {
                    return // Migration already happened!
                }

                // 2. The Atomic Transaction
                let systemCategory = LibraryCategory(name: "Uncategorized", sortOrder: 0, isSystemCategory: true)
                try systemCategory.insert(db)

                // 3. Resilient Decoding
                let defaults = UserDefaults.standard

                if let data = defaults.data(forKey: legacyKey) {
                    if let legacyItems = try? JSONDecoder().decode([LibraryItem].self, from: data) {
                        for item in legacyItems {
                            try item.insert(db) // Valid ones are saved
                            let link = ItemCategoryLink(itemId: item.id, categoryId: systemCategory.id)
                            try link.insert(db)
                        }
                    }

                    // 4. Backup & Cleanup
                    defaults.set(data, forKey: backupKey)
                    defaults.removeObject(forKey: legacyKey)
                }
            }
        } catch {
            print("❌ Migration Failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Phase 3: Reactive State Observation
    private func startObservation() {
        // Observe Categories
        let catObservation = ValueObservation.tracking { db in
            try LibraryCategory.order(Column("sortOrder")).fetchAll(db)
        }
        categoryObserver = catObservation.start(in: dbPool, onError: { error in
            print("Category observation error: \(error)")
        }, onChange: { [weak self] categories in
            Task { @MainActor in
                self?.categories = categories
                self?.checkLoadingState()
            }
        })

        // Observe Items
        let itemObs = ValueObservation.tracking { db in
            try LibraryItem.order(Column("title")).fetchAll(db)
        }
        itemObserver = itemObs.start(in: dbPool, onError: { error in
            print("Item observation error: \(error)")
        }, onChange: { [weak self] items in
            Task { @MainActor in
                self?.items = items
                self?.checkLoadingState()
            }
        })

        // Observe Links
        let linkObs = ValueObservation.tracking { db in
            try ItemCategoryLink.fetchAll(db)
        }
        linkObserver = linkObs.start(in: dbPool, onError: { error in
            print("Link observation error: \(error)")
        }, onChange: { [weak self] links in
            Task { @MainActor in
                self?.links = links
                self?.checkLoadingState()
            }
        })
    }

    private var observationEmissionsReady = 0
    private func checkLoadingState() {
        // We wait for all 3 observations to emit at least once
        observationEmissionsReady += 1
        if observationEmissionsReady >= 3 && isLoading {
            isLoading = false
        }
    }

    // MARK: - Legacy Plugin Toggles Compatibility

    public func isSaved(id: String) -> Bool {
        return items.contains(where: { $0.id == id })
    }

    public func removeItem(withId id: String) {
        Task {
            do {
                try await dbPool.write { db in
                    if let existing = try LibraryItem.fetchOne(db, key: id) {
                        try existing.delete(db)
                    }
                }
            } catch {
                print("Failed to remove item: \(error)")
            }
        }
    }

    private func saveOrRemoveItem(id: String, itemProvider: () -> LibraryItem) {
        let generatedItem = itemProvider()
        Task {
            do {
                try await dbPool.write { db in
                    if let existing = try LibraryItem.fetchOne(db, key: id) {
                        try existing.delete(db) // CASCADE will delete links
                    } else {
                        let newItem = generatedItem
                        try newItem.insert(db)
                        if let uncategorized = try LibraryCategory.filter(Column("isSystemCategory") == true).fetchOne(db) {
                            let link = ItemCategoryLink(itemId: id, categoryId: uncategorized.id)
                            try link.insert(db)
                        }
                    }
                }
            } catch {
                print("Failed to toggle item: \(error)")
            }
        }
    }

    public func toggleSaveManga(manga: Manga, pluginId: String) {
        let payload = (try? JSONEncoder().encode(manga)) ?? Data()
        let count = manga.chapters?.count ?? 0
        saveOrRemoveItem(id: manga.key) {
            LibraryItem(id: manga.key, title: manga.title, coverUrl: manga.cover, pluginId: pluginId, isAnime: false, pluginType: .manga, rawPayload: payload, anilistId: nil, knownChapterCount: count)
        }
    }

    public func toggleSaveNovel(novel: Novel, pluginId: String) {
        let payload = (try? JSONEncoder().encode(novel)) ?? Data()
        let count = novel.chapters?.count ?? 0
        saveOrRemoveItem(id: novel.key) {
            LibraryItem(id: novel.key, title: novel.title, coverUrl: novel.cover, pluginId: pluginId, isAnime: false, pluginType: .novel, rawPayload: payload, anilistId: nil, knownChapterCount: count)
        }
    }

    public func toggleSaveAnime(anime: Anime, pluginId: String) {
        let payload = (try? JSONEncoder().encode(anime)) ?? Data()
        let count = anime.episodes?.count ?? 0
        saveOrRemoveItem(id: anime.key) {
            LibraryItem(id: anime.key, title: anime.title, coverUrl: anime.cover, pluginId: pluginId, isAnime: true, pluginType: .anime, rawPayload: payload, anilistId: nil, knownChapterCount: count)
        }
    }

    // MARK: - Category CRUD

    public func createCategory(name: String) async throws -> String {
        return try await dbPool.write { db in
            let maxOrder = try Int.fetchOne(db, sql: "SELECT MAX(sortOrder) FROM libraryCategory") ?? 0
            let newCat = LibraryCategory(name: name, sortOrder: maxOrder + 1)
            try newCat.insert(db)
            return newCat.id
        }
    }

    public func deleteCategory(id: String) {
        Task {
            do {
                try await dbPool.write { db in
                    guard let cat = try LibraryCategory.fetchOne(db, key: id), !cat.isSystemCategory else { return }
                    try cat.delete(db) // Cascade deletes links

                    // Self Healing Query: reassign orphaned items to Uncategorized
                    let uncategorized = try LibraryCategory.filter(Column("isSystemCategory") == true).fetchOne(db)
                    if let systemId = uncategorized?.id {
                        let orphanedItems = try LibraryItem.fetchAll(db, sql: """
                            SELECT libraryItem.* FROM libraryItem
                            LEFT JOIN itemCategoryLink ON libraryItem.id = itemCategoryLink.itemId
                            WHERE itemCategoryLink.categoryId IS NULL
                        """)

                        for item in orphanedItems {
                            let link = ItemCategoryLink(itemId: item.id, categoryId: systemId)
                            try link.insert(db)
                        }
                    }
                }
            } catch {
                print("Failed to delete category: \(error)")
            }
        }
    }

    public func toggleCategory(forItemId itemId: String, categoryId: String) {
        Task {
            do {
                try await dbPool.write { db in
                    // Find the system "Uncategorized" category
                    let systemCat = try LibraryCategory.filter(Column("isSystemCategory") == true).fetchOne(db)

                    if let existing = try ItemCategoryLink.fetchOne(db, key: ["itemId": itemId, "categoryId": categoryId]) {
                        // REMOVING from this category
                        try existing.delete(db)

                        // If the item now has zero links, push back to Uncategorized
                        let remaining = try ItemCategoryLink.filter(Column("itemId") == itemId).fetchCount(db)
                        if remaining == 0, let sysId = systemCat?.id {
                            let link = ItemCategoryLink(itemId: itemId, categoryId: sysId)
                            try link.insert(db)
                        }
                    } else {
                        // ADDING to this category
                        let link = ItemCategoryLink(itemId: itemId, categoryId: categoryId)
                        try link.insert(db)

                        // If we just added a custom category, remove the Uncategorized link
                        if let sysId = systemCat?.id, categoryId != sysId {
                            if let uncatLink = try ItemCategoryLink.fetchOne(db, key: ["itemId": itemId, "categoryId": sysId]) {
                                try uncatLink.delete(db)
                            }
                        }
                    }
                }
            } catch {
                print("Failed to toggle link: \(error)")
            }
        }
    }

    public func reorderCategories(newOrder: [LibraryCategory]) {
        Task {
            do {
                try await dbPool.write { db in
                    for (index, cat) in newOrder.enumerated() {
                        var updatedCat = cat
                        updatedCat.sortOrder = index
                        try updatedCat.update(db)
                    }
                }
            } catch {
                print("Failed to reorder: \(error)")
            }
        }
    }

    // MARK: - AniList Interactions

    public func setAnilistId(for itemId: String, anilistId: Int) {
        Task {
            do {
                try await dbPool.write { db in
                    if var item = try LibraryItem.fetchOne(db, key: itemId) {
                        item.anilistId = anilistId
                        try item.update(db)
                    }
                }
            } catch {}
        }
    }

    public func removeAnilistId(for itemId: String) {
        Task {
            do {
                try await dbPool.write { db in
                    if var item = try LibraryItem.fetchOne(db, key: itemId) {
                        item.anilistId = nil
                        try item.update(db)
                    }
                }
            } catch {}
        }
    }

    public func getAnilistId(for itemId: String) -> Int? {
        return items.first(where: { $0.id == itemId })?.anilistId
    }
}

import OSLog
import Combine
import Foundation
import GRDB
import SwiftUI
import ito_runner

@MainActor
public class LibraryManager: ObservableObject, LibraryManaging {
    enum DurableMutationError: Error {
        case identifierCollision
    }

    public static let shared = LibraryManager(dbPool: AppDatabase.shared.dbPool)

    @Published public private(set) var categories: [LibraryCategory] = []
    @Published public private(set) var items: [LibraryItem] = []
    @Published public private(set) var links: [ItemCategoryLink] = []

    @Published public var isLoading: Bool = true

    private var categoryObserver: DatabaseCancellable?
    private var itemObserver: DatabaseCancellable?
    private var linkObserver: DatabaseCancellable?
    private let dbPool: DatabasePool

    private struct DurableSnapshot {
        let categories: [LibraryCategory]
        let items: [LibraryItem]
        let links: [ItemCategoryLink]
    }

    public init(dbPool: DatabasePool) {
        self.dbPool = dbPool
        startObservation()
    }

    public func reload() async throws {
        let snapshot = try await dbPool.read { db in
            (
                try LibraryCategory.order(Column("sortOrder")).fetchAll(db),
                try LibraryItem.order(Column("title")).fetchAll(db),
                try ItemCategoryLink.fetchAll(db)
            )
        }
        categories = snapshot.0
        items = snapshot.1
        links = snapshot.2
        isLoading = false
    }

    // MARK: - Phase 3: Reactive State Observation
    private func startObservation() {
        // Observe Categories
        let catObservation = ValueObservation.tracking { db in
            try LibraryCategory.order(Column("sortOrder")).fetchAll(db)
        }
        categoryObserver = catObservation.start(in: dbPool, onError: { error in
            AppLogger.database.error("Category observation error: \(error)")
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
            AppLogger.database.error("Item observation error: \(error)")
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
            AppLogger.database.error("Link observation error: \(error)")
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
        return items.contains(where: { $0.id == id || $0.id == "\($0.pluginId)_\(id)" })
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
                AppLogger.database.error("Failed to remove item: \(error)")
            }
        }
    }

    private func saveOrRemoveItem(id: String, itemProvider: () -> LibraryItem) {
        let generatedItem = itemProvider()
        let legacyId = "\(generatedItem.pluginId)_\(id)"

        Task {
            do {
                try await dbPool.write { db in
                    // Check for either the standard ID or the legacy plugin-prefixed ID
                    let existingItem = try LibraryItem.fetchOne(db, sql: "SELECT * FROM libraryItem WHERE id = ? OR id = ?", arguments: [id, legacyId])

                    if let existing = existingItem {
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
                AppLogger.database.error("Failed to toggle item: \(error)")
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

    // MARK: - Awaitable Media Detail Mutations

    func saveMangaDurably(manga: Manga, pluginId: String) async throws -> String {
        let payload = try JSONEncoder().encode(manga)
        return try await saveItemDurably(
            sourceItemID: manga.key,
            item: LibraryItem(
                id: manga.key,
                title: manga.title,
                coverUrl: manga.cover,
                pluginId: pluginId,
                isAnime: false,
                pluginType: .manga,
                rawPayload: payload,
                anilistId: nil,
                knownChapterCount: manga.chapters?.count ?? 0
            )
        )
    }

    func saveAnimeDurably(anime: Anime, pluginId: String) async throws -> String {
        let payload = try JSONEncoder().encode(anime)
        return try await saveItemDurably(
            sourceItemID: anime.key,
            item: LibraryItem(
                id: anime.key,
                title: anime.title,
                coverUrl: anime.cover,
                pluginId: pluginId,
                isAnime: true,
                pluginType: .anime,
                rawPayload: payload,
                anilistId: nil,
                knownChapterCount: anime.episodes?.count ?? 0
            )
        )
    }

    func saveNovelDurably(novel: Novel, pluginId: String) async throws -> String {
        let payload = try JSONEncoder().encode(novel)
        return try await saveItemDurably(
            sourceItemID: novel.key,
            item: LibraryItem(
                id: novel.key,
                title: novel.title,
                coverUrl: novel.cover,
                pluginId: pluginId,
                isAnime: false,
                pluginType: .novel,
                rawPayload: payload,
                anilistId: nil,
                knownChapterCount: novel.chapters?.count ?? 0
            )
        )
    }

    func removeItemDurably(id: String, pluginId: String) async throws {
        let possibleIDs = [id, "\(pluginId)_\(id)"]
        let snapshot = try await dbPool.write { db in
            for possibleID in possibleIDs {
                guard let existing = try LibraryItem.fetchOne(db, key: possibleID),
                      existing.pluginId == pluginId else { continue }
                try existing.delete(db)
            }
            return try Self.fetchDurableSnapshot(db)
        }
        apply(snapshot)
    }

    private func saveItemDurably(
        sourceItemID: String,
        item: LibraryItem
    ) async throws -> String {
        let legacyID = "\(item.pluginId)_\(sourceItemID)"
        let mutation = try await dbPool.write { db in
            let sourceItem = try LibraryItem.fetchOne(db, key: sourceItemID)
            let legacyItem = try LibraryItem.fetchOne(db, key: legacyID)
            let ownedItem = [sourceItem, legacyItem]
                .compactMap { $0 }
                .first { $0.pluginId == item.pluginId }
            let storedItem: LibraryItem
            if let ownedItem {
                storedItem = ownedItem
            } else {
                if sourceItem == nil {
                    storedItem = item
                } else if legacyItem == nil {
                    storedItem = Self.copy(item, replacingIDWith: legacyID)
                } else {
                    throw DurableMutationError.identifierCollision
                }
                try storedItem.insert(db)
                if let uncategorized = try LibraryCategory
                    .filter(Column("isSystemCategory") == true)
                    .fetchOne(db) {
                    try ItemCategoryLink(
                        itemId: storedItem.id,
                        categoryId: uncategorized.id
                    ).insert(db)
                }
            }
            return (try Self.fetchDurableSnapshot(db), storedItem.id)
        }
        apply(mutation.0)
        return mutation.1
    }

    nonisolated private static func copy(
        _ item: LibraryItem,
        replacingIDWith id: String
    ) -> LibraryItem {
        LibraryItem(
            id: id,
            title: item.title,
            coverUrl: item.coverUrl,
            pluginId: item.pluginId,
            isAnime: item.isAnime,
            pluginType: item.pluginType,
            rawPayload: item.rawPayload,
            anilistId: item.anilistId,
            status: item.status,
            lastCheckedAt: item.lastCheckedAt,
            lastUpdatedAt: item.lastUpdatedAt,
            knownChapterCount: item.knownChapterCount
        )
    }

    nonisolated private static func fetchDurableSnapshot(
        _ db: Database
    ) throws -> DurableSnapshot {
        DurableSnapshot(
            categories: try LibraryCategory.order(Column("sortOrder")).fetchAll(db),
            items: try LibraryItem.order(Column("title")).fetchAll(db),
            links: try ItemCategoryLink.fetchAll(db)
        )
    }

    private func apply(_ snapshot: DurableSnapshot) {
        categories = snapshot.categories
        items = snapshot.items
        links = snapshot.links
        isLoading = false
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

    public func renameCategory(id: String, to name: String) async throws {
        try await dbPool.write { db in
            guard var category = try LibraryCategory.fetchOne(db, key: id) else {
                throw LibraryCategory.recordNotFound(key: ["id": id])
            }
            category.name = name
            try category.update(db)
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
                AppLogger.database.error("Failed to delete category: \(error)")
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
                AppLogger.database.error("Failed to toggle link: \(error)")
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
                AppLogger.database.error("Failed to reorder: \(error)")
            }
        }
    }

}

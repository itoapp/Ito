import Combine
import Foundation
import GRDB
import ito_runner

// MARK: - Display Model (used by HistoryView)

public struct HistoryEntry: Identifiable, Hashable, Sendable {
    public var id: String { record.id }
    public let record: ReadingHistoryRecord

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: HistoryEntry, rhs: HistoryEntry) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - History Manager

@MainActor
public class HistoryManager: ObservableObject {
    public static let shared = HistoryManager()

    @Published public private(set) var history: [HistoryEntry] = []

    private let dbPool: DatabasePool
    private var observationCancellable: DatabaseCancellable?

    private let legacyDefaultsKey = "ito_reading_history"

    private init() {
        self.dbPool = AppDatabase.shared.dbPool
        migrateFromUserDefaults()
        startObservation()
    }

    // MARK: - Observation

    private func startObservation() {
        let observation = ValueObservation.tracking { db -> [ReadingHistoryRecord] in
            try ReadingHistoryRecord
                .order(ReadingHistoryRecord.Columns.readAt.desc)
                .limit(200)
                .fetchAll(db)
        }

        observationCancellable = observation.start(
            in: dbPool,
            onError: { error in
                print("[HistoryManager] Observation error: \(error)")
            },
            onChange: { [weak self] records in
                Task { @MainActor in
                    self?.history = records.map { HistoryEntry(record: $0) }
                }
            }
        )
    }

    // MARK: - Add History

    public func addManga(_ manga: Manga, chapterKey: String, chapterTitle: String, pluginId: String) {
        let isIncognito = UserDefaults.standard.bool(forKey: "Ito.IncognitoMode")
        if isIncognito { return }

        let libraryItemId = LibraryManager.shared.isSaved(id: manga.key) ? manga.key : nil

        let record = ReadingHistoryRecord(
            libraryItemId: libraryItemId,
            mediaKey: manga.key,
            title: manga.title,
            coverUrl: manga.cover,
            pluginId: pluginId,
            chapterKey: chapterKey,
            chapterTitle: chapterTitle
        )
        insertRecord(record)
    }

    public func addNovel(_ novel: Novel, chapterKey: String, chapterTitle: String, pluginId: String) {
        let isIncognito = UserDefaults.standard.bool(forKey: "Ito.IncognitoMode")
        if isIncognito { return }

        let libraryItemId = LibraryManager.shared.isSaved(id: novel.key) ? novel.key : nil

        let record = ReadingHistoryRecord(
            libraryItemId: libraryItemId,
            mediaKey: novel.key,
            title: novel.title,
            coverUrl: novel.cover,
            pluginId: pluginId,
            chapterKey: chapterKey,
            chapterTitle: chapterTitle
        )
        insertRecord(record)
    }

    public func addAnime(_ anime: Anime, episodeKey: String, episodeTitle: String, pluginId: String) {
        let isIncognito = UserDefaults.standard.bool(forKey: "Ito.IncognitoMode")
        if isIncognito { return }

        let libraryItemId = LibraryManager.shared.isSaved(id: anime.key) ? anime.key : nil

        let record = ReadingHistoryRecord(
            libraryItemId: libraryItemId,
            mediaKey: anime.key,
            title: anime.title,
            coverUrl: anime.cover,
            pluginId: pluginId,
            chapterKey: episodeKey,
            chapterTitle: episodeTitle
        )
        insertRecord(record)
    }

    private func insertRecord(_ record: ReadingHistoryRecord) {
        Task {
            do {
                try await dbPool.write { db in
                    try record.insert(db)
                }
            } catch {
                print("[HistoryManager] Failed to insert: \(error)")
            }
        }
    }

    // MARK: - Delete

    public func removeEntry(id: String) {
        Task {
            do {
                try await dbPool.write { db in
                    _ = try ReadingHistoryRecord.deleteOne(db, key: id)
                }
            } catch {
                print("[HistoryManager] Failed to remove entry: \(error)")
            }
        }
    }

    public func clearHistory() {
        Task {
            do {
                try await dbPool.write { db in
                    _ = try ReadingHistoryRecord.deleteAll(db)
                }
            } catch {
                print("[HistoryManager] Failed to clear history: \(error)")
            }
        }
    }

    // MARK: - Migration from UserDefaults

    private func migrateFromUserDefaults() {
        // Legacy HistoryEntry stored in UserDefaults as JSON
        struct LegacyHistoryEntry: Codable {
            let item: LibraryItem
            var lastReadAt: Date
            var chapterTitle: String?
        }

        guard let data = UserDefaults.standard.data(forKey: legacyDefaultsKey),
              let legacy = try? JSONDecoder().decode([LegacyHistoryEntry].self, from: data) else {
            return
        }

        Task {
            do {
                try await dbPool.write { db in
                    for entry in legacy {
                        let record = ReadingHistoryRecord(
                            libraryItemId: entry.item.id,
                            mediaKey: entry.item.id,
                            title: entry.item.title,
                            coverUrl: entry.item.coverUrl,
                            pluginId: entry.item.pluginId,
                            chapterKey: entry.chapterTitle ?? "unknown",
                            chapterTitle: entry.chapterTitle,
                            readAt: entry.lastReadAt
                        )
                        try record.insert(db)
                    }
                }
                // Clean up legacy data
                UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
                print("[HistoryManager] Migrated \(legacy.count) entries from UserDefaults")
            } catch {
                print("[HistoryManager] Migration failed: \(error)")
            }
        }
    }
}

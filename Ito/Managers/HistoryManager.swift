import OSLog
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
    public static let shared = HistoryManager(
        dbPool: AppDatabase.shared.dbPool,
        libraryManager: .shared
    )

    @Published public private(set) var history: [HistoryEntry] = []

    private let dbPool: DatabasePool
    private let libraryManager: LibraryManager
    private var observationCancellable: DatabaseCancellable?
    private var settingsStore: AppSettingsStore?

    public init(dbPool: DatabasePool, libraryManager: LibraryManager) {
        self.dbPool = dbPool
        self.libraryManager = libraryManager
        startObservation()
    }

    func configure(settingsStore: AppSettingsStore) {
        self.settingsStore = settingsStore
    }

    public func reload() async throws {
        let records = try await dbPool.read { db in
            try ReadingHistoryRecord
                .order(ReadingHistoryRecord.Columns.readAt.desc)
                .limit(200)
                .fetchAll(db)
        }
        history = records.map { HistoryEntry(record: $0) }
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
                AppLogger.general.error("[HistoryManager] Observation error: \(error)")
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
        guard settingsStore?.incognitoMode == false else { return }

        let libraryItemId = libraryManager.isSaved(id: manga.key) ? manga.key : nil

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
        guard settingsStore?.incognitoMode == false else { return }

        let libraryItemId = libraryManager.isSaved(id: novel.key) ? novel.key : nil

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
        guard settingsStore?.incognitoMode == false else { return }

        let libraryItemId = libraryManager.isSaved(id: anime.key) ? anime.key : nil

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
                AppLogger.general.error("[HistoryManager] Failed to insert: \(error)")
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
                AppLogger.general.error("[HistoryManager] Failed to remove entry: \(error)")
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
                AppLogger.general.error("[HistoryManager] Failed to clear history: \(error)")
            }
        }
    }

}

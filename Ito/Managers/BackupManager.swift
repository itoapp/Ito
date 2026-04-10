import Foundation
import Combine
import GRDB
import SystemConfiguration

public enum BackupRestoreMode: Sendable, Equatable {
    case wipe
    case merge
}

@MainActor
public class BackupManager: ObservableObject {
    public static let shared = BackupManager()

    @Published public private(set) var isExporting: Bool = false
    @Published public private(set) var isRestoring: Bool = false
    @Published public private(set) var lastMigrationReport: MigrationReport?

    private let registeredImporters: [BackupImporter] = [
        AidokuImporter(),
        PaperbackImporter(),
        ItoNativeImporter()
    ]

    private init() {}

    private func parseBackup(url: URL) async throws -> ImportedBackup {
        let isAccessing = url.startAccessingSecurityScopedResource()
        defer { if isAccessing { url.stopAccessingSecurityScopedResource() } }

        for importer in registeredImporters {
            if importer.canHandle(url: url) {
                return try await importer.parse(url: url)
            }
        }
        throw URLError(.cannotDecodeRawData)
    }

    /// Exports the current AppDatabase to a temporary .itobackup file and returns its URL.
    public func createBackupFile() async throws -> URL {
        isExporting = true
        defer { isExporting = false }

        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory
        let backupFileName = "Ito_Backup_\(Int(Date().timeIntervalSince1970)).itobackup"
        let backupFileURL = tempDir.appendingPathComponent(backupFileName)

        if fileManager.fileExists(atPath: backupFileURL.path) {
            try fileManager.removeItem(at: backupFileURL)
        }

        // GRDB native backup
        let dbPool = AppDatabase.shared.dbPool
        try await Task.detached {
            let backupDbPool = try DatabasePool(path: backupFileURL.path)
            try dbPool.backup(to: backupDbPool)
        }.value

        return backupFileURL
    }

    public func analyzeMerge(from url: URL) async throws -> [MergeConflict] {
        let importedBackup = try await parseBackup(url: url)
        let currentPool = AppDatabase.shared.dbPool

        return try await currentPool.read { currentDb in
            var conflicts: [MergeConflict] = []

            let localCategories = try LibraryCategory.fetchAll(currentDb)
            let localLinks = try ItemCategoryLink.fetchAll(currentDb)
            let localItems = try LibraryItem.fetchAll(currentDb)

            let localHistory = try ReadingHistoryRecord.fetchAll(currentDb)

            for backupItem in importedBackup.items {
                guard let localItem = localItems.first(where: { $0.id == backupItem.id }) else { continue }

                let localLink = localLinks.first(where: { $0.itemId == localItem.id })
                let backupLink = importedBackup.links.first(where: { $0.itemId == backupItem.id })

                let localCategory = localCategories.first(where: { $0.id == localLink?.categoryId })?.name
                let backupCategory = importedBackup.categories.first(where: { $0.id == backupLink?.categoryId })?.name

                let localHistCount = localHistory.filter({ $0.mediaKey == localItem.id }).count
                let backupHistCount = importedBackup.history.filter({ $0.mediaKey == backupItem.id }).count

                if localCategory != backupCategory || localHistCount != backupHistCount {
                    conflicts.append(MergeConflict(
                        item: localItem,
                        localCategoryName: localCategory,
                        backupCategoryName: backupCategory,
                        localHistoryCount: localHistCount,
                        backupHistoryCount: backupHistCount
                    ))
                }
            }

            return conflicts
        }
    }

    public func restoreBackup(from url: URL, mode: BackupRestoreMode, resolvedConflicts: [String: ConflictResolution] = [:]) async throws -> MigrationReport? {
        isRestoring = true
        defer { isRestoring = false }

        let importedBackup = try await parseBackup(url: url)
        let currentPool = AppDatabase.shared.dbPool

        try await currentPool.write { currentDb in
            // Discover our system category identity mapping
            let currentSystemCat = try LibraryCategory.filter(Column("isSystemCategory") == true).fetchOne(currentDb)
            let currentSystemId = currentSystemCat?.id

            // 1. If mode is WIPE, clear existing tables
            if case .wipe = mode {
                try ReadingHistoryRecord.deleteAll(currentDb)
                try ItemCategoryLink.deleteAll(currentDb)
                try LibraryItem.deleteAll(currentDb)
                try LibraryCategory.filter(Column("isSystemCategory") == false).deleteAll(currentDb)
            }

            // Identify the backup's system category ID for mapping later
            let backupSystemCatId = importedBackup.categories.first(where: { $0.isSystemCategory })?.id

            // 3. Insert or Update Categories
            for category in importedBackup.categories {
                // Prevent inserting duplicate system categories
                if category.isSystemCategory { continue }

                if case .merge = mode {
                    if try LibraryCategory.fetchOne(currentDb, key: category.id) == nil {
                        try category.insert(currentDb)
                    }
                } else {
                    try category.save(currentDb)
                }
            }

            // 4. Insert or Update Library Items
            for item in importedBackup.items {
                if case .merge = mode {
                    let resolution = resolvedConflicts[item.id] ?? .keepLocal
                    if try LibraryItem.fetchOne(currentDb, key: item.id) == nil {
                        try item.insert(currentDb)
                    } else if case .keepBackup = resolution {
                        try item.update(currentDb)
                    }
                } else {
                    try item.save(currentDb)
                }
            }

            // 5. Insert Links (With strict consistency checks)
            for var link in importedBackup.links {
                // Automatically remap the system category if it points to the old UUID!
                if link.categoryId == backupSystemCatId, let activeSystemId = currentSystemId {
                    link = ItemCategoryLink(itemId: link.itemId, categoryId: activeSystemId, addedAt: link.addedAt)
                }

                // Make sure both sides exist before inserting the strict FK
                if try LibraryItem.fetchOne(currentDb, key: link.itemId) != nil,
                   try LibraryCategory.fetchOne(currentDb, key: link.categoryId) != nil {

                    if case .merge = mode {
                        let resolution = resolvedConflicts[link.itemId] ?? .keepLocal
                        let linkExists = try ItemCategoryLink.fetchOne(currentDb, key: ["itemId": link.itemId, "categoryId": link.categoryId]) != nil

                        if !linkExists {
                            if try ItemCategoryLink.filter(Column("itemId") == link.itemId).fetchCount(currentDb) == 0 {
                                try link.insert(currentDb)
                            } else if case .keepBackup = resolution {
                                try ItemCategoryLink.filter(Column("itemId") == link.itemId).deleteAll(currentDb)
                                try link.insert(currentDb)
                            }
                        }
                    } else {
                        try link.save(currentDb)
                    }
                }
            }

            // 6. Insert History
            for entry in importedBackup.history {
                if case .merge = mode {
                    let resolution = resolvedConflicts[entry.mediaKey] ?? .keepLocal
                    if try ReadingHistoryRecord.fetchOne(currentDb, key: entry.id) == nil {
                        if case .keepBackup = resolution {
                            try entry.insert(currentDb)
                        }
                    }
                } else {
                    try entry.save(currentDb)
                }
            }

            // 7. Insert AppPreferences
            if case .wipe = mode {
                try AppPreference.deleteAll(currentDb)
            }
            for pref in importedBackup.preferences {
                try pref.save(currentDb)
            }
        }

        // Surface migration report
        let report = importedBackup.migrationReport
        self.lastMigrationReport = report
        return report
    }
}

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

    private init() {}

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

    /// Restores a backup from the given URL. 
    public func restoreBackup(from url: URL, mode: BackupRestoreMode) async throws {
        isRestoring = true
        defer { isRestoring = false }

        // Start accessing the security-scoped resource if it's from a file importer
        let isAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if isAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let currentPool = AppDatabase.shared.dbPool
        let backupPool = try DatabasePool(path: url.path)

        try await currentPool.write { currentDb in
            try backupPool.read { backupDb in

                // Discover our system category identity mapping
                let currentSystemCat = try LibraryCategory.filter(Column("isSystemCategory") == true).fetchOne(currentDb)
                let currentSystemId = currentSystemCat?.id

                // 1. If mode is WIPE, clear existing tables (safely without breaking schema)
                if case .wipe = mode {
                    // This creates a rigid transaction that rolls back if anything fails
                    try ReadingHistoryRecord.deleteAll(currentDb)
                    try ItemCategoryLink.deleteAll(currentDb)
                    try LibraryItem.deleteAll(currentDb)
                    try LibraryCategory.filter(Column("isSystemCategory") == false).deleteAll(currentDb)
                }

                // 2. Fetch all backup data safely (checking schema for backwards compatibility)
                let backupCategories = try LibraryCategory.fetchAll(backupDb)
                let backupItems = try LibraryItem.fetchAll(backupDb)
                let backupLinks = try ItemCategoryLink.fetchAll(backupDb)

                let backupHistory: [ReadingHistoryRecord]
                if try backupDb.tableExists("readingHistory") {
                    backupHistory = try ReadingHistoryRecord.fetchAll(backupDb)
                } else {
                    backupHistory = []
                }

                // Identify the backup's system category ID for mapping later
                let backupSystemCatId = backupCategories.first(where: { $0.isSystemCategory })?.id

                // 3. Insert or Update Categories
                for category in backupCategories {
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
                for item in backupItems {
                    if case .merge = mode {
                        if try LibraryItem.fetchOne(currentDb, key: item.id) == nil {
                            try item.insert(currentDb)
                        }
                    } else {
                        try item.save(currentDb)
                    }
                }

                // 5. Insert Links (With strict consistency checks)
                for var link in backupLinks {
                    // Automatically remap the system category if it points to the old UUID!
                    if link.categoryId == backupSystemCatId, let activeSystemId = currentSystemId {
                        link = ItemCategoryLink(itemId: link.itemId, categoryId: activeSystemId, addedAt: link.addedAt)
                    }

                    if try LibraryItem.fetchOne(currentDb, key: link.itemId) != nil,
                       try LibraryCategory.fetchOne(currentDb, key: link.categoryId) != nil {

                        // Fail constraints implicitly to let SQLite trigger the transaction rollback!
                        if case .merge = mode {
                            if try ItemCategoryLink.fetchOne(currentDb, key: ["itemId": link.itemId, "categoryId": link.categoryId]) == nil {
                                try link.insert(currentDb)
                            }
                        } else {
                            try link.save(currentDb)
                        }
                    }
                }

                // 6. Insert History
                for entry in backupHistory {
                    if case .merge = mode {
                        // Avoid duplicates if we merge
                        if try ReadingHistoryRecord.fetchOne(currentDb, key: entry.id) == nil {
                            try entry.insert(currentDb)
                        }
                    } else {
                        try entry.save(currentDb)
                    }
                }
            }
        }
    }
}

import Foundation
import GRDB
import Combine

/// A singleton that manages the SQLite database pool and migrations.
public final class AppDatabase: Sendable {
    public static let shared: AppDatabase = {
        do {
            return try AppDatabase()
        } catch {
            fatalError("Failed to initialize database: \(error)")
        }
    }()

    public let dbPool: DatabasePool

    private init() throws {
        let fileManager = FileManager.default
        let appSupportURL = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directoryURL = appSupportURL.appendingPathComponent("Database", isDirectory: true)

        if !fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }

        let databaseURL = directoryURL.appendingPathComponent("ItoLibrary.sqlite")

        var configuration = Configuration()
        #if DEBUG
        configuration.prepareDatabase { db in
            db.trace { print($0) }
        }
        #endif

        dbPool = try DatabasePool(path: databaseURL.path, configuration: configuration)

        try migrator.migrate(dbPool)
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "libraryCategory") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("sortOrder", .integer).notNull()
                t.column("isSystemCategory", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "libraryItem") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("coverUrl", .text)
                t.column("pluginId", .text).notNull()
                t.column("isAnime", .boolean).notNull()
                t.column("pluginType", .text)
                t.column("rawPayload", .blob).notNull()
                t.column("anilistId", .integer)
            }

            try db.create(table: "itemCategoryLink") { t in
                t.column("itemId", .text).notNull().references("libraryItem", onDelete: .cascade)
                t.column("categoryId", .text).notNull().references("libraryCategory", onDelete: .cascade)
                t.column("addedAt", .datetime).notNull()
                t.primaryKey(["itemId", "categoryId"])
            }

            try db.create(index: "idx_link_categoryId", on: "itemCategoryLink", columns: ["categoryId"])
        }

        // MARK: - v2: Smart Updates + Reading History
        migrator.registerMigration("v2") { db in
            // Add update tracking columns to libraryItem
            try db.alter(table: "libraryItem") { t in
                t.add(column: "status", .text)
                t.add(column: "lastCheckedAt", .datetime)
                t.add(column: "lastUpdatedAt", .datetime)
                t.add(column: "knownChapterCount", .integer)
            }

            // Create reading history table (no FK — history works for unsaved series)
            try db.create(table: "readingHistory") { t in
                t.primaryKey("id", .text)
                t.column("libraryItemId", .text) // nullable, no FK
                t.column("mediaKey", .text).notNull()
                t.column("title", .text).notNull()
                t.column("coverUrl", .text)
                t.column("pluginId", .text).notNull()
                t.column("chapterKey", .text).notNull()
                t.column("chapterTitle", .text)
                t.column("readAt", .datetime).notNull()
            }

            try db.create(index: "idx_history_mediaKey_readAt", on: "readingHistory", columns: ["mediaKey", "readAt"])
        }

        // MARK: - v3: Theme Cache
        migrator.registerMigration("v3") { db in
            try db.create(table: "themeCache") { t in
                t.primaryKey("mediaKey", .text)
                t.column("dominantHex", .text).notNull()
                t.column("secondaryHex", .text).notNull()
            }
        }

        // MARK: - v4: App Preferences Key-Value Store
        migrator.registerMigration("v4") { db in
            try db.create(table: "appPreference") { t in
                t.primaryKey("key", .text)
                t.column("value", .blob).notNull()
            }
        }

        return migrator
    }
}

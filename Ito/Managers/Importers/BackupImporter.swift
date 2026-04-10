import Foundation

// MARK: - Migration Report

public struct MigrationReport: Sendable {
    public struct UnresolvedPlugin: Sendable, Identifiable {
        public var id: String { foreignId }
        public let foreignId: String
        public let resolvedId: String
        public let confidence: Int
        public let isInstalled: Bool
        public let affectedItemCount: Int
        public let candidates: [(id: String, score: Int)]
    }

    public let unresolvedPlugins: [UnresolvedPlugin]
    public let totalItemsImported: Int
    public let totalItemsSkipped: Int

    public var hasIssues: Bool { !unresolvedPlugins.isEmpty }
}

// MARK: - Imported Backup

public struct ImportedBackup: Sendable {
    public let categories: [LibraryCategory]
    public let items: [LibraryItem]
    public let links: [ItemCategoryLink]
    public let history: [ReadingHistoryRecord]
    public let preferences: [AppPreference]
    public let migrationReport: MigrationReport?

    nonisolated public init(
        categories: [LibraryCategory] = [],
        items: [LibraryItem] = [],
        links: [ItemCategoryLink] = [],
        history: [ReadingHistoryRecord] = [],
        preferences: [AppPreference] = [],
        migrationReport: MigrationReport? = nil
    ) {
        self.categories = categories
        self.items = items
        self.links = links
        self.history = history
        self.preferences = preferences
        self.migrationReport = migrationReport
    }
}

// MARK: - BackupImporter Protocol

public protocol BackupImporter: Sendable {
    /// Tests if this importer can handle this specific file extension or magic bytes
    func canHandle(url: URL) -> Bool

    /// Parses the file and standardizes it into the Ito format
    func parse(url: URL) async throws -> ImportedBackup
}

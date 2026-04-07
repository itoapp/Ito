import Foundation

public enum ConflictResolution: Sendable, Equatable {
    case keepLocal
    case keepBackup
}

public struct MergeConflict: Identifiable, Sendable, Equatable {
    public var id: String { item.id }

    public let item: LibraryItem

    public let localCategoryName: String?
    public let backupCategoryName: String?

    public let localHistoryCount: Int
    public let backupHistoryCount: Int

    public var resolution: ConflictResolution

    nonisolated public init(
        item: LibraryItem,
        localCategoryName: String?,
        backupCategoryName: String?,
        localHistoryCount: Int,
        backupHistoryCount: Int,
        resolution: ConflictResolution = .keepLocal
    ) {
        self.item = item
        self.localCategoryName = localCategoryName
        self.backupCategoryName = backupCategoryName
        self.localHistoryCount = localHistoryCount
        self.backupHistoryCount = backupHistoryCount
        self.resolution = resolution
    }
}

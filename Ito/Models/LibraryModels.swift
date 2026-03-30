import Combine
import Foundation
import GRDB
import SwiftUI
import ito_runner

// MARK: - PRE-FLIGHT: Preferences

public enum LibraryLayoutStyle: Int {
    case tabbed = 0
    case sectioned = 1
}

public enum UserDefaultsKeys {
    public static let legacyLibraryItems = "ito_library_items"
    public static let backupLibraryItems = "ito_library_items_backup"
    public static let layoutStyle = "ito_library_layout_style"
    public static let alwaysShowCategoryPicker = "ito_always_show_category_picker"

    // Update & Notification Settings
    public static let bgUpdatesEnabled = "ito_bg_updates_enabled"
    public static let updateInterval = "ito_update_interval"
    public static let skipCompleted = "ito_skip_completed"
    public static let updateNotifications = "ito_update_notifications"
    public static let wifiOnlyUpdates = "ito_wifi_only_updates"
}

// MARK: - PHASE 1: Models

public struct LibraryCategory: Codable, Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public var id: String
    public var name: String
    public var sortOrder: Int
    public var isSystemCategory: Bool
    public var createdAt: Date

    public init(id: String = UUID().uuidString, name: String, sortOrder: Int, isSystemCategory: Bool = false, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.isSystemCategory = isSystemCategory
        self.createdAt = createdAt
    }

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let name = Column(CodingKeys.name)
        public static let sortOrder = Column(CodingKeys.sortOrder)
        public static let isSystemCategory = Column(CodingKeys.isSystemCategory)
        public static let createdAt = Column(CodingKeys.createdAt)
    }
}

// Ensure decoding from legacy JSON still works seamlessly while bridging to SQLite
public struct LibraryItem: Codable, Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public let id: String
    public let title: String
    public let coverUrl: String?
    public let pluginId: String
    public let isAnime: Bool
    public var pluginType: PluginType?

    // We store the raw payload so we can easily instantiate an Anime/Manga/Novel object when the user clicks it.
    public let rawPayload: Data

    // AniList Tracker Mapping
    public var anilistId: Int?

    // v2: Smart Update Tracking
    public var status: String?
    public var lastCheckedAt: Date?
    public var lastUpdatedAt: Date?
    public var knownChapterCount: Int?

    public var effectiveType: PluginType {
        if let pt = pluginType { return pt }
        return isAnime ? .anime : .manga
    }

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let title = Column(CodingKeys.title)
        public static let coverUrl = Column(CodingKeys.coverUrl)
        public static let pluginId = Column(CodingKeys.pluginId)
        public static let isAnime = Column(CodingKeys.isAnime)
        public static let pluginType = Column(CodingKeys.pluginType)
        public static let rawPayload = Column(CodingKeys.rawPayload)
        public static let anilistId = Column(CodingKeys.anilistId)
        public static let status = Column(CodingKeys.status)
        public static let lastCheckedAt = Column(CodingKeys.lastCheckedAt)
        public static let lastUpdatedAt = Column(CodingKeys.lastUpdatedAt)
        public static let knownChapterCount = Column(CodingKeys.knownChapterCount)
    }

    public static func == (lhs: LibraryItem, rhs: LibraryItem) -> Bool {
        return lhs.id == rhs.id && lhs.anilistId == rhs.anilistId
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(anilistId)
    }
}

public struct ItemCategoryLink: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public let itemId: String
    public let categoryId: String
    public let addedAt: Date

    public init(itemId: String, categoryId: String, addedAt: Date = Date()) {
        self.itemId = itemId
        self.categoryId = categoryId
        self.addedAt = addedAt
    }

    public enum Columns {
        public static let itemId = Column(CodingKeys.itemId)
        public static let categoryId = Column(CodingKeys.categoryId)
        public static let addedAt = Column(CodingKeys.addedAt)
    }
}

// MARK: - Reading History Record

public struct ReadingHistoryRecord: Codable, Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "readingHistory"

    public var id: String
    public var libraryItemId: String?
    public var mediaKey: String
    public var title: String
    public var coverUrl: String?
    public var pluginId: String
    public var chapterKey: String
    public var chapterTitle: String?
    public var readAt: Date

    public init(
        id: String = UUID().uuidString,
        libraryItemId: String? = nil,
        mediaKey: String,
        title: String,
        coverUrl: String?,
        pluginId: String,
        chapterKey: String,
        chapterTitle: String?,
        readAt: Date = Date()
    ) {
        self.id = id
        self.libraryItemId = libraryItemId
        self.mediaKey = mediaKey
        self.title = title
        self.coverUrl = coverUrl
        self.pluginId = pluginId
        self.chapterKey = chapterKey
        self.chapterTitle = chapterTitle
        self.readAt = readAt
    }

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let libraryItemId = Column(CodingKeys.libraryItemId)
        public static let mediaKey = Column(CodingKeys.mediaKey)
        public static let title = Column(CodingKeys.title)
        public static let coverUrl = Column(CodingKeys.coverUrl)
        public static let pluginId = Column(CodingKeys.pluginId)
        public static let chapterKey = Column(CodingKeys.chapterKey)
        public static let chapterTitle = Column(CodingKeys.chapterTitle)
        public static let readAt = Column(CodingKeys.readAt)
    }
}

// MARK: - Associations
extension LibraryItem {
    static let itemCategoryLinks = hasMany(ItemCategoryLink.self)
    static let categories = hasMany(LibraryCategory.self, through: itemCategoryLinks, using: ItemCategoryLink.category)
}

extension LibraryCategory {
    static let itemCategoryLinks = hasMany(ItemCategoryLink.self)
    static let items = hasMany(LibraryItem.self, through: itemCategoryLinks, using: ItemCategoryLink.item)
}

extension ItemCategoryLink {
    static let item = belongsTo(LibraryItem.self)
    static let category = belongsTo(LibraryCategory.self)
}

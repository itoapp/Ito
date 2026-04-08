import Foundation
import GRDB

public struct AppPreference: Codable, Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "appPreference"

    public var id: String { key }
    public var key: String
    public var value: Data

    public init(key: String, value: Data) {
        self.key = key
        self.value = value
    }

    public enum Columns {
        public static let key = Column("key")
        public static let value = Column("value")
    }
}

import GRDB
import XCTest
import ito_runner
@testable import Ito

@MainActor
final class MediaDetailLibraryBoundaryTests: XCTestCase {
    func testDurableSaveCommitsBeforeReturningSuccessAndPublishesSnapshot() async throws {
        let database = try TestDatabase()
        let manager = LibraryManager(dbPool: database.dbPool)
        let media = Manga(key: "m1", title: "Manga")

        let durableItemID = try await manager.saveMangaDurably(
            manga: media,
            pluginId: "plugin.test"
        )

        XCTAssertEqual(durableItemID, "m1")
        let stored = try await database.dbPool.read { db in
            try LibraryItem.fetchOne(db, key: "m1")
        }
        XCTAssertEqual(stored?.pluginId, "plugin.test")
        XCTAssertTrue(manager.items.contains { $0.id == "m1" && $0.pluginId == "plugin.test" })
        XCTAssertTrue(
            manager.state.isSaved(
                media: MediaIdentity(pluginId: "plugin.test", itemId: "m1"),
                sourceItemID: "m1"
            )
        )
    }

    func testDurableSaveFailureDoesNotPublishFalseSuccess() async throws {
        let database = try TestDatabase()
        let manager = LibraryManager(dbPool: database.dbPool)
        try await database.dbPool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_media_detail_save
                BEFORE INSERT ON libraryItem
                BEGIN
                    SELECT RAISE(ABORT, 'forced save failure');
                END
                """)
        }

        do {
            try await manager.saveAnimeDurably(
                anime: Anime(key: "a1", title: "Anime"),
                pluginId: "plugin.test"
            )
            XCTFail("Expected durable save failure")
        } catch {}

        let count = try await database.dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM libraryItem") ?? 0
        }
        XCTAssertEqual(count, 0)
        XCTAssertFalse(manager.items.contains { $0.id == "a1" })
        XCTAssertFalse(
            manager.state.isSaved(
                media: MediaIdentity(pluginId: "plugin.test", itemId: "a1"),
                sourceItemID: "a1"
            )
        )
    }

    func testDurableSaveUsesCompatiblePrefixedIdentityWhenAnotherPluginOwnsRawKey() async throws {
        let database = try TestDatabase()
        let manager = LibraryManager(dbPool: database.dbPool)
        _ = try await manager.saveMangaDurably(
            manga: Manga(key: "shared", title: "First"),
            pluginId: "plugin.first"
        )

        let durableItemID = try await manager.saveMangaDurably(
            manga: Manga(key: "shared", title: "Second"),
            pluginId: "plugin.second"
        )

        XCTAssertEqual(durableItemID, "plugin.second_shared")
        let stored = try await database.dbPool.read { db in
            try LibraryItem.order(Column("id")).fetchAll(db)
        }
        XCTAssertEqual(stored.map(\.id), ["plugin.second_shared", "shared"])
        XCTAssertTrue(
            manager.state.isSaved(
                media: MediaIdentity(pluginId: "plugin.second", itemId: "shared"),
                sourceItemID: "shared"
            )
        )
    }

    func testDurableUnsaveCommitsBeforeReturningAndPublishesSnapshot() async throws {
        let database = try TestDatabase()
        let manager = LibraryManager(dbPool: database.dbPool)
        try await manager.saveNovelDurably(
            novel: Novel(key: "n1", title: "Novel"),
            pluginId: "plugin.test"
        )

        try await manager.removeItemDurably(id: "n1", pluginId: "plugin.test")

        let stored = try await database.dbPool.read { db in
            try LibraryItem.fetchOne(db, key: "n1")
        }
        XCTAssertNil(stored)
        XCTAssertFalse(manager.items.contains { $0.id == "n1" })
    }

    func testDurableUnsaveFailurePreservesDatabaseAndPublishedState() async throws {
        let database = try TestDatabase()
        let manager = LibraryManager(dbPool: database.dbPool)
        try await manager.saveMangaDurably(
            manga: Manga(key: "m1", title: "Manga"),
            pluginId: "plugin.test"
        )
        try await database.dbPool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_media_detail_unsave
                BEFORE DELETE ON libraryItem
                BEGIN
                    SELECT RAISE(ABORT, 'forced unsave failure');
                END
                """)
        }

        do {
            try await manager.removeItemDurably(id: "m1", pluginId: "plugin.test")
            XCTFail("Expected durable unsave failure")
        } catch {}

        let stored = try await database.dbPool.read { db in
            try LibraryItem.fetchOne(db, key: "m1")
        }
        XCTAssertEqual(stored?.pluginId, "plugin.test")
        XCTAssertTrue(manager.items.contains { $0.id == "m1" })
    }
}

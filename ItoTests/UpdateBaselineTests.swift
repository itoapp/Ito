import Foundation
import GRDB
import Testing
import ito_runner
@testable import Ito

@MainActor
struct UpdateBaselineTests {
    @Test func existingBaselineAdvancesAndRepeatedCountClearsBadge() async throws {
        let (database, manager, item) = try await makeSubject(knownCount: 10)
        defer { database.cleanup() }
        let checkedAt = Date(timeIntervalSince1970: 1_700_000_100)

        let firstDelta = await successfulUpdate(
            manager,
            item: item,
            freshCount: 12,
            checkedAt: checkedAt
        )
        #expect(firstDelta == 2)
        #expect(manager.newChapterCounts[item.id] == 2)
        let firstPersisted = try await persistedItem(database, id: item.id)
        #expect(firstPersisted.knownChapterCount == 12)
        #expect(firstPersisted.status == "updated")
        #expect(firstPersisted.lastCheckedAt == checkedAt)
        #expect(firstPersisted.lastUpdatedAt == checkedAt)

        let secondDelta = await successfulUpdate(manager, item: item, freshCount: 12)
        #expect(secondDelta == 0)
        #expect(manager.newChapterCounts[item.id] == nil)
        #expect(try await persistedItem(database, id: item.id).knownChapterCount == 12)
    }

    @Test func latestPersistedBaselineWinsOverStaleInput() async throws {
        let (database, manager, staleItem) = try await makeSubject(knownCount: 10)
        defer { database.cleanup() }
        try await database.dbPool.write { db in
            let fetchedLatest = try LibraryItem.fetchOne(db, key: staleItem.id)
            var latest = try #require(fetchedLatest)
            latest.knownChapterCount = 11
            try latest.update(db)
        }

        let delta = await successfulUpdate(manager, item: staleItem, freshCount: 12)

        #expect(delta == 1)
        #expect(manager.newChapterCounts[staleItem.id] == 1)
        #expect(try await persistedItem(database, id: staleItem.id).knownChapterCount == 12)
    }

    @Test func nilBaselineInitializesSilently() async throws {
        let (database, manager, item) = try await makeSubject(knownCount: nil)
        defer { database.cleanup() }

        let delta = await successfulUpdate(manager, item: item, freshCount: 12)

        #expect(delta == 0)
        #expect(manager.newChapterCounts[item.id] == nil)
        #expect(try await persistedItem(database, id: item.id).knownChapterCount == 12)
    }

    @Test func lowerCountBecomesBaselineForNextIncrease() async throws {
        let (database, manager, item) = try await makeSubject(knownCount: 12)
        defer { database.cleanup() }

        let decreaseDelta = await successfulUpdate(manager, item: item, freshCount: 10)
        #expect(decreaseDelta == 0)
        #expect(try await persistedItem(database, id: item.id).knownChapterCount == 10)

        let increaseDelta = await successfulUpdate(manager, item: item, freshCount: 11)
        #expect(increaseDelta == 1)
        #expect(manager.newChapterCounts[item.id] == 1)
        #expect(try await persistedItem(database, id: item.id).knownChapterCount == 11)
    }

    @Test func failedFetchDoesNotMutatePersistedUpdateStateOrBadge() async throws {
        let checkedAt = Date(timeIntervalSince1970: 1_700_000_001)
        let updatedAt = Date(timeIntervalSince1970: 1_700_000_002)
        let (database, manager, item) = try await makeSubject(
            knownCount: 10,
            status: "ongoing",
            lastCheckedAt: checkedAt,
            lastUpdatedAt: updatedAt
        )
        defer { database.cleanup() }

        let delta = await manager.processUpdate(for: item) {
            throw StubError.fetchFailed
        }

        #expect(delta == nil)
        #expect(manager.newChapterCounts[item.id] == nil)
        let persisted = try await persistedItem(database, id: item.id)
        #expect(persisted.knownChapterCount == 10)
        #expect(persisted.status == "ongoing")
        #expect(persisted.lastCheckedAt == checkedAt)
        #expect(persisted.lastUpdatedAt == updatedAt)
    }

    @Test func itemDeletedDuringFetchIsNotRecreatedAndHasNoBadge() async throws {
        let (database, manager, item) = try await makeSubject(knownCount: 10)
        defer { database.cleanup() }
        #expect(await successfulUpdate(manager, item: item, freshCount: 12) == 2)
        #expect(manager.newChapterCounts[item.id] == 2)
        try await database.dbPool.write { db in
            _ = try LibraryItem.deleteOne(db, key: item.id)
        }

        let delta = await successfulUpdate(manager, item: item, freshCount: 13)

        #expect(delta == nil)
        #expect(manager.newChapterCounts[item.id] == nil)
        let deleted = try await database.dbPool.read { db in
            try LibraryItem.fetchOne(db, key: item.id)
        }
        #expect(deleted == nil)
    }

    private func makeSubject(
        knownCount: Int?,
        status: String? = nil,
        lastCheckedAt: Date? = nil,
        lastUpdatedAt: Date? = nil
    ) async throws -> (TestDatabase, UpdateManager, LibraryItem) {
        let database = try TestDatabase()
        let item = LibraryItem(
            id: "update-item",
            title: "Update Item",
            coverUrl: nil,
            pluginId: "test.plugin",
            isAnime: false,
            pluginType: .manga,
            rawPayload: Data(),
            anilistId: nil,
            status: status,
            lastCheckedAt: lastCheckedAt,
            lastUpdatedAt: lastUpdatedAt,
            knownChapterCount: knownCount
        )
        try await database.dbPool.write { db in
            try item.insert(db)
        }
        return (
            database,
            UpdateManager(dbPool: database.dbPool, loadsPersistedState: false),
            item
        )
    }

    private func successfulUpdate(
        _ manager: UpdateManager,
        item: LibraryItem,
        freshCount: Int,
        status: String? = "updated",
        checkedAt: Date = Date()
    ) async -> Int? {
        await manager.processUpdate(for: item, checkedAt: checkedAt) {
            UpdateManager.SuccessfulUpdate(freshCount: freshCount, status: status)
        }
    }

    private func persistedItem(_ database: TestDatabase, id: String) async throws -> LibraryItem {
        try await database.dbPool.read { db in
            let fetchedItem = try LibraryItem.fetchOne(db, key: id)
            return try #require(fetchedItem)
        }
    }
}

private enum StubError: Error {
    case fetchFailed
}

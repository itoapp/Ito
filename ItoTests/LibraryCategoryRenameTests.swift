import Combine
import Foundation
import GRDB
import XCTest
@testable import Ito

@MainActor
final class LibraryCategoryRenameTests: XCTestCase {
    func testSuccessfulRenamePersistsExactlyOnce() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let category = try await seedCategory(in: database)
        try await database.dbPool.write { db in
            try db.execute(sql: "CREATE TABLE categoryRenameAudit (name TEXT NOT NULL)")
            try db.execute(sql: """
                CREATE TRIGGER audit_category_rename
                AFTER UPDATE OF name ON libraryCategory
                BEGIN
                    INSERT INTO categoryRenameAudit (name) VALUES (NEW.name);
                END
                """)
        }
        let manager = LibraryManager(dbPool: database.dbPool)
        try await waitForCategory(id: category.id, name: category.name, in: manager)

        try await manager.renameCategory(id: category.id, to: "Renamed")
        try await waitForCategory(id: category.id, name: "Renamed", in: manager)

        let persisted = try await database.dbPool.read { db in
            (
                try LibraryCategory.fetchOne(db, key: category.id)?.name,
                try String.fetchAll(db, sql: "SELECT name FROM categoryRenameAudit")
            )
        }
        XCTAssertEqual(persisted.0, "Renamed")
        XCTAssertEqual(persisted.1, ["Renamed"])
    }

    func testSuccessfulRenamePublishesOnlyAfterCommit() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let category = try await seedCategory(in: database)
        let manager = LibraryManager(dbPool: database.dbPool)
        try await waitForCategory(id: category.id, name: category.name, in: manager)
        let gate = DatabaseWriteGate()
        defer { gate.release() }
        try await database.dbPool.writeWithoutTransaction { db in
            db.add(function: DatabaseFunction(
                "wait_for_category_rename_commit",
                argumentCount: 0,
                pure: false
            ) { _ in
                gate.blockWriter()
                return nil
            })
            try db.execute(sql: """
                CREATE TRIGGER wait_before_category_rename_commit
                AFTER UPDATE OF name ON libraryCategory
                BEGIN
                    SELECT wait_for_category_rename_commit();
                END
                """)
        }

        var publishedAttemptedName = false
        let subscription = manager.$categories.sink { categories in
            if categories.contains(where: { $0.id == category.id && $0.name == "Renamed" }) {
                publishedAttemptedName = true
            }
        }
        defer { subscription.cancel() }

        let rename = Task {
            try await manager.renameCategory(id: category.id, to: "Renamed")
        }
        let didBlockBeforeCommit = await gate.waitUntilBlocked(timeout: 2)
        XCTAssertTrue(didBlockBeforeCommit)
        XCTAssertEqual(manager.categories.first(where: { $0.id == category.id })?.name, category.name)
        XCTAssertFalse(publishedAttemptedName)

        gate.release()
        try await rename.value
        try await waitForCategory(id: category.id, name: "Renamed", in: manager)
        XCTAssertTrue(publishedAttemptedName)
    }

    func testInjectedDatabaseFailureRollsBackTransaction() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let category = try await seedCategory(in: database)
        let manager = LibraryManager(dbPool: database.dbPool)
        try await waitForCategory(id: category.id, name: category.name, in: manager)
        try await installRenameFailure(in: database)

        await XCTAssertThrowsErrorAsync {
            try await manager.renameCategory(id: category.id, to: "Attempted")
        }

        let failureProbeCount = try await database.dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM categoryRenameFailureProbe")
        }
        XCTAssertEqual(failureProbeCount, 0)
    }

    func testFailedRenamePreservesPriorName() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let category = try await seedCategory(in: database)
        let manager = LibraryManager(dbPool: database.dbPool)
        try await waitForCategory(id: category.id, name: category.name, in: manager)
        try await installRenameFailure(in: database)

        await XCTAssertThrowsErrorAsync {
            try await manager.renameCategory(id: category.id, to: "Attempted")
        }

        let persistedName = try await database.dbPool.read { db in
            try LibraryCategory.fetchOne(db, key: category.id)?.name
        }
        XCTAssertEqual(persistedName, category.name)
        XCTAssertEqual(manager.categories.first(where: { $0.id == category.id })?.name, category.name)
    }

    func testFailedRenameDoesNotPublishAttemptedValue() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let category = try await seedCategory(in: database)
        let manager = LibraryManager(dbPool: database.dbPool)
        try await waitForCategory(id: category.id, name: category.name, in: manager)
        try await installRenameFailure(in: database)
        var publishedNames: [String] = []
        let subscription = manager.$categories.sink { categories in
            if let name = categories.first(where: { $0.id == category.id })?.name {
                publishedNames.append(name)
            }
        }
        defer { subscription.cancel() }

        await XCTAssertThrowsErrorAsync {
            try await manager.renameCategory(id: category.id, to: "Attempted")
        }
        await Task.yield()

        XCTAssertFalse(publishedNames.contains("Attempted"))
        XCTAssertEqual(publishedNames.last, category.name)
    }

    func testCategoryViewsDoNotAccessDatabaseDirectly() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewURL = repositoryRoot
            .appendingPathComponent("Ito")
            .appendingPathComponent("Views")
            .appendingPathComponent("Library")
            .appendingPathComponent("CategorySettingsView.swift")
        let source = try String(contentsOf: viewURL, encoding: .utf8)

        XCTAssertFalse(source.contains("AppDatabase.shared"))
        XCTAssertFalse(source.contains("dbPool.read"))
        XCTAssertFalse(source.contains("dbPool.write"))
    }

    private func seedCategory(in database: TestDatabase) async throws -> LibraryCategory {
        let category = LibraryCategory(id: "category", name: "Original", sortOrder: 1)
        try await database.dbPool.write { db in
            try category.insert(db)
        }
        return category
    }

    private func installRenameFailure(in database: TestDatabase) async throws {
        try await database.dbPool.write { db in
            try db.execute(sql: "CREATE TABLE categoryRenameFailureProbe (name TEXT NOT NULL)")
            try db.execute(sql: """
                CREATE TRIGGER fail_category_rename
                BEFORE UPDATE OF name ON libraryCategory
                BEGIN
                    INSERT INTO categoryRenameFailureProbe (name) VALUES (NEW.name);
                    SELECT RAISE(ROLLBACK, 'injected category rename failure');
                END
                """)
        }
    }

    private func waitForCategory(
        id: String,
        name: String,
        in manager: LibraryManager
    ) async throws {
        if manager.categories.contains(where: { $0.id == id && $0.name == name }) {
            return
        }

        let published = expectation(description: "Category \(id) published as \(name)")
        var didFulfill = false
        let subscription = manager.$categories.sink { categories in
            guard !didFulfill else { return }
            if categories.contains(where: { $0.id == id && $0.name == name }) {
                didFulfill = true
                published.fulfill()
            }
        }
        defer { subscription.cancel() }
        await fulfillment(of: [published], timeout: 2)
    }
}

private final class DatabaseWriteGate: @unchecked Sendable {
    private let blocked = DispatchSemaphore(value: 0)
    private let resume = DispatchSemaphore(value: 0)

    func blockWriter() {
        blocked.signal()
        resume.wait()
    }

    func waitUntilBlocked(timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(
                    returning: self.blocked.wait(timeout: .now() + timeout) == .success
                )
            }
        }
    }

    func release() {
        resume.signal()
    }
}

@MainActor
private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error to be thrown", file: file, line: line)
    } catch {
        // Expected.
    }
}

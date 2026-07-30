import Foundation
import GRDB
import Testing
@testable import Ito

@MainActor
struct RepositoryAndAliasStoreTests {
    @Test func repositoryAndAliasRoundTripWithoutDefaults() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let index = RepoIndex(
            repoName: "Offline",
            repoUrl: "https://example.com/repo",
            description: "Cached metadata",
            packages: []
        )
        let payload = try JSONEncoder().encode(index)
        let repositories = RepoManager(dbPool: database.dbPool) { _ in payload }

        try await repositories.addRepository(url: "https://example.com/repo/index.json")
        #expect(repositories.repositories.single?.url == "https://example.com/repo")
        #expect(repositories.repositories.single?.index == index)

        let reloadedRepositories = RepoManager(dbPool: database.dbPool)
        try await reloadedRepositories.reload()
        #expect(reloadedRepositories.repositories.single?.index == index)

        let resolver = PluginResolver(
            dbPool: database.dbPool,
            repoManager: reloadedRepositories,
            installedPluginIds: { ["plugin.target"] }
        )
        try await resolver.saveUserAlias(
            foreignId: "source.foreign-v2",
            itoPluginId: "plugin.target"
        )
        let reloadedResolver = PluginResolver(
            dbPool: database.dbPool,
            repoManager: reloadedRepositories,
            installedPluginIds: { ["plugin.target"] }
        )
        try await reloadedResolver.reload()
        #expect(reloadedResolver.resolveId(foreignId: "source.foreign-v3") == "plugin.target")
    }

    @Test func repositoryFailureDoesNotPublishOrPersistPartialState() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let index = RepoIndex(
            repoName: "Fixture",
            repoUrl: "https://example.com",
            description: "",
            packages: []
        )
        let payload = try JSONEncoder().encode(index)
        let manager = RepoManager(dbPool: database.dbPool) { _ in payload }
        try await manager.addRepository(url: "https://example.com/first")
        try await database.dbPool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_repository_insert
                BEFORE INSERT ON repository
                BEGIN
                    SELECT RAISE(ABORT, 'injected repository failure');
                END
                """)
        }

        await #expect(throws: (any Error).self) {
            try await manager.addRepository(url: "https://example.com/second")
        }

        #expect(manager.repositories.map(\.url) == ["https://example.com/first"])
        try await database.dbPool.read { db in
            let records = try RepositoryRecord.fetchAll(db)
            #expect(records.map(\.url) == ["https://example.com/first"])
        }
    }

    @Test func aliasFailureKeepsPriorCommittedAliasPublished() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let repositories = RepoManager(dbPool: database.dbPool)
        let resolver = PluginResolver(
            dbPool: database.dbPool,
            repoManager: repositories,
            installedPluginIds: { ["old.plugin", "new.plugin"] }
        )
        try await resolver.saveUserAlias(foreignId: "foreign", itoPluginId: "old.plugin")
        try await database.dbPool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_alias_update
                BEFORE UPDATE ON pluginMigrationAlias
                BEGIN
                    SELECT RAISE(ABORT, 'injected alias failure');
                END
                """)
        }

        await #expect(throws: (any Error).self) {
            try await resolver.saveUserAlias(
                foreignId: "foreign",
                itoPluginId: "new.plugin"
            )
        }

        #expect(resolver.resolveId(foreignId: "foreign") == "old.plugin")
        try await database.dbPool.read { db in
            let record = try PluginMigrationAliasRecord.fetchOne(db, key: "foreign")
            #expect(record?.pluginId == "old.plugin")
        }
    }
}

private extension Collection {
    var single: Element? {
        count == 1 ? first : nil
    }
}

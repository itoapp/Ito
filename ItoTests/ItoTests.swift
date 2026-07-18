//
//  ItoTests.swift
//  ItoTests
//
//  Created by caocao on 3/3/26.
//

import Testing
import GRDB
@testable import Ito

struct ItoTests {

    @Test func productionMigratedTestDatabase() throws {
        let database = try TestDatabase()
        defer { database.cleanup() }

        let appliedMigrations = try database.dbPool.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid"
            )
        }

        #expect(appliedMigrations == ["v1", "v2", "v3", "v4"])
    }

}

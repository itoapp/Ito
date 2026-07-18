import Foundation
import GRDB
@testable import Ito

final class TestDatabase {
    let dbPool: DatabasePool
    let databaseURL: URL

    private let directoryURL: URL

    init() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("ItoTests-\(UUID().uuidString)", isDirectory: true)
        let databaseURL = directoryURL.appendingPathComponent("ItoLibrary.sqlite")

        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        do {
            let dbPool = try DatabasePool(path: databaseURL.path)
            try AppDatabase.makeMigrator().migrate(dbPool)

            self.directoryURL = directoryURL
            self.databaseURL = databaseURL
            self.dbPool = dbPool
        } catch {
            try? fileManager.removeItem(at: directoryURL)
            throw error
        }
    }

    deinit {
        cleanup()
    }

    func cleanup() {
        try? dbPool.close()
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

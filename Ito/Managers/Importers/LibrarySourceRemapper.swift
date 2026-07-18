import Foundation
import GRDB

struct LibrarySourceRemapper: Sendable {
    nonisolated struct Result: Equatable, Sendable {
        let remappedItemCount: Int
        let movedLinkCount: Int
        let movedHistoryCount: Int
    }

    nonisolated enum RemapError: Error, Equatable, LocalizedError {
        case sourceNotFound(String)
        case sourceOwnershipMismatch(itemId: String, expectedPluginId: String, actualPluginId: String)
        case noOpMapping(itemId: String)
        case destinationExists(String)
        case intraBatchDestinationCollision(destinationId: String, sourceItemIds: [String])
        case ambiguousHistoryAssociation(historyId: String, sourceItemIds: [String])

        var errorDescription: String? {
            switch self {
            case .sourceNotFound(let itemId):
                return "The imported library item \"\(itemId)\" no longer exists."
            case .sourceOwnershipMismatch(let itemId, let expected, let actual):
                return "Library item \"\(itemId)\" belongs to \"\(actual)\", not \"\(expected)\"."
            case .noOpMapping(let itemId):
                return "Remapping \"\(itemId)\" would not change its identifier."
            case .destinationExists(let itemId):
                return "A library item already exists at the destination \"\(itemId)\"."
            case .intraBatchDestinationCollision(let destinationId, _):
                return "Multiple imported items would map to \"\(destinationId)\"."
            case .ambiguousHistoryAssociation(let historyId, _):
                return "Reading history \"\(historyId)\" matches multiple imported items."
            }
        }
    }

    typealias AliasWriter = @Sendable (_ foreignId: String, _ newPluginId: String) async throws -> Void

    nonisolated private struct Mapping: Sendable {
        let source: LibraryItem
        let destinationId: String
    }

    let dbPool: DatabasePool

    func remap(
        oldPluginId: String,
        newPluginId: String,
        affectedItemIds: [String]
    ) async throws -> Result {
        try await dbPool.write { db in
            var mappings: [Mapping] = []
            mappings.reserveCapacity(affectedItemIds.count)

            for sourceId in affectedItemIds {
                guard let source = try LibraryItem.fetchOne(db, key: sourceId) else {
                    throw RemapError.sourceNotFound(sourceId)
                }
                guard source.pluginId == oldPluginId else {
                    throw RemapError.sourceOwnershipMismatch(
                        itemId: sourceId,
                        expectedPluginId: oldPluginId,
                        actualPluginId: source.pluginId
                    )
                }

                let destinationId = ImportedMediaIdentity.destinationId(
                    sourceItemId: sourceId,
                    oldPluginId: oldPluginId,
                    newPluginId: newPluginId
                )
                guard destinationId != sourceId else {
                    throw RemapError.noOpMapping(itemId: sourceId)
                }
                guard try LibraryItem.fetchOne(db, key: destinationId) == nil else {
                    throw RemapError.destinationExists(destinationId)
                }
                mappings.append(Mapping(source: source, destinationId: destinationId))
            }

            let mappingsByDestination = Dictionary(grouping: mappings, by: \.destinationId)
            if let collision = mappingsByDestination.first(where: { $0.value.count > 1 }) {
                throw RemapError.intraBatchDestinationCollision(
                    destinationId: collision.key,
                    sourceItemIds: collision.value.map(\.source.id).sorted()
                )
            }

            let oldHistory = try ReadingHistoryRecord
                .filter(ReadingHistoryRecord.Columns.pluginId == oldPluginId)
                .fetchAll(db)
            var historyMappings: [(ReadingHistoryRecord, Mapping)] = []

            for history in oldHistory {
                let matches = mappings.filter {
                    ImportedMediaIdentity.historyIdentifiers(
                        history,
                        match: $0.source.id,
                        pluginId: oldPluginId
                    )
                }
                guard matches.count <= 1 else {
                    throw RemapError.ambiguousHistoryAssociation(
                        historyId: history.id,
                        sourceItemIds: matches.map(\.source.id).sorted()
                    )
                }
                if let match = matches.first {
                    historyMappings.append((history, match))
                }
            }

            for mapping in mappings {
                let source = mapping.source
                let destination = LibraryItem(
                    id: mapping.destinationId,
                    title: source.title,
                    coverUrl: source.coverUrl,
                    pluginId: newPluginId,
                    isAnime: source.isAnime,
                    pluginType: source.pluginType,
                    rawPayload: source.rawPayload,
                    anilistId: source.anilistId,
                    status: source.status,
                    lastCheckedAt: source.lastCheckedAt,
                    lastUpdatedAt: source.lastUpdatedAt,
                    knownChapterCount: source.knownChapterCount
                )
                try destination.insert(db)
            }

            var movedLinkCount = 0
            for mapping in mappings {
                try db.execute(
                    sql: "UPDATE itemCategoryLink SET itemId = ? WHERE itemId = ?",
                    arguments: [mapping.destinationId, mapping.source.id]
                )
                movedLinkCount += db.changesCount
            }

            for (history, mapping) in historyMappings {
                try db.execute(
                    sql: """
                        UPDATE readingHistory
                        SET libraryItemId = ?, mediaKey = ?, pluginId = ?
                        WHERE id = ?
                        """,
                    arguments: [mapping.destinationId, mapping.destinationId, newPluginId, history.id]
                )
            }

            for mapping in mappings {
                try LibraryItem.deleteOne(db, key: mapping.source.id)
            }

            return Result(
                remappedItemCount: mappings.count,
                movedLinkCount: movedLinkCount,
                movedHistoryCount: historyMappings.count
            )
        }
    }

    /// The database and alias store cannot share a transaction. The database commits first;
    /// a process crash in the narrow window before this callback can leave the alias unwritten.
    func remapAndPersistAlias(
        foreignId: String,
        oldPluginId: String,
        newPluginId: String,
        affectedItemIds: [String],
        aliasWriter: AliasWriter
    ) async throws -> Result {
        let result = try await remap(
            oldPluginId: oldPluginId,
            newPluginId: newPluginId,
            affectedItemIds: affectedItemIds
        )
        try await aliasWriter(foreignId, newPluginId)
        return result
    }
}

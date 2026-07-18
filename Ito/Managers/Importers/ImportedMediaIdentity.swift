import Foundation

enum ImportedMediaIdentity {
    nonisolated struct Key: Hashable, Sendable {
        let pluginId: String
        let canonicalMediaId: String
    }

    nonisolated static func canonicalMediaId(itemId: String, pluginId: String) -> String {
        let prefix = "\(pluginId)_"
        guard itemId.hasPrefix(prefix) else { return itemId }
        return String(itemId.dropFirst(prefix.count))
    }

    nonisolated static func key(itemId: String, pluginId: String) -> Key {
        Key(
            pluginId: pluginId,
            canonicalMediaId: canonicalMediaId(itemId: itemId, pluginId: pluginId)
        )
    }

    nonisolated static func destinationId(
        sourceItemId: String,
        oldPluginId: String,
        newPluginId: String
    ) -> String {
        "\(newPluginId)_\(canonicalMediaId(itemId: sourceItemId, pluginId: oldPluginId))"
    }

    nonisolated static func historyIdentifiers(
        _ history: ReadingHistoryRecord,
        match sourceItemId: String,
        pluginId: String
    ) -> Bool {
        guard history.pluginId == pluginId else { return false }
        let sourceCanonicalId = canonicalMediaId(itemId: sourceItemId, pluginId: pluginId)
        return [history.libraryItemId, history.mediaKey].compactMap { $0 }.contains { identifier in
            canonicalMediaId(itemId: identifier, pluginId: pluginId) == sourceCanonicalId
        }
    }

    nonisolated static func uniquelyAssociatedItem(
        for history: ReadingHistoryRecord,
        among items: [LibraryItem]
    ) -> LibraryItem? {
        let matches = items.filter {
            historyIdentifiers(history, match: $0.id, pluginId: $0.pluginId)
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }
}

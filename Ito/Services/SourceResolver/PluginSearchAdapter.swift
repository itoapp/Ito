import Foundation
import ito_runner

public actor PluginSearchAdapter: PluginSearching {
    public let pluginID: String
    public let pluginVersion: String?
    public let mediaType: PluginMediaType

    private let runner: ItoRunner

    public init(pluginID: String, pluginVersion: String?, mediaType: PluginMediaType, runner: ItoRunner) {
        self.pluginID = pluginID
        self.pluginVersion = pluginVersion
        self.mediaType = mediaType
        self.runner = runner
    }

    public func search(query: String) async throws -> [ResolvedPluginMedia] {
        var results: [ResolvedPluginMedia] = []

        switch mediaType {
        case .manga:
            let res = try await runner.getSearchMangaList(query: query, page: 1, filters: nil)
            for m in res.entries {
                results.append(.manga(m))
            }
        case .anime:
            let res = try await runner.getSearchAnimeList(query: query, page: 1, filters: nil)
            for a in res.entries {
                results.append(.anime(a))
            }
        }
        return results
    }
}

import Foundation
import OSLog
import SwiftUI
import ito_runner

enum SearchPluginKind: Equatable {
    case manga
    case anime
    case novel
    case unsupported
}

struct SearchPluginDescriptor: Equatable {
    let id: String
    let name: String
    let kind: SearchPluginKind
}

@MainActor
protocol SearchPluginExecuting: AnyObject {
    var plugins: [SearchPluginDescriptor] { get }

    func search(
        plugin: SearchPluginDescriptor,
        query: String,
        limit: Int
    ) async throws -> [PluginSearchResult]

    func evictRunner(for pluginID: String)
}

@MainActor
protocol RecentSearchPersisting {
    func load() -> [String]
    func save(_ searches: [String])
    func clear()
}

struct UserDefaultsRecentSearchStore: RecentSearchPersisting {
    static let key = "Ito.RecentSearches"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [String] {
        defaults.stringArray(forKey: Self.key) ?? []
    }

    func save(_ searches: [String]) {
        defaults.set(searches, forKey: Self.key)
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}

@MainActor
final class PluginManagerSearchExecutor: SearchPluginExecuting {
    private let pluginManager: PluginManager

    init(pluginManager: PluginManager) {
        self.pluginManager = pluginManager
    }

    var plugins: [SearchPluginDescriptor] {
        pluginManager.installedPlugins.values.map { plugin in
            SearchPluginDescriptor(
                id: plugin.id,
                name: plugin.info.name,
                kind: searchKind(for: plugin)
            )
        }
    }

    func search(
        plugin: SearchPluginDescriptor,
        query: String,
        limit: Int
    ) async throws -> [PluginSearchResult] {
        AppLogger.ui.debug("🔍 [Search] Getting runner for \(plugin.name)...")
        let runner = try await pluginManager.getRunner(for: plugin.id)

        guard !Task.isCancelled else { return [] }
        AppLogger.ui.debug("🔍 [Search] Searching \(plugin.name) for '\(query)'...")

        switch plugin.kind {
        case .manga:
            let response = try await runner.getSearchMangaList(query: query, page: 1, filters: nil)
            AppLogger.ui.debug("🔍 [Search] \(plugin.name) WASM returned \(response.entries.count) raw manga entries (hasNextPage: \(response.hasNextPage))")
            guard !Task.isCancelled else { return [] }
            return response.entries.prefix(limit).map { manga in
                PluginSearchResult(
                    id: manga.key,
                    title: manga.title,
                    cover: manga.cover,
                    subtitle: manga.displayStatus,
                    pluginName: plugin.name,
                    destination: AnyView(
                        MediaDetailView(
                            runner: runner,
                            media: manga,
                            pluginId: plugin.id
                        ) { try await runner.getMangaUpdate(manga: $0) }
                    )
                )
            }
        case .anime:
            let response = try await runner.getSearchAnimeList(query: query, page: 1, filters: nil)
            AppLogger.ui.debug("🔍 [Search] \(plugin.name) WASM returned \(response.entries.count) raw anime entries (hasNextPage: \(response.hasNextPage))")
            guard !Task.isCancelled else { return [] }
            return response.entries.prefix(limit).map { anime in
                PluginSearchResult(
                    id: anime.key,
                    title: anime.title,
                    cover: anime.cover,
                    subtitle: anime.displayStatus,
                    pluginName: plugin.name,
                    destination: AnyView(
                        MediaDetailView(
                            runner: runner,
                            media: anime,
                            pluginId: plugin.id
                        ) { try await runner.getAnimeUpdate(anime: $0) }
                    )
                )
            }
        case .novel:
            let response = try await runner.getSearchNovelList(query: query, page: 1, filters: nil)
            AppLogger.ui.debug("🔍 [Search] \(plugin.name) WASM returned \(response.entries.count) raw novel entries (hasNextPage: \(response.hasNextPage))")
            guard !Task.isCancelled else { return [] }
            return response.entries.prefix(limit).map { novel in
                PluginSearchResult(
                    id: novel.key,
                    title: novel.title,
                    cover: novel.cover,
                    subtitle: novel.displayStatus,
                    pluginName: plugin.name,
                    destination: AnyView(
                        MediaDetailView(
                            runner: runner,
                            media: novel,
                            pluginId: plugin.id
                        ) { try await runner.getNovelUpdate(novel: $0) }
                    )
                )
            }
        case .unsupported:
            return []
        }
    }

    func evictRunner(for pluginID: String) {
        pluginManager.evictRunner(for: pluginID)
    }

    private func searchKind(for plugin: InstalledPlugin) -> SearchPluginKind {
        switch plugin.info.type {
        case .manga:
            return .manga
        case .anime:
            return .anime
        case .novel:
            return .novel
        @unknown default:
            return .unsupported
        }
    }
}

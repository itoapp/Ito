import Foundation
import Combine
import SwiftUI
import ito_runner

@MainActor
public class SearchViewModel: ObservableObject {
    @Published public var searchText: String = ""
    @Published public var searchScope: SearchScope = .all
    @Published public var searchResults: [String: [PluginSearchResult]] = [:]
    @Published public var isSearching: Bool = false
    @Published public var activeTasks: Set<String> = []
    @Published public var recentSearches: [String] = []

    private var cancellables = Set<AnyCancellable>()
    private var currentTasks: [Task<Void, Never>] = []
    private var searchSessionID = UUID()

    public init() {
        self.recentSearches = UserDefaults.standard.stringArray(forKey: "Ito.RecentSearches") ?? []

        Publishers.CombineLatest($searchText, $searchScope)
            .dropFirst()
            .debounce(for: .milliseconds(700), scheduler: RunLoop.main)
            .sink { [weak self] query, _ in
                // If the user clears the search, don't auto-search but definitely wipe the old results
                self?.performSearch(query: query)
            }
            .store(in: &cancellables)
    }

    public func performSearch(query: String) {
        // Cancel any existing tasks from a previous search
        currentTasks.forEach { $0.cancel() }
        currentTasks.removeAll()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            self.searchResults = [:]
            self.isSearching = false
            self.activeTasks.removeAll()
            return
        }

        self.isSearching = true
        self.searchResults.removeAll()
        self.activeTasks.removeAll()

        // Track unique execution run
        let sessionID = UUID()
        self.searchSessionID = sessionID

        let plugins = PluginManager.shared.installedPlugins.values.sorted { $0.info.name < $1.info.name }

        // Filter plugins based on the currently selected scope!
        var validPlugins: [InstalledPlugin] = []
        for plugin in plugins {
            switch searchScope {
            case .all:
                validPlugins.append(plugin)
            case .manga:
                if plugin.info.type == .manga { validPlugins.append(plugin) }
            case .anime:
                if plugin.info.type == .anime { validPlugins.append(plugin) }
            case .novel:
                if plugin.info.type == .novel { validPlugins.append(plugin) }
            }
        }

        if validPlugins.isEmpty {
            self.isSearching = false
            return
        }

        // Save to Recent Searches dynamically capping at 10 items
        if !recentSearches.contains(trimmed) {
            recentSearches.insert(trimmed, at: 0)
            if recentSearches.count > 10 {
                recentSearches.removeLast()
            }
            UserDefaults.standard.set(recentSearches, forKey: "Ito.RecentSearches")
        }

        for plugin in validPlugins {
            activeTasks.insert(plugin.id)
        }

        for plugin in validPlugins {
            let task = Task { @MainActor in
                defer {
                    if self.searchSessionID == sessionID {
                        self.activeTasks.remove(plugin.id)
                        if self.activeTasks.isEmpty {
                            self.isSearching = false
                        }
                    }
                }

                do {
                    let runner = try await PluginManager.shared.getRunner(for: plugin.id)
                    var results: [PluginSearchResult] = []

                    if self.searchSessionID != sessionID { return }

                    switch plugin.info.type {
                    case .manga:
                        let res = try await runner.getSearchMangaList(query: trimmed, page: 1, filters: nil)
                        results = res.entries.prefix(25).map { manga in
                            PluginSearchResult(
                                id: manga.key,
                                title: manga.title,
                                cover: manga.cover,
                                subtitle: manga.displayStatus,
                                pluginName: plugin.info.name,
                                destination: AnyView(MediaDetailView(runner: runner, media: manga, pluginId: plugin.id) { try await runner.getMangaUpdate(manga: $0) })
                            )
                        }
                    case .anime:
                        let res = try await runner.getSearchAnimeList(query: trimmed, page: 1, filters: nil)
                        results = res.entries.prefix(25).map { anime in
                            PluginSearchResult(
                                id: anime.key,
                                title: anime.title,
                                cover: anime.cover,
                                subtitle: anime.displayStatus,
                                pluginName: plugin.info.name,
                                destination: AnyView(MediaDetailView(runner: runner, media: anime, pluginId: plugin.id) { try await runner.getAnimeUpdate(anime: $0) })
                            )
                        }
                    case .novel:
                        let res = try await runner.getSearchNovelList(query: trimmed, page: 1, filters: nil)
                        results = res.entries.prefix(25).map { novel in
                            PluginSearchResult(
                                id: novel.key,
                                title: novel.title,
                                cover: novel.cover,
                                subtitle: novel.displayStatus,
                                pluginName: plugin.info.name,
                                destination: AnyView(MediaDetailView(runner: runner, media: novel, pluginId: plugin.id) { try await runner.getNovelUpdate(novel: $0) })
                            )
                        }
                    @unknown default:
                        break
                    }

                    if self.searchSessionID == sessionID && !results.isEmpty {
                        self.searchResults[plugin.info.name] = results
                    }
                } catch {
                    print("Search failed for \(plugin.info.name): \(error)")
                }
            }
            currentTasks.append(task)
        }
    }

    public func clearRecentSearches() {
        recentSearches.removeAll()
        UserDefaults.standard.removeObject(forKey: "Ito.RecentSearches")
    }
}

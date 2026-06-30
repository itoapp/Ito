import OSLog
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

        // IMPORTANT: ItoRunner WASM host functions use DispatchSemaphore to bridge
        // sync WASM ↔ async Swift. Each in-flight call blocks one thread from the
        // cooperative thread pool. Running too many searches concurrently exhausts
        // the pool and deadlocks. We run searches SERIALLY to avoid this.
        let searchPlugins = validPlugins
        let searchQuery = trimmed
        let task = Task { @MainActor in
            for plugin in searchPlugins {
                // Bail out if a newer search has started
                guard !Task.isCancelled, self.searchSessionID == sessionID else {
                    AppLogger.ui.debug("🔍 [Search] Session invalidated, stopping")
                    break
                }

                do {
                    AppLogger.ui.debug("\("🔍 [Search] Getting runner for \(plugin.info.name)")...")
                    let runner = try await PluginManager.shared.getRunner(for: plugin.id)

                    guard !Task.isCancelled, self.searchSessionID == sessionID else { break }

                    AppLogger.ui.debug("\("🔍 [Search] Searching \(plugin.info.name)") for '\(searchQuery)'...")
                    var results: [PluginSearchResult] = []

                    switch plugin.info.type {
                    case .manga:
                        let res = try await runner.getSearchMangaList(query: searchQuery, page: 1, filters: nil)
                        AppLogger.ui.debug("\("🔍 [Search] \(plugin.info.name)") WASM returned \(res.entries.count) raw manga entries (hasNextPage: \(res.hasNextPage))")
                        guard !Task.isCancelled else { break }
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
                        let res = try await runner.getSearchAnimeList(query: searchQuery, page: 1, filters: nil)
                        AppLogger.ui.debug("\("🔍 [Search] \(plugin.info.name)") WASM returned \(res.entries.count) raw anime entries (hasNextPage: \(res.hasNextPage))")
                        guard !Task.isCancelled else { break }
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
                        let res = try await runner.getSearchNovelList(query: searchQuery, page: 1, filters: nil)
                        AppLogger.ui.debug("\("🔍 [Search] \(plugin.info.name)") WASM returned \(res.entries.count) raw novel entries (hasNextPage: \(res.hasNextPage))")
                        guard !Task.isCancelled else { break }
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

                    let sessionValid = self.searchSessionID == sessionID
                    if sessionValid && !results.isEmpty {
                        AppLogger.ui.debug("\("🔍 [Search] \(plugin.info.name)") → \(results.count) results added to UI")
                        self.searchResults[plugin.info.name] = results
                    } else if !sessionValid {
                        AppLogger.ui.debug("\("🔍 [Search] \(plugin.info.name)") → DROPPED (session expired)")
                    } else {
                        AppLogger.ui.debug("\("🔍 [Search] \(plugin.info.name)") → 0 mapped results, skipping")
                    }
                } catch is CancellationError {
                    AppLogger.ui.debug("🔍 [Search] Cancelled for \(plugin.info.name)")
                    break
                } catch {
                    AppLogger.ui.error("\("🔍 [Search] Failed for \(plugin.info.name)"): \(error)")
                    // If a WASM trap occurred, the runner state may be corrupted.
                    // Evict it so the next use creates a fresh instance.
                    if "\(error)".contains("wasmTrap") || "\(error)".contains("Trap") {
                        AppLogger.ui.debug("🔍 [Search] Evicting corrupted runner for \(plugin.id)")
                        PluginManager.shared.evictRunner(for: plugin.id)
                    }
                }

                // Mark this plugin as done
                if self.searchSessionID == sessionID {
                    self.activeTasks.remove(plugin.id)
                }
            }

            // All done (or cancelled)
            if self.searchSessionID == sessionID {
                self.activeTasks.removeAll()
                self.isSearching = false
                AppLogger.ui.debug("🔍 [Search] All search tasks complete")
            }
        }
        currentTasks = [task]
    }

    public func clearRecentSearches() {
        recentSearches.removeAll()
        UserDefaults.standard.removeObject(forKey: "Ito.RecentSearches")
    }
}

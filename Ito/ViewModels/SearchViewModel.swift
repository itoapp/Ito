import Foundation
import Combine
import OSLog
import SwiftUI

@MainActor
public class SearchViewModel: ObservableObject {
    static let automaticSearchDebounceMilliseconds = 700

    @Published public var searchText: String = ""
    @Published public var searchScope: SearchScope = .all
    @Published public var searchResults: [String: [PluginSearchResult]] = [:]
    @Published public var isSearching: Bool = false
    @Published public var activeTasks: Set<String> = []
    @Published public var recentSearches: [String] = []

    private var cancellables = Set<AnyCancellable>()
    private var currentTasks: [Task<Void, Never>] = []
    private var searchSessionID = UUID()
    private var searchExecutor: (any SearchPluginExecuting)?
    private let recentSearchStore: any RecentSearchPersisting

    public convenience init() {
        self.init(
            searchExecutor: nil,
            recentSearchStore: UserDefaultsRecentSearchStore(),
            debounceMilliseconds: Self.automaticSearchDebounceMilliseconds
        )
    }

    init(
        searchExecutor: (any SearchPluginExecuting)?,
        recentSearchStore: any RecentSearchPersisting,
        debounceMilliseconds: Int?
    ) {
        self.searchExecutor = searchExecutor
        self.recentSearchStore = recentSearchStore
        self.recentSearches = recentSearchStore.load()

        if let debounceMilliseconds {
            Publishers.CombineLatest($searchText, $searchScope)
                .dropFirst()
                .debounce(for: .milliseconds(debounceMilliseconds), scheduler: RunLoop.main)
                .sink { [weak self] query, _ in
                    // If the user clears the search, don't auto-search but definitely wipe the old results
                    self?.performSearch(query: query)
                }
                .store(in: &cancellables)
        }
    }

    public func configure(pluginManager: PluginManager) {
        self.searchExecutor = PluginManagerSearchExecutor(pluginManager: pluginManager)
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

        guard let searchExecutor else {
            isSearching = false
            return
        }
        let plugins = searchExecutor.plugins.sorted { $0.name < $1.name }

        // Filter plugins based on the currently selected scope!
        var validPlugins: [SearchPluginDescriptor] = []
        for plugin in plugins {
            switch searchScope {
            case .all:
                validPlugins.append(plugin)
            case .manga:
                if plugin.kind == .manga { validPlugins.append(plugin) }
            case .anime:
                if plugin.kind == .anime { validPlugins.append(plugin) }
            case .novel:
                if plugin.kind == .novel { validPlugins.append(plugin) }
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
            recentSearchStore.save(recentSearches)
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
                    let searchResults = try await searchExecutor.search(
                        plugin: plugin,
                        query: searchQuery,
                        limit: 25
                    )
                    guard !Task.isCancelled else { break }
                    let results = Array(searchResults.prefix(25))

                    let sessionValid = self.searchSessionID == sessionID
                    if sessionValid && !results.isEmpty {
                        AppLogger.ui.debug("🔍 [Search] \(plugin.name) → \(results.count) results added to UI")
                        self.searchResults[plugin.name] = results
                    } else if !sessionValid {
                        AppLogger.ui.debug("🔍 [Search] \(plugin.name) → DROPPED (session expired)")
                    } else {
                        AppLogger.ui.debug("🔍 [Search] \(plugin.name) → 0 mapped results, skipping")
                    }
                } catch is CancellationError {
                    AppLogger.ui.debug("🔍 [Search] Cancelled for \(plugin.name)")
                    break
                } catch {
                    AppLogger.ui.error("🔍 [Search] Failed for \(plugin.name): \(error)")
                    // If a WASM trap occurred, the runner state may be corrupted.
                    // Evict it so the next use creates a fresh instance.
                    if "\(error)".contains("wasmTrap") || "\(error)".contains("Trap") {
                        AppLogger.ui.debug("🔍 [Search] Evicting corrupted runner for \(plugin.id)")
                        searchExecutor.evictRunner(for: plugin.id)
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
        recentSearchStore.clear()
    }
}

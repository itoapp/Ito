import XCTest
import ito_runner
@testable import Ito

@MainActor
final class SearchViewModelTests: XCTestCase {
    func testConstructorInjectionRequiresNoLaterConfigurationCall() async {
        let executor = SearchViewModelRecordingExecutor(plugins: [.manga()])
        let viewModel = makeViewModel(executor: executor)

        viewModel.performSearch(query: "query")
        await waitUntil { !viewModel.isSearching }

        XCTAssertEqual(executor.invocations.map(\.query), ["query"])
    }

    func testInitialStateIsIdle() {
        let viewModel = makeViewModel()

        guard case .idle = viewModel.state else {
            return XCTFail("Expected idle state")
        }
        XCTAssertFalse(viewModel.isSearching)
        XCTAssertTrue(viewModel.searchResults.isEmpty)
    }

    func testLoadingStateDuringActiveOperation() async {
        let executor = SearchViewModelSuspendingExecutor(plugins: [.manga()])
        let viewModel = makeViewModel(executor: executor)

        viewModel.performSearch(query: "query")
        await waitUntil { executor.pendingCount == 1 }

        guard case .loading(let results, let activePluginIDs) = viewModel.state else {
            return XCTFail("Expected loading state")
        }
        XCTAssertTrue(results.isEmpty)
        XCTAssertEqual(activePluginIDs, ["plugin.manga"])

        executor.complete(query: "query", with: [])
        await waitUntil { !viewModel.isSearching }
    }

    func testContentStateAfterSuccessfulResults() async {
        let executor = SearchViewModelRecordingExecutor(plugins: [.manga()])
        executor.resultsByPluginID["plugin.manga"] = [.result(id: "content")]
        let viewModel = makeViewModel(executor: executor)

        viewModel.performSearch(query: "query")
        await waitUntil { !viewModel.isSearching }

        guard case .content(let results) = viewModel.state else {
            return XCTFail("Expected content state")
        }
        XCTAssertEqual(results["Manga Plugin"]?.map(\.id), ["content"])
    }

    func testEmptyStateAfterSuccessfulZeroResultSearch() async {
        let executor = SearchViewModelRecordingExecutor(plugins: [.manga()])
        executor.resultsByPluginID["plugin.manga"] = []
        let viewModel = makeViewModel(executor: executor)

        viewModel.performSearch(query: "query")
        await waitUntil { !viewModel.isSearching }

        guard case .empty = viewModel.state else {
            return XCTFail("Expected empty state")
        }
    }

    func testPartialFailurePreservesSuccessfulPluginResults() async {
        let executor = SearchViewModelRecordingExecutor(
            plugins: [
                .init(id: "plugin.a", name: "Alpha", kind: .manga),
                .init(id: "plugin.b", name: "Beta", kind: .anime)
            ]
        )
        executor.errorsByPluginID["plugin.a"] = SearchPluginExecutionError.pluginExecution
        executor.resultsByPluginID["plugin.b"] = [.result(id: "success")]
        let viewModel = makeViewModel(executor: executor)

        viewModel.performSearch(query: "query")
        await waitUntil { !viewModel.isSearching }

        guard case .partialFailure(let results, let failedPluginCount) = viewModel.state else {
            return XCTFail("Expected partial-failure state")
        }
        XCTAssertEqual(failedPluginCount, 1)
        XCTAssertEqual(results["Beta"]?.map(\.id), ["success"])
        XCTAssertNil(results["Alpha"])
    }

    func testTotalFailureIsDistinctFromEmpty() async {
        let executor = SearchViewModelRecordingExecutor(plugins: [.manga()])
        executor.errorsByPluginID["plugin.manga"] = SearchPluginExecutionError.pluginExecution
        let viewModel = makeViewModel(executor: executor)

        viewModel.performSearch(query: "query")
        await waitUntil { !viewModel.isSearching }

        guard case .failure(.pluginExecution) = viewModel.state else {
            return XCTFail("Expected total plugin-execution failure")
        }
    }

    func testCancelledStateIsTerminalForCancelledOperation() async {
        let executor = SearchViewModelSuspendingExecutor(plugins: [.manga()])
        let viewModel = makeViewModel(executor: executor)

        viewModel.performSearch(query: "query")
        await waitUntil { executor.pendingCount == 1 }
        viewModel.cancelSearch()

        guard case .cancelled = viewModel.state else {
            return XCTFail("Expected cancelled state")
        }

        executor.complete(query: "query", with: [.result(id: "stale")])
        await waitUntil { executor.pendingCount == 0 }
        await Task.yield()

        guard case .cancelled = viewModel.state else {
            return XCTFail("Stale completion must not replace cancelled state")
        }
        XCTAssertTrue(viewModel.searchResults.isEmpty)
    }

    func testNewerOperationSupersedesPriorAndStaleResultsCannotMutateState() async throws {
        let executor = SearchViewModelSuspendingExecutor(plugins: [.manga()])
        let logger = PresentationEventCaptureSpy()
        let viewModel = makeViewModel(executor: executor, logger: logger)

        viewModel.performSearch(query: "first")
        await waitUntil { executor.pendingQueries == ["first"] }
        let firstOperationID = try XCTUnwrap(logger.operationStartedIDs.first)

        viewModel.performSearch(query: "second")
        await waitUntil { executor.pendingQueries == ["first", "second"] }
        let secondOperationID = try XCTUnwrap(logger.operationStartedIDs.last)
        XCTAssertNotEqual(firstOperationID, secondOperationID)

        executor.complete(query: "first", with: [.result(id: "stale")])
        await waitUntil {
            logger.events.contains {
                $0.operationID == firstOperationID && $0.outcome == .ignoredStale
            }
        }
        XCTAssertTrue(viewModel.searchResults.isEmpty)
        XCTAssertTrue(viewModel.isSearching)

        executor.complete(query: "second", with: [.result(id: "fresh")])
        await waitUntil { !viewModel.isSearching }

        XCTAssertEqual(viewModel.searchResults["Manga Plugin"]?.map(\.id), ["fresh"])
        XCTAssertTrue(logger.events.contains {
            $0.operationID == firstOperationID && $0.outcome == .cancelled
        })
        XCTAssertTrue(logger.events.contains {
            $0.operationID == firstOperationID && $0.outcome == .ignoredStale
        })
    }

    func testSuccessEventSequenceUsesOneOperationUUID() async throws {
        let executor = SearchViewModelRecordingExecutor(plugins: [.manga()])
        let logger = PresentationEventCaptureSpy()
        let viewModel = makeViewModel(executor: executor, logger: logger)

        viewModel.performSearch(query: "query")
        await waitUntil { !viewModel.isSearching }

        let operationID = try XCTUnwrap(logger.events.first?.operationID)
        XCTAssertTrue(logger.events.allSatisfy { $0.operationID == operationID })
        XCTAssertEqual(
            logger.events.map(\.kind),
            [.operation, .pluginExecution, .pluginExecution, .operation]
        )
        XCTAssertEqual(
            logger.events.map(\.phase),
            [.started, .started, .finished, .finished]
        )
        XCTAssertEqual(
            logger.events.map(\.outcome),
            [nil, nil, .succeeded, .succeeded]
        )
    }

    func testPartialAndTotalFailureEmitDistinctTypedOutcomes() async {
        let partialExecutor = SearchViewModelRecordingExecutor(
            plugins: [
                .init(id: "plugin.a", name: "Alpha", kind: .manga),
                .init(id: "plugin.b", name: "Beta", kind: .anime)
            ]
        )
        partialExecutor.errorsByPluginID["plugin.a"] = SearchPluginExecutionError.pluginExecution
        let partialLogger = PresentationEventCaptureSpy()
        let partialViewModel = makeViewModel(
            executor: partialExecutor,
            logger: partialLogger
        )

        partialViewModel.performSearch(query: "partial")
        await waitUntil { !partialViewModel.isSearching }

        XCTAssertEqual(
            partialLogger.events.last?.outcome,
            .partiallySucceeded(.pluginExecution)
        )

        let failedExecutor = SearchViewModelRecordingExecutor(plugins: [.manga()])
        failedExecutor.errorsByPluginID["plugin.manga"] = SearchPluginExecutionError.pluginExecution
        let failedLogger = PresentationEventCaptureSpy()
        let failedViewModel = makeViewModel(executor: failedExecutor, logger: failedLogger)

        failedViewModel.performSearch(query: "failure")
        await waitUntil { !failedViewModel.isSearching }

        XCTAssertEqual(failedLogger.events.last?.outcome, .failed(.pluginExecution))
    }

    func testPluginTrapEmitsSafeTypedEventAndEvictsRunner() async {
        let executor = SearchViewModelRecordingExecutor(plugins: [.manga()])
        executor.errorsByPluginID["plugin.manga"] = SearchPluginExecutionError.pluginTrap
        let logger = PresentationEventCaptureSpy()
        let viewModel = makeViewModel(executor: executor, logger: logger)

        viewModel.performSearch(query: "query")
        await waitUntil { !viewModel.isSearching }

        XCTAssertEqual(executor.evictedPluginIDs, ["plugin.manga"])
        XCTAssertTrue(logger.events.contains {
            $0.kind == .pluginExecution && $0.outcome == .failed(.pluginTrap)
        })
        XCTAssertEqual(logger.events.last?.outcome, .failed(.pluginTrap))
    }

    func testSensitiveValuesNeverAppearInEventsOrFormattedOutput() async {
        let sensitiveQuery = "sentinel-private-query"
        let sensitiveTitle = "sentinel-private-media-title"
        let executor = SearchViewModelRecordingExecutor(plugins: [.manga()])
        executor.resultsByPluginID["plugin.manga"] = [
            .result(id: "result", title: sensitiveTitle)
        ]
        let logger = PresentationEventCaptureSpy()
        let viewModel = makeViewModel(executor: executor, logger: logger)

        viewModel.performSearch(query: sensitiveQuery)
        await waitUntil { !viewModel.isSearching }

        let eventDescription = String(reflecting: logger.events)
        let formattedOutput = logger.formattedMessages.joined(separator: "\n")
        XCTAssertFalse(eventDescription.contains(sensitiveQuery))
        XCTAssertFalse(eventDescription.contains(sensitiveTitle))
        XCTAssertFalse(formattedOutput.contains(sensitiveQuery))
        XCTAssertFalse(formattedOutput.contains(sensitiveTitle))
    }

    func testSourceContainsNoGlobalDefaultsMutableConfigurationOrSwiftUIDestination() throws {
        let source = try sourceFile("Ito/ViewModels/SearchViewModel.swift")

        for forbidden in [
            ".shared",
            "UserDefaults.standard",
            "AppLogger",
            "AnyView",
            "configure(pluginManager:"
        ] {
            XCTAssertFalse(source.contains(forbidden), "Found forbidden source: \(forbidden)")
        }
    }

    private func makeViewModel(
        executor: any SearchPluginExecuting = SearchViewModelRecordingExecutor(plugins: []),
        store: SearchViewModelRecentStore = SearchViewModelRecentStore(),
        logger: PresentationEventCaptureSpy = PresentationEventCaptureSpy()
    ) -> SearchViewModel {
        SearchViewModel(
            searchExecutor: executor,
            recentSearchStore: store,
            debounceMilliseconds: nil,
            presentationLogger: logger
        )
    }

    private func waitUntil(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Condition was not met before timeout", file: file, line: line)
    }

    private func sourceFile(_ path: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(path),
            encoding: .utf8
        )
    }
}

@MainActor
private final class SearchViewModelRecentStore: RecentSearchPersisting {
    func load() -> [String] { [] }
    func save(_ searches: [String]) { _ = searches }
    func clear() {}
}

@MainActor
private final class SearchViewModelRecordingExecutor: SearchPluginExecuting {
    struct Invocation {
        let pluginID: String
        let query: String
        let limit: Int
    }

    let plugins: [SearchPluginDescriptor]
    var resultsByPluginID: [String: [PluginSearchResult]] = [:]
    var errorsByPluginID: [String: any Error] = [:]
    private(set) var invocations: [Invocation] = []
    private(set) var evictedPluginIDs: [String] = []

    init(plugins: [SearchPluginDescriptor]) {
        self.plugins = plugins
    }

    func search(
        plugin: SearchPluginDescriptor,
        query: String,
        limit: Int
    ) async throws -> [PluginSearchResult] {
        invocations.append(.init(pluginID: plugin.id, query: query, limit: limit))
        if let error = errorsByPluginID[plugin.id] { throw error }
        return resultsByPluginID[plugin.id] ?? [.result(id: plugin.id)]
    }

    func evictRunner(for pluginID: String) {
        evictedPluginIDs.append(pluginID)
    }
}

@MainActor
private final class SearchViewModelSuspendingExecutor: SearchPluginExecuting {
    private struct PendingSearch {
        let query: String
        let continuation: CheckedContinuation<[PluginSearchResult], any Error>
    }

    let plugins: [SearchPluginDescriptor]
    private var pending: [PendingSearch] = []

    init(plugins: [SearchPluginDescriptor]) {
        self.plugins = plugins
    }

    var pendingCount: Int { pending.count }
    var pendingQueries: [String] { pending.map(\.query) }

    func search(
        plugin: SearchPluginDescriptor,
        query: String,
        limit: Int
    ) async throws -> [PluginSearchResult] {
        _ = plugin
        _ = limit
        return try await withCheckedThrowingContinuation { continuation in
            pending.append(.init(query: query, continuation: continuation))
        }
    }

    func evictRunner(for pluginID: String) {
        _ = pluginID
    }

    func complete(query: String, with results: [PluginSearchResult]) {
        guard let index = pending.firstIndex(where: { $0.query == query }) else { return }
        let search = pending.remove(at: index)
        search.continuation.resume(returning: results)
    }
}

@MainActor
private extension PresentationEventCaptureSpy {
    var operationStartedIDs: [UUID] {
        events.compactMap { event in
            guard event.kind == .operation, event.phase == .started else { return nil }
            return event.operationID
        }
    }
}

private extension SearchPluginDescriptor {
    static func manga() -> Self {
        .init(id: "plugin.manga", name: "Manga Plugin", kind: .manga)
    }
}

private extension PluginSearchResult {
    @MainActor
    static func result(id: String, title: String? = nil) -> Self {
        let runner = ItoRunner()
        return .init(
            id: id,
            title: title ?? id,
            cover: nil,
            subtitle: nil,
            destination: .manga(
                pluginID: "plugin.manga",
                context: ItoRunnerSearchContext(runner: runner),
                media: Manga(key: id, title: title ?? id)
            )
        )
    }
}

import XCTest
import ito_runner
@testable import Ito

@MainActor
final class ListingViewModelTests: XCTestCase {
    func testInitialStateCapturesListingIdentityWithoutLoading() {
        let context = PR7BSourceRunnerContextSpy()
        let viewModel = makeViewModel(context: context)

        XCTAssertEqual(viewModel.phase, .idle)
        XCTAssertEqual(viewModel.paginationState, .idle)
        XCTAssertEqual(viewModel.nextPage, 1)
        XCTAssertTrue(viewModel.hasNextPage)
        XCTAssertTrue(viewModel.isEmpty)
        XCTAssertEqual(viewModel.identity.listingID, "popular")
        XCTAssertEqual(viewModel.identity.pluginID, "plugin.manga")
        XCTAssertTrue(context.listingInvocations.isEmpty)
    }

    func testInitialPageSuccessPublishesInRunnerOrderAndAdvancesPage() async {
        let context = PR7BSourceRunnerContextSpy()
        context.listingResults[1] = .success(.manga(
            entries: [Manga(key: "b", title: "B"), Manga(key: "a", title: "A")],
            hasNextPage: true
        ))
        let viewModel = makeViewModel(context: context)

        await viewModel.loadInitialIfNeeded()

        XCTAssertEqual(viewModel.phase, .content)
        XCTAssertEqual(viewModel.mangas.map(\.key), ["b", "a"])
        XCTAssertEqual(viewModel.nextPage, 2)
        XCTAssertTrue(viewModel.hasNextPage)
        XCTAssertEqual(context.listingInvocations.map(\.page), [1])
    }

    func testInitialPageFailureIsRetryableAndDoesNotAdvancePage() async {
        let context = PR7BSourceRunnerContextSpy()
        context.listingResults[1] = .failure(PR7BTestFailure.failed)
        let viewModel = makeViewModel(context: context)

        await viewModel.loadInitialIfNeeded()

        XCTAssertEqual(viewModel.phase, .failure("fixture failure"))
        XCTAssertEqual(viewModel.nextPage, 1)
        XCTAssertTrue(viewModel.isEmpty)

        context.listingResults[1] = .success(.manga(
            entries: [Manga(key: "recovered", title: "Recovered")],
            hasNextPage: false
        ))
        await viewModel.retry()

        XCTAssertEqual(context.listingInvocations.map(\.page), [1, 1])
        XCTAssertEqual(viewModel.mangas.map(\.key), ["recovered"])
        XCTAssertEqual(viewModel.phase, .content)
    }

    func testEmptyInitialPageProducesStableEmptyAndExhaustedState() async {
        let context = PR7BSourceRunnerContextSpy()
        context.listingResults[1] = .success(.manga(entries: [], hasNextPage: false))
        let viewModel = makeViewModel(context: context)

        await viewModel.loadInitialIfNeeded()

        XCTAssertEqual(viewModel.phase, .empty)
        XCTAssertEqual(viewModel.paginationState, .exhausted)
        XCTAssertFalse(viewModel.hasNextPage)
        await viewModel.loadMore()
        XCTAssertEqual(context.listingInvocations.map(\.page), [1])
    }

    func testEmptyNonterminalFirstPageCanReachSecondPageContent() async {
        let context = PR7BSourceRunnerContextSpy()
        context.listingResults = [
            1: .success(.manga(entries: [], hasNextPage: true)),
            2: .success(.manga(
                entries: [Manga(key: "later", title: "Later")],
                hasNextPage: false
            ))
        ]
        let viewModel = makeViewModel(context: context)

        await viewModel.loadInitial()
        XCTAssertEqual(viewModel.phase, .empty)
        XCTAssertTrue(viewModel.hasNextPage)
        XCTAssertEqual(viewModel.nextPage, 2)

        await viewModel.loadMore()

        XCTAssertEqual(context.listingInvocations.map(\.page), [1, 2])
        XCTAssertEqual(viewModel.mangas.map(\.key), ["later"])
        XCTAssertEqual(viewModel.phase, .content)
        XCTAssertEqual(viewModel.paginationState, .exhausted)
    }

    func testEmptyNonterminalPaginationFailureRetriesSameSecondPage() async {
        let context = PR7BSourceRunnerContextSpy()
        context.listingResults = [
            1: .success(.manga(entries: [], hasNextPage: true)),
            2: .failure(PR7BTestFailure.failed)
        ]
        let viewModel = makeViewModel(context: context)

        await viewModel.loadInitial()
        await viewModel.loadMore()
        context.listingResults[2] = .success(.manga(
            entries: [Manga(key: "recovered", title: "Recovered")],
            hasNextPage: false
        ))
        await viewModel.retry()

        XCTAssertEqual(context.listingInvocations.map(\.page), [1, 2, 2])
        XCTAssertEqual(viewModel.mangas.map(\.key), ["recovered"])
        XCTAssertEqual(viewModel.nextPage, 3)
        XCTAssertEqual(viewModel.paginationState, .exhausted)
    }

    func testPaginationAppendsInOrderAndAdvancesOnlyAfterSuccess() async {
        let context = PR7BSourceRunnerContextSpy()
        context.listingResults[1] = .success(.manga(
            entries: [Manga(key: "one", title: "One")],
            hasNextPage: true
        ))
        context.listingResults[2] = .success(.manga(
            entries: [Manga(key: "two", title: "Two")],
            hasNextPage: true
        ))
        let viewModel = makeViewModel(context: context)

        await viewModel.loadInitialIfNeeded()
        await viewModel.loadMore()

        XCTAssertEqual(viewModel.mangas.map(\.key), ["one", "two"])
        XCTAssertEqual(viewModel.nextPage, 3)
        XCTAssertEqual(viewModel.paginationState, .idle)
        XCTAssertEqual(context.listingInvocations.map(\.page), [1, 2])
    }

    func testEmptyNonterminalLaterPageExposesContinuationAndReachesFollowingContent() async {
        let context = PR7BSourceRunnerContextSpy()
        context.listingResults = [
            1: .success(.manga(
                entries: [Manga(key: "one", title: "One")],
                hasNextPage: true
            )),
            2: .success(.manga(entries: [], hasNextPage: true)),
            3: .success(.manga(
                entries: [Manga(key: "three", title: "Three")],
                hasNextPage: false
            ))
        ]
        let viewModel = makeViewModel(context: context)

        await viewModel.loadInitialIfNeeded()
        await viewModel.loadMore()

        XCTAssertEqual(viewModel.mangas.map(\.key), ["one"])
        XCTAssertEqual(viewModel.nextPage, 3)
        XCTAssertEqual(viewModel.paginationState, .continuationRequired(page: 3))
        XCTAssertEqual(viewModel.phase, .content)

        await viewModel.loadMore()

        XCTAssertEqual(context.listingInvocations.map(\.page), [1, 2, 3])
        XCTAssertEqual(viewModel.mangas.map(\.key), ["one", "three"])
        XCTAssertEqual(viewModel.nextPage, 4)
        XCTAssertEqual(viewModel.paginationState, .exhausted)
    }

    func testEndOfListRemainsStableAndSuppressesFurtherRequests() async {
        let context = PR7BSourceRunnerContextSpy()
        context.listingResults[1] = .success(.manga(
            entries: [Manga(key: "one", title: "One")],
            hasNextPage: true
        ))
        context.listingResults[2] = .success(.manga(
            entries: [Manga(key: "two", title: "Two")],
            hasNextPage: false
        ))
        let viewModel = makeViewModel(context: context)

        await viewModel.loadInitialIfNeeded()
        await viewModel.loadMore()
        await viewModel.loadMore()

        XCTAssertEqual(context.listingInvocations.map(\.page), [1, 2])
        XCTAssertEqual(viewModel.paginationState, .exhausted)
        XCTAssertFalse(viewModel.hasNextPage)
        XCTAssertEqual(viewModel.nextPage, 3)
    }

    func testRapidDuplicatePaginationTriggersIssueOneEquivalentRequest() async {
        let context = PR7BSourceRunnerContextSpy()
        context.listingResults[1] = .success(.manga(
            entries: [Manga(key: "one", title: "One")],
            hasNextPage: true
        ))
        context.suspendedListingPages = [2]
        let viewModel = makeViewModel(context: context)
        await viewModel.loadInitialIfNeeded()

        let first = Task { await viewModel.loadMore() }
        await pr7bWaitUntil { context.pendingListings.count == 1 }
        await viewModel.loadMore()

        XCTAssertEqual(context.listingInvocations.map(\.page), [1, 2])
        context.completeListing(
            page: 2,
            with: .success(.manga(
                entries: [Manga(key: "two", title: "Two")],
                hasNextPage: false
            ))
        )
        await first.value
        XCTAssertEqual(viewModel.mangas.map(\.key), ["one", "two"])
    }

    func testPaginationFailureDoesNotAdvanceAndRetryUsesSamePage() async {
        let context = PR7BSourceRunnerContextSpy()
        context.listingResults[1] = .success(.manga(
            entries: [Manga(key: "one", title: "One")],
            hasNextPage: true
        ))
        context.listingResults[2] = .failure(PR7BTestFailure.failed)
        let viewModel = makeViewModel(context: context)
        await viewModel.loadInitialIfNeeded()

        await viewModel.loadMore()
        XCTAssertEqual(viewModel.paginationState, .failure(page: 2, reason: "fixture failure"))
        XCTAssertEqual(viewModel.nextPage, 2)
        XCTAssertEqual(viewModel.mangas.map(\.key), ["one"])

        context.listingResults[2] = .success(.manga(
            entries: [Manga(key: "retry", title: "Retry")],
            hasNextPage: false
        ))
        await viewModel.retry()

        XCTAssertEqual(context.listingInvocations.map(\.page), [1, 2, 2])
        XCTAssertEqual(viewModel.mangas.map(\.key), ["one", "retry"])
        XCTAssertEqual(viewModel.nextPage, 3)
    }

    func testReplacingListingSuppressesStaleNonCooperativeFirstPage() async {
        let stale = PR7BSourceRunnerContextSpy()
        stale.suspendedListingPages = [1]
        let fresh = PR7BSourceRunnerContextSpy()
        fresh.listingResults[1] = .success(.manga(
            entries: [Manga(key: "fresh", title: "Fresh")],
            hasNextPage: false
        ))
        let viewModel = makeViewModel(context: stale)

        let oldTask = Task { await viewModel.loadInitialIfNeeded() }
        await pr7bWaitUntil { stale.pendingListings.count == 1 }
        await viewModel.replaceDestination(makeDestination(
            context: fresh,
            listingID: "recent",
            title: "Recent"
        ))
        stale.completeListing(
            page: 1,
            with: .success(.manga(
                entries: [Manga(key: "stale", title: "Stale")],
                hasNextPage: true
            ))
        )
        await oldTask.value

        XCTAssertEqual(viewModel.identity.listingID, "recent")
        XCTAssertEqual(viewModel.title, "Recent")
        XCTAssertEqual(viewModel.mangas.map(\.key), ["fresh"])
        XCTAssertEqual(viewModel.nextPage, 2)
    }

    func testReplacingListingSuppressesStaleSubsequentPageAndTokenAdvance() async {
        let stale = PR7BSourceRunnerContextSpy()
        stale.listingResults[1] = .success(.manga(
            entries: [Manga(key: "old-one", title: "Old")],
            hasNextPage: true
        ))
        stale.suspendedListingPages = [2]
        let fresh = PR7BSourceRunnerContextSpy()
        fresh.listingResults[1] = .success(.manga(
            entries: [Manga(key: "fresh-one", title: "Fresh")],
            hasNextPage: true
        ))
        let viewModel = makeViewModel(context: stale)
        await viewModel.loadInitialIfNeeded()

        let oldPage = Task { await viewModel.loadMore() }
        await pr7bWaitUntil { stale.pendingListings.count == 1 }
        await viewModel.replaceDestination(makeDestination(
            context: fresh,
            listingID: "new-query",
            title: "New Query"
        ))
        stale.completeListing(
            page: 2,
            with: .success(.manga(
                entries: [Manga(key: "old-two", title: "Old Two")],
                hasNextPage: false
            ))
        )
        await oldPage.value

        XCTAssertEqual(viewModel.mangas.map(\.key), ["fresh-one"])
        XCTAssertEqual(viewModel.nextPage, 2)
        XCTAssertEqual(viewModel.paginationState, .idle)
    }

    func testCancellationSuppressesNonCooperativeFirstPagePublication() async {
        let context = PR7BSourceRunnerContextSpy()
        context.suspendedListingPages = [1]
        let viewModel = makeViewModel(context: context)

        let task = Task { await viewModel.loadInitialIfNeeded() }
        await pr7bWaitUntil { context.pendingListings.count == 1 }
        viewModel.cancel()
        context.completeListing(
            page: 1,
            with: .success(.manga(
                entries: [Manga(key: "obsolete", title: "Obsolete")],
                hasNextPage: true
            ))
        )
        await task.value

        XCTAssertEqual(viewModel.phase, .cancelled)
        XCTAssertTrue(viewModel.mangas.isEmpty)
        XCTAssertEqual(viewModel.nextPage, 1)
    }

    func testCharacterizedDuplicateItemsRemainUndeduplicatedAcrossPages() async {
        let context = PR7BSourceRunnerContextSpy()
        context.listingResults[1] = .success(.manga(
            entries: [Manga(key: "same", title: "First")],
            hasNextPage: true
        ))
        context.listingResults[2] = .success(.manga(
            entries: [Manga(key: "same", title: "Second")],
            hasNextPage: false
        ))
        let viewModel = makeViewModel(context: context)

        await viewModel.loadInitialIfNeeded()
        await viewModel.loadMore()

        XCTAssertEqual(viewModel.mangas.map(\.key), ["same", "same"])
        XCTAssertEqual(viewModel.mangas.map(\.title), ["First", "Second"])
    }

    func testTypedMediaRoutePreservesContextPluginAndPayload() async throws {
        let context = PR7BSourceRunnerContextSpy()
        let viewModel = makeViewModel(context: context)
        let media = Manga(key: "manga-key", title: "Manga")

        let destination = viewModel.destination(for: media)
        guard case .manga(let pluginID, let routeContext, let payload) = destination else {
            return XCTFail("Expected typed manga destination")
        }
        XCTAssertEqual(pluginID, "plugin.manga")
        XCTAssertTrue(routeContext === context)
        XCTAssertEqual(payload.key, media.key)

        let route = SearchRouteFactory().route(for: destination)
        guard case .manga(let routePluginID, let runner, let routeMedia, let loader) = route else {
            return XCTFail("Expected manga detail route")
        }
        XCTAssertEqual(routePluginID, "plugin.manga")
        XCTAssertTrue(runner === context.runner)
        XCTAssertEqual(routeMedia.key, media.key)
        _ = try await loader(routeMedia)
        XCTAssertEqual(context.mangaDetailLoadCount, 1)
    }

    func testListingResponseTypeMismatchFailsWithoutAdvancingPagination() async {
        let context = PR7BSourceRunnerContextSpy()
        context.listingResults[1] = .success(.anime(
            entries: [Anime(key: "wrong", title: "Wrong")],
            hasNextPage: true
        ))
        let viewModel = makeViewModel(context: context)

        await viewModel.loadInitialIfNeeded()

        XCTAssertEqual(
            viewModel.phase,
            .failure("The source returned an unexpected listing type.")
        )
        XCTAssertEqual(viewModel.nextPage, 1)
        XCTAssertTrue(viewModel.isEmpty)
    }

    func testMigratedListingLayerContainsNoGlobalsAdHocDestinationOrAnyView() throws {
        for path in [
            "Ito/ViewModels/ListingViewModel.swift",
            "Ito/Views/Browse/ListingView.swift"
        ] {
            let source = try sourceFile(path)
            for forbidden in [
                "PluginManager.shared", "RepoManager.shared", "SnackBarManager.shared",
                "AppDatabase.shared", "URLSession.shared", "FileManager.default",
                "UIApplication.shared", "UserDefaults.standard", "AppLogger", "AnyView",
                "MediaDetailView(", "configure("
            ] {
                XCTAssertFalse(source.contains(forbidden), "Forbidden \(forbidden) in \(path)")
            }
        }
    }

    private func makeViewModel(context: PR7BSourceRunnerContextSpy) -> ListingViewModel {
        ListingViewModel(destination: makeDestination(context: context))
    }

    private func makeDestination(
        context: PR7BSourceRunnerContextSpy,
        listingID: String = "popular",
        title: String = "Popular"
    ) -> SourceListingDestination {
        SourceListingDestination(
            plugin: pr7bPlugin(),
            context: context,
            listing: Listing(id: listingID, name: title, kind: 1),
            title: title
        )
    }

    private func sourceFile(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}

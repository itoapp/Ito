import XCTest
@testable import Ito

final class ReaderSessionEffectPlanTests: XCTestCase {
    func testMangaReadInvocationOrderAndRepeatedChapterSuppressionBoundary() throws {
        let source = try sourceFile("Ito/ViewModels/MangaReaderViewModel.swift")
        let function = try XCTUnwrap(
            source.slice(from: "func markChapterRead", to: "// MARK: - Image prefetch")
        )

        assertOrdered(
            [
                "dependencies.history.recordManga(",
                "guard !plan.asynchronousEffects.isEmpty else { return }",
                "markedChapterKeys.insert(chapter.key)",
                "let task = Task {",
                "progress.markChapterRead(",
                "tracker.updateMangaProgress("
            ],
            in: function
        )
    }

    func testMangaInitialLoadMarksAfterPublishingPagesAndBeforeAdjacentPrefetch() throws {
        let source = try sourceFile("Ito/ViewModels/MangaReaderViewModel.swift")
        let function = try XCTUnwrap(
            source.slice(from: "private func completeMainLoad", to: "private func failMainLoad")
        )

        assertOrdered(
            ["pagedPages = sorted", "loadPhase = .content", "markChapterRead(chapter)", "beginAdjacentChapterPrefetch()"],
            in: function
        )
    }

    func testMangaContinuousAndCachedPagedTransitionsPreserveMutationEffectOrder() throws {
        let source = try sourceFile("Ito/ViewModels/MangaReaderViewModel.swift")
        let continuous = try XCTUnwrap(
            source.slice(from: "func continuousPageAppeared", to: "private func pagedGoToChapter")
        )
        assertOrdered(
            ["changeCurrentChapter(to: flatPage.chapter)", "markChapterRead(flatPage.chapter)"],
            in: continuous
        )

        let paged = try XCTUnwrap(
            source.slice(from: "private func pagedGoToChapter", to: "private func continuousGoToChapter")
        )
        assertOrdered(
            ["changeCurrentChapter(to: chapter)", "pagedPages = cached", "pagedIndex = 0", "markChapterRead(chapter)", "beginAdjacentChapterPrefetch()"],
            in: paged
        )

        let direct = try XCTUnwrap(
            source.slice(from: "private func continuousGoToChapter", to: "private func changeCurrentChapter")
        )
        assertOrdered(
            ["changeCurrentChapter(to: chapter)", "segments = []", "loadPhase = .loading", "beginMainLoad(for: chapter)"],
            in: direct
        )
    }

    func testNovelReadAndTransitionInvocationOrderIsPreserved() throws {
        let source = try sourceFile("Ito/Views/Reader/NovelReaderView.swift")
        let tracking = try XCTUnwrap(source.slice(from: "private func updateTracking", to: "\n    }\n\n    func goToChapter"))
        assertOrdered(
            ["historyManager.addNovel(", "Task {", "progressManager.markAsRead(", "trackerManager.updateProgress("],
            in: tracking
        )

        let scrolling = try XCTUnwrap(source.slice(from: "if currentChapter.key != loadedChapter.chapter.key", to: "\n                                        }"))
        assertOrdered(["currentChapter = loadedChapter.chapter", "updateTracking(for: loadedChapter.chapter)"], in: scrolling)

        let navigation = try XCTUnwrap(source.slice(from: "func goToChapter", to: "\n    }\n\n    var nextChapter"))
        assertOrdered(["currentChapter = nextChap", "isLoaded = false", "loadedChapters = []", "loadInitialChapter()"], in: navigation)
    }

    func testDiscordInitialChangeAndDisappearTimerSemanticsAreLocked() throws {
        let manga = try sourceFile("Ito/ViewModels/MangaReaderViewModel.swift")
        let appear = try XCTUnwrap(
            manga.slice(from: "func appear()", to: "func disappear()")
        )
        XCTAssertTrue(appear.contains("resetTimer: true"))
        let change = try XCTUnwrap(
            manga.slice(from: "private func changeCurrentChapter", to: "// MARK: - Main chapter loading")
        )
        XCTAssertTrue(change.contains("resetTimer: false"))
        let disappear = try XCTUnwrap(
            manga.slice(from: "func disappear()", to: "// MARK: - Viewer and settings")
        )
        XCTAssertTrue(disappear.contains("clearMangaReaderPresence()"))

        let novel = try sourceFile("Ito/Views/Reader/NovelReaderView.swift")
        let onAppear = try XCTUnwrap(
            novel.slice(from: ".onAppear {", to: "\n        .onChange(of: currentChapter.key)")
        )
        XCTAssertTrue(onAppear.contains("resetTimer: true"))
        let onChange = try XCTUnwrap(
            novel.slice(from: ".onChange(of: currentChapter.key)", to: "\n        .onDisappear")
        )
        XCTAssertTrue(onChange.contains("resetTimer: false"))
        let onDisappear = try XCTUnwrap(
            novel.slice(from: ".onDisappear {", to: "\n        }")
        )
        XCTAssertTrue(onDisappear.contains("discordRPCManager.clearActivity()"))
    }

    func testNovelPagingChangesChapterBeforePrefetchWithoutMovingTrackingIntoPager() throws {
        let source = try sourceFile("Ito/Views/Reader/NovelPagingReaderView.swift")
        let callback = try XCTUnwrap(
            source.slice(from: "onPageChanged: { newIndex in", to: "onLoadNextChapter()")
        )

        assertOrdered(["currentChapter = newChap", "onLoadNextChapter()"], in: callback)
        XCTAssertFalse(callback.contains("updateTracking"))
        XCTAssertFalse(callback.contains("HistoryManager"))
        XCTAssertFalse(callback.contains("ReadProgressManager"))
    }

    func testOnlyMangaReaderAdoptsScreenOwnedViewModel() throws {
        let manga = try sourceFile("Ito/Views/Reader/ReaderView.swift")
        XCTAssertTrue(manga.contains("@StateObject private var viewModel: MangaReaderViewModel"))
        XCTAssertTrue(manga.contains("StateObject(wrappedValue: viewModel)"))
        XCTAssertFalse(manga.contains("ReaderViewModel("))

        for path in [
            "Ito/Views/Reader/NovelReaderView.swift",
            "Ito/Views/Reader/NovelPagingReaderView.swift",
            "Ito/Views/Reader/VideoPlayerView.swift"
        ] {
            let source = try sourceFile(path)
            XCTAssertFalse(source.contains("ReaderViewModel("), path)
            XCTAssertFalse(source.contains("@StateObject"), path)
        }

        let legacy = try sourceFile("Ito/ViewModels/ReaderViewModel.swift")
        XCTAssertTrue(legacy.contains("public final class ReaderViewModel"))
    }

    func testPureChapterReadPlanLocksHistoryProgressAndTrackerOrder() {
        let plan = ReaderSessionEffectPlan.chapterRead(
            chapterNumber: 12.75,
            titleOrKey: "ignored",
            alreadyMarked: false
        )

        XCTAssertEqual(plan.synchronousEffects, [.recordHistory])
        XCTAssertEqual(
            plan.asynchronousEffects,
            [.markLocalProgress, .updateTracker(progress: 12)]
        )
    }

    func testPureChapterReadPlanLocksFallbackNumberExtraction() {
        let decimalTitle = ReaderSessionEffectPlan.chapterRead(
            chapterNumber: nil,
            titleOrKey: "Chapter 12.5 Extra",
            alreadyMarked: false
        )
        let noNumber = ReaderSessionEffectPlan.chapterRead(
            chapterNumber: nil,
            titleOrKey: "Epilogue",
            alreadyMarked: false
        )

        XCTAssertEqual(
            decimalTitle.asynchronousEffects,
            [.markLocalProgress, .updateTracker(progress: 125)]
        )
        XCTAssertEqual(noNumber.asynchronousEffects, [.markLocalProgress])
    }

    func testPureChapterReadPlanKeepsRepeatedMangaHistoryButSuppressesAsyncEffects() {
        let plan = ReaderSessionEffectPlan.chapterRead(
            chapterNumber: 3,
            titleOrKey: "Chapter 3",
            alreadyMarked: true
        )

        XCTAssertEqual(plan.synchronousEffects, [.recordHistory])
        XCTAssertEqual(plan.asynchronousEffects, [])
    }

    private func assertOrdered(
        _ fragments: [String],
        in source: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var lowerBound = source.startIndex
        for fragment in fragments {
            guard let range = source.range(of: fragment, range: lowerBound..<source.endIndex) else {
                return XCTFail("Missing or out-of-order fragment: \(fragment)", file: file, line: line)
            }
            lowerBound = range.upperBound
        }
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let testsFile = URL(fileURLWithPath: #filePath)
        let root = testsFile.deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}

private extension String {
    func slice(from start: String, to end: String) -> String? {
        guard let startRange = range(of: start),
              let endRange = range(of: end, range: startRange.lowerBound..<endIndex) else {
            return nil
        }
        return String(self[startRange.lowerBound..<endRange.upperBound])
    }
}

import XCTest
@testable import Ito

final class ReaderSessionEffectPlanTests: XCTestCase {
    func testMangaReadInvocationOrderAndRepeatedChapterSuppressionBoundary() throws {
        let source = try sourceFile("Ito/Views/Reader/ReaderView.swift")
        let function = try XCTUnwrap(source.slice(from: "func markChapterRead", to: "\n    }\n}"))

        assertOrdered(
            [
                "historyManager.addManga(",
                "guard !plan.asynchronousEffects.isEmpty else { return }",
                "markedChapterKeys.insert(chapter.key)",
                "Task {",
                "progressManager.markAsRead(",
                "trackerManager.updateProgress("
            ],
            in: function
        )
    }

    func testMangaInitialLoadMarksAfterPublishingPagesAndBeforeAdjacentPrefetch() throws {
        let source = try sourceFile("Ito/Views/Reader/ReaderView.swift")
        let function = try XCTUnwrap(source.slice(from: "func loadInitialChapter", to: "\n    }\n\n    func prefetchAdjacentChapters"))

        assertOrdered(
            ["pagedPages = sorted", "isLoaded = true", "markChapterRead(currentChapter)", "prefetchAdjacentChapters()"],
            in: function
        )
    }

    func testMangaContinuousAndCachedPagedTransitionsPreserveMutationEffectOrder() throws {
        let source = try sourceFile("Ito/Views/Reader/ReaderView.swift")
        let continuous = try XCTUnwrap(source.slice(from: "if flatPage.chapter.key != currentChapter.key", to: "prefetchContinuousImages"))
        assertOrdered(["currentChapter = flatPage.chapter", "markChapterRead(flatPage.chapter)"], in: continuous)

        let paged = try XCTUnwrap(source.slice(from: "func pagedGoToChapter", to: "\n    }\n\n    // MARK: Image Preloading"))
        assertOrdered(
            ["currentChapter = chapter", "pagedPages = cached", "pagedIndex = 0", "markChapterRead(chapter)", "prefetchAdjacentChapters()"],
            in: paged
        )

        let direct = try XCTUnwrap(source.slice(from: "func continuousGoToChapter", to: "\n    }\n\n    func pagedGoToChapter"))
        assertOrdered(
            ["currentChapter = chapter", "segments = []", "isLoaded = false", "loadInitialChapter()"],
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
        for path in [
            "Ito/Views/Reader/ReaderView.swift",
            "Ito/Views/Reader/NovelReaderView.swift"
        ] {
            let source = try sourceFile(path)
            let onAppear = try XCTUnwrap(source.slice(from: ".onAppear {", to: "\n        .onChange(of: currentChapter.key)"))
            XCTAssertTrue(onAppear.contains("resetTimer: true"), path)

            let onChange = try XCTUnwrap(source.slice(from: ".onChange(of: currentChapter.key)", to: "\n        .onDisappear"))
            XCTAssertTrue(onChange.contains("resetTimer: false"), path)

            let onDisappear = try XCTUnwrap(source.slice(from: ".onDisappear {", to: "\n        }"))
            XCTAssertTrue(onDisappear.contains("discordRPCManager.clearActivity()"), path)
        }
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

    func testReaderRenderingOwnersDoNotAdoptViewModelsOrStateObjects() throws {
        for path in [
            "Ito/Views/Reader/ReaderView.swift",
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

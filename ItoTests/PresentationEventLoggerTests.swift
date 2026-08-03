import Foundation
import XCTest
@testable import Ito

@MainActor
final class PresentationEventLoggerTests: XCTestCase {
    private let operationID = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!

    func testEventFormattingIsStable() {
        let started = PresentationLogEvent.started(
            feature: .search,
            operationID: operationID
        )
        let finished = PresentationLogEvent.finished(
            feature: .search,
            operationID: operationID,
            outcome: .failed(.pluginExecution)
        )

        XCTAssertEqual(
            PresentationLogFormatter.format(started),
            "presentation feature=search kind=operation operation_id=01234567-89ab-cdef-0123-456789abcdef phase=started outcome=none error_category=none"
        )
        XCTAssertEqual(
            PresentationLogFormatter.format(finished),
            "presentation feature=search kind=operation operation_id=01234567-89ab-cdef-0123-456789abcdef phase=finished outcome=failed error_category=plugin_execution"
        )
    }

    func testOneUUIDCorrelatesEventsForTheSameOperation() {
        let capture = PresentationEventCaptureSpy()

        capture.log(.started(feature: .search, operationID: operationID))
        capture.log(
            .finished(
                feature: .search,
                operationID: operationID,
                outcome: .succeeded
            )
        )

        XCTAssertEqual(capture.events.map(\.operationID), [operationID, operationID])
        XCTAssertTrue(capture.formattedMessages.allSatisfy {
            $0.contains(operationID.uuidString.lowercased())
        })
    }

    func testCancellationAndIgnoredStaleAreDistinctTypedOutcomes() {
        let cancelled = PresentationLogEvent.finished(
            feature: .search,
            operationID: operationID,
            outcome: .cancelled
        )
        let ignoredStale = PresentationLogEvent.finished(
            feature: .search,
            operationID: operationID,
            outcome: .ignoredStale
        )

        XCTAssertNotEqual(cancelled.outcome, ignoredStale.outcome)
        XCTAssertTrue(PresentationLogFormatter.format(cancelled).contains("outcome=cancelled"))
        XCTAssertTrue(PresentationLogFormatter.format(ignoredStale).contains("outcome=ignored_stale"))
    }

    func testPartialFailureIsAClosedTypedOutcome() {
        let partial = PresentationLogEvent.finished(
            feature: .search,
            operationID: operationID,
            outcome: .partiallySucceeded(.pluginExecution)
        )

        XCTAssertEqual(partial.outcome, .partiallySucceeded(.pluginExecution))
        XCTAssertEqual(
            PresentationLogFormatter.format(partial),
            "presentation feature=search kind=operation operation_id=01234567-89ab-cdef-0123-456789abcdef phase=finished outcome=partial_failure error_category=plugin_execution"
        )
    }

    func testPluginTrapUsesClosedPluginExecutionKindAndErrorCategory() {
        let event = PresentationLogEvent.finished(
            feature: .search,
            kind: .pluginExecution,
            operationID: operationID,
            outcome: .failed(.pluginTrap)
        )

        XCTAssertEqual(event.kind, .pluginExecution)
        XCTAssertEqual(event.outcome, .failed(.pluginTrap))
        XCTAssertEqual(
            PresentationLogFormatter.format(event),
            "presentation feature=search kind=plugin_execution operation_id=01234567-89ab-cdef-0123-456789abcdef phase=finished outcome=failed error_category=plugin_trap"
        )
    }

    func testSentinelCredentialsDoNotAppearInCapturedOrFormattedOutput() {
        assertSensitiveValueIsExcluded("username=sentinel-user password=sentinel-password token=sentinel-token")
    }

    func testSentinelSignedURLDoesNotAppearInCapturedOrFormattedOutput() {
        assertSensitiveValueIsExcluded("https://media.example/video.m3u8?signature=sentinel-signed-url")
    }

    func testSentinelRepositoryURLDoesNotAppearInCapturedOrFormattedOutput() {
        assertSensitiveValueIsExcluded("https://repo.example/sentinel-private-repository/index.json")
    }

    func testSentinelQueryAndMediaTitleDoNotAppearInCapturedOrFormattedOutput() {
        assertSensitiveValueIsExcluded("query=sentinel-query title=sentinel-media-title")
    }

    func testSentinelBackupPayloadDoesNotAppearInCapturedOrFormattedOutput() {
        assertSensitiveValueIsExcluded("backup_payload={sentinel-private-backup-fragment}")
    }

    func testEventSchemaUsesAnExactStoredFieldAllowlist() {
        let event = PresentationLogEvent.finished(
            feature: .search,
            kind: .pluginExecution,
            operationID: operationID,
            outcome: .failed(.pluginTrap)
        )

        let storedFieldNames = Mirror(reflecting: event).children.compactMap(\.label)
        XCTAssertEqual(
            storedFieldNames,
            ["feature", "kind", "operationID", "phase", "outcome"]
        )
    }

    func testFormattedOutputUsesAnExactKeyAllowlist() {
        let event = PresentationLogEvent.finished(
            feature: .search,
            kind: .pluginExecution,
            operationID: operationID,
            outcome: .failed(.pluginTrap)
        )
        let components = PresentationLogFormatter.format(event).split(separator: " ")
        let formattedKeys = components.dropFirst().compactMap { component in
            component.split(separator: "=", maxSplits: 1).first.map(String.init)
        }

        XCTAssertEqual(components.first, "presentation")
        XCTAssertEqual(
            formattedKeys,
            ["feature", "kind", "operation_id", "phase", "outcome", "error_category"]
        )
    }

    func testCaptureSpyImplementsContractWithoutCallingAppLogger() {
        let capture: any PresentationEventLogging = PresentationEventCaptureSpy()

        capture.log(.started(feature: .search, operationID: operationID))

        guard let capture = capture as? PresentationEventCaptureSpy else {
            return XCTFail("Expected capture spy")
        }
        XCTAssertEqual(capture.events.count, 1)
    }

    private func assertSensitiveValueIsExcluded(
        _ sensitiveValue: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let capture = PresentationEventCaptureSpy()
        let events: [PresentationLogEvent] = [
            .started(feature: .search, operationID: operationID),
            .finished(
                feature: .search,
                operationID: operationID,
                outcome: .succeeded
            ),
            .finished(
                feature: .search,
                operationID: operationID,
                outcome: .failed(.pluginUnavailable)
            ),
            .finished(
                feature: .search,
                operationID: operationID,
                outcome: .cancelled
            ),
            .finished(
                feature: .search,
                operationID: operationID,
                outcome: .ignoredStale
            )
        ]
        for event in events {
            capture.log(event)
        }

        let capturedOutput = String(reflecting: capture.events)
        let formattedOutput = capture.formattedMessages.joined(separator: "\n")
        XCTAssertFalse(capturedOutput.contains(sensitiveValue), file: file, line: line)
        XCTAssertFalse(formattedOutput.contains(sensitiveValue), file: file, line: line)
    }

}

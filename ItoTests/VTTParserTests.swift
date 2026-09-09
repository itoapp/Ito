import XCTest
@testable import Ito

@MainActor
final class VTTParserTests: XCTestCase {
    func testHeaderCueIdentifierHoursMinutesSecondsAndMultilineText() {
        let input = """
        WEBVTT

        cue-1
        00:01:02.500 --> 00:01:05.750
        First line
        Second <i>line</i>
        """

        let cues = VTTParser.parse(input)

        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].start, 62.5, accuracy: 0.000_001)
        XCTAssertEqual(cues[0].end, 65.75, accuracy: 0.000_001)
        XCTAssertEqual(cues[0].text, "First line\nSecond line")
    }

    func testMinuteTimestampCommaMillisecondsSettingsAndCRLFAreAccepted() {
        let input = "WEBVTT\r\n\r\n01:02,250  -->  01:04,500 line:20% position:10%\r\n  Text  \r\n"

        let cues = VTTParser.parse(input)

        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].start, 62.25, accuracy: 0.000_001)
        XCTAssertEqual(cues[0].end, 64.5, accuracy: 0.000_001)
        XCTAssertEqual(cues[0].text, "Text")
    }

    func testAdjacentCuesWithoutBlankLineFlushInInputOrder() {
        let input = """
        00:00:01.000 --> 00:00:02.000
        One
        00:00:03.000 --> 00:00:04.000
        Two
        """

        let cues = VTTParser.parse(input)

        XCTAssertEqual(cues.map(\.text), ["One", "Two"])
        XCTAssertEqual(cues.map(\.start), [1, 3])
        XCTAssertEqual(cues.map(\.end), [2, 4])
    }

    func testBlankLinesAndEmptyCueTextProduceNoCue() {
        let input = """
        WEBVTT


        00:00:01.000 --> 00:00:02.000

        00:00:03.000 --> 00:00:04.000
        Kept

        """

        let cues = VTTParser.parse(input)

        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].text, "Kept")
    }

    func testMalformedTimestampComponentsBecomeZeroRatherThanRejectingCue() {
        let input = """
        bad:time:value --> also:bad
        Preserved
        """

        let cues = VTTParser.parse(input)

        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].start, 0)
        XCTAssertEqual(cues[0].end, 0)
        XCTAssertEqual(cues[0].text, "Preserved")
    }

    func testMalformedArrowLineIsIgnoredWhenNotReadingCue() {
        let input = """
        WEBVTT

        00:00:01.000 --> 00:00:02.000 --> 00:00:03.000
        Ignored text

        00:00:04.000 --> 00:00:05.000
        Kept
        """

        let cues = VTTParser.parse(input)

        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].start, 4)
        XCTAssertEqual(cues[0].end, 5)
        XCTAssertEqual(cues[0].text, "Kept")
    }

    func testMalformedArrowWhileReadingFlushesThenReusesPreviousTiming() {
        let input = """
        00:00:01.000 --> 00:00:02.000
        First
        00:00:03.000 --> 00:00:04.000 --> 00:00:05.000
        Attached to prior timing

        """

        let cues = VTTParser.parse(input)

        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues.map(\.start), [1, 1])
        XCTAssertEqual(cues.map(\.end), [2, 2])
        XCTAssertEqual(cues.map(\.text), ["First", "Attached to prior timing"])
    }

    func testMetadataAndCommentBlocksOutsideCueAreIgnored() {
        let input = """
        WEBVTT Kind: captions

        NOTE this is metadata
        another note line

        STYLE
        ::cue { color: lime }

        00:00:01.000 --> 00:00:02.000
        Caption
        """

        let cues = VTTParser.parse(input)

        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].text, "Caption")
    }

    func testTrailingNewlineAndNoTrailingNewlineHaveEquivalentOutput() {
        let base = "00:00:01.000 --> 00:00:02.000\nCaption"

        let withoutTrailing = VTTParser.parse(base)
        let withTrailing = VTTParser.parse(base + "\n")

        XCTAssertEqual(withoutTrailing.count, withTrailing.count)
        XCTAssertEqual(withoutTrailing.first?.start, withTrailing.first?.start)
        XCTAssertEqual(withoutTrailing.first?.end, withTrailing.first?.end)
        XCTAssertEqual(withoutTrailing.first?.text, withTrailing.first?.text)
    }
}

import Foundation

nonisolated struct VTTCue: Equatable, Sendable {
    let start: Double
    let end: Double
    let text: String
}

nonisolated enum VTTParser {
    static func parse(_ vtt: String) -> [VTTCue] {
        var results: [VTTCue] = []
        let cleanVTT = vtt.replacingOccurrences(of: "\r", with: "")
        let lines = cleanVTT.components(separatedBy: "\n")
        var currentStart: Double = 0
        var currentEnd: Double = 0
        var currentText = ""
        var isReadingText = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("-->") {
                if isReadingText {
                    appendCue(
                        start: currentStart,
                        end: currentEnd,
                        text: currentText,
                        to: &results
                    )
                    currentText = ""
                }

                let parts = trimmed.components(separatedBy: "-->")
                if parts.count == 2 {
                    let startString = parts[0]
                        .trimmingCharacters(in: .whitespaces)
                        .components(separatedBy: .whitespaces)
                        .first ?? ""
                    let endString = parts[1]
                        .trimmingCharacters(in: .whitespaces)
                        .components(separatedBy: .whitespaces)
                        .first ?? ""
                    currentStart = parseTime(startString)
                    currentEnd = parseTime(endString)
                    isReadingText = true
                }
            } else if trimmed.isEmpty {
                if isReadingText {
                    appendCue(
                        start: currentStart,
                        end: currentEnd,
                        text: currentText,
                        to: &results
                    )
                    currentText = ""
                    isReadingText = false
                }
            } else if isReadingText {
                let stripped = trimmed.replacingOccurrences(
                    of: "<[^>]+>",
                    with: "",
                    options: .regularExpression,
                    range: nil
                )
                if currentText.isEmpty {
                    currentText = stripped
                } else {
                    currentText += "\n" + stripped
                }
            }
        }

        if isReadingText {
            appendCue(
                start: currentStart,
                end: currentEnd,
                text: currentText,
                to: &results
            )
        }
        return results
    }

    private static func appendCue(
        start: Double,
        end: Double,
        text: String,
        to results: inout [VTTCue]
    ) {
        let cleanedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanedText.isEmpty {
            results.append(VTTCue(start: start, end: end, text: cleanedText))
        }
    }

    private static func parseTime(_ timeString: String) -> Double {
        let parts = timeString.components(separatedBy: ":")
        var seconds: Double = 0
        if parts.count == 3 {
            seconds += (Double(parts[0]) ?? 0) * 3600
            seconds += (Double(parts[1]) ?? 0) * 60
            seconds += Double(
                parts[2].replacingOccurrences(of: ",", with: ".")
            ) ?? 0
        } else if parts.count == 2 {
            seconds += (Double(parts[0]) ?? 0) * 60
            seconds += Double(
                parts[1].replacingOccurrences(of: ",", with: ".")
            ) ?? 0
        }
        return seconds
    }
}

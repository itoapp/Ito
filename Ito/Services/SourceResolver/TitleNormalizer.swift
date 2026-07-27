import Foundation

public struct TitleNormalizer: Sendable {
    public nonisolated static func normalize(_ input: String) -> String {
        let folded = input.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US"))

        let compatible = folded.precomposedStringWithCompatibilityMapping

        let scalarSpaces = compatible.unicodeScalars.map { scalar -> Unicode.Scalar in
            if CharacterSet.punctuationCharacters.contains(scalar) || CharacterSet.symbols.contains(scalar) {
                return Unicode.Scalar(32)
            }
            return scalar
        }

        let noPunctuation = String(String.UnicodeScalarView(scalarSpaces))

        let components = noPunctuation.components(separatedBy: CharacterSet.whitespacesAndNewlines)
        let collapsed = components.filter { !$0.isEmpty }.joined(separator: " ")

        return collapsed
    }
}

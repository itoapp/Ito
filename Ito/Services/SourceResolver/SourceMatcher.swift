import Foundation

public struct SourceMatcher: Sendable {
    public nonisolated static func evaluate(
        canonical: CanonicalTitleInput,
        candidates: [PluginCandidateInput],
        rejectedPluginMediaKeys: Set<String>
    ) -> [ScoredCandidate] {
        var rawScores: [(candidate: PluginCandidateInput, score: Double, method: MatchMethod)] = []

        let normPreferred = TitleNormalizer.normalize(canonical.preferredTitle)

        var altTitles: Set<String> = []
        if let english = canonical.titleEnglish { altTitles.insert(TitleNormalizer.normalize(english)) }
        if let romaji = canonical.titleRomaji { altTitles.insert(TitleNormalizer.normalize(romaji)) }
        if let native = canonical.titleNative { altTitles.insert(TitleNormalizer.normalize(native)) }
        for syn in canonical.synonyms { altTitles.insert(TitleNormalizer.normalize(syn)) }

        // Remove empty strings
        altTitles.remove("")

        for candidate in candidates {
            if candidate.mediaType != canonical.mediaType {
                rawScores.append((candidate, 0.0, .none))
                continue
            }

            let normCandidate = TitleNormalizer.normalize(candidate.title)

            if normCandidate.isEmpty {
                rawScores.append((candidate, 0.0, .none))
                continue
            }

            if normPreferred == normCandidate && !normPreferred.isEmpty {
                rawScores.append((candidate, 1.0, .exactPreferred))
                continue
            }

            if altTitles.contains(normCandidate) {
                rawScores.append((candidate, 0.98, .exactAlternative))
                continue
            }

            var bestFuzzy = 0.0
            if !normPreferred.isEmpty {
                bestFuzzy = max(bestFuzzy, JaroWinkler.distance(normPreferred, normCandidate))
            }
            for alt in altTitles {
                if !alt.isEmpty {
                    bestFuzzy = max(bestFuzzy, JaroWinkler.distance(alt, normCandidate))
                }
            }

            // Fuzzy scores must be capped below automatic-confirmation territory
            bestFuzzy = min(bestFuzzy, 0.97)

            if bestFuzzy >= 0.80 {
                rawScores.append((candidate, bestFuzzy, .fuzzy))
            } else {
                rawScores.append((candidate, bestFuzzy, .none))
            }
        }

        let exactCount = rawScores.filter { $0.method == .exactPreferred || $0.method == .exactAlternative }.count

        // Sort to determine margin
        let sortedDesc = rawScores.sorted { $0.score > $1.score }

        var results: [ScoredCandidate] = []

        for item in rawScores {
            if item.method == .none || item.score < 0.80 {
                results.append(ScoredCandidate(candidate: item.candidate, method: item.method, score: item.score, decision: .discard))
                continue
            }

            if item.method == .fuzzy {
                results.append(ScoredCandidate(candidate: item.candidate, method: item.method, score: item.score, decision: .requiresConfirmation))
                continue
            }

            // Exact method
            if rejectedPluginMediaKeys.contains(item.candidate.pluginMediaKey) {
                results.append(ScoredCandidate(candidate: item.candidate, method: item.method, score: item.score, decision: .requiresConfirmation))
                continue
            }

            if exactCount > 1 {
                results.append(ScoredCandidate(candidate: item.candidate, method: item.method, score: item.score, decision: .requiresConfirmation))
                continue
            }

            // Margin check
            var hasMargin = true
            if sortedDesc.count > 1 {
                let secondBest = sortedDesc[1]
                if item.score - secondBest.score < 0.08 {
                    hasMargin = false
                }
            }

            if hasMargin {
                results.append(ScoredCandidate(candidate: item.candidate, method: item.method, score: item.score, decision: .autoConfirm))
            } else {
                results.append(ScoredCandidate(candidate: item.candidate, method: item.method, score: item.score, decision: .requiresConfirmation))
            }
        }

        // Deterministic ordering
        results.sort { a, b in
            if abs(a.score - b.score) > 0.000001 {
                return a.score > b.score
            }

            let isExactA = (a.method == .exactPreferred || a.method == .exactAlternative)
            let isExactB = (b.method == .exactPreferred || b.method == .exactAlternative)

            if isExactA != isExactB {
                return isExactA
            }

            let normA = TitleNormalizer.normalize(a.candidate.title)
            let normB = TitleNormalizer.normalize(b.candidate.title)

            if normA != normB {
                return normA < normB
            }

            return a.candidate.pluginMediaKey < b.candidate.pluginMediaKey
        }

        return results
    }
}

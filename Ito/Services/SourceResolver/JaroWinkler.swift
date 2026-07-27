import Foundation

public struct JaroWinkler: Sendable {
    public nonisolated static func distance(_ s1: String, _ s2: String) -> Double {
        let len1 = s1.count
        let len2 = s2.count

        if len1 == 0 && len2 == 0 { return 1.0 }
        if len1 == 0 || len2 == 0 { return 0.0 }
        if s1 == s2 { return 1.0 }

        let matchDistance = max(len1, len2) / 2 - 1

        var s1Matches = [Bool](repeating: false, count: len1)
        var s2Matches = [Bool](repeating: false, count: len2)

        let s1Array = Array(s1)
        let s2Array = Array(s2)

        var matches = 0

        for i in 0..<len1 {
            let start = max(0, i - matchDistance)
            let end = min(len2 - 1, i + matchDistance)

            if start <= end {
                for j in start...end {
                    if s2Matches[j] { continue }
                    if s1Array[i] == s2Array[j] {
                        s1Matches[i] = true
                        s2Matches[j] = true
                        matches += 1
                        break
                    }
                }
            }
        }

        if matches == 0 { return 0.0 }

        var t = 0
        var point = 0

        for i in 0..<len1 {
            if s1Matches[i] {
                while !s2Matches[point] {
                    point += 1
                }
                if s1Array[i] != s2Array[point] {
                    t += 1
                }
                point += 1
            }
        }

        t /= 2

        let m = Double(matches)
        let jaro = (m / Double(len1) + m / Double(len2) + (m - Double(t)) / m) / 3.0

        var prefix = 0
        for i in 0..<min(4, min(len1, len2)) {
            if s1Array[i] == s2Array[i] {
                prefix += 1
            } else {
                break
            }
        }

        let jaroWinkler = jaro + (Double(prefix) * 0.1 * (1.0 - jaro))

        return jaroWinkler
    }
}

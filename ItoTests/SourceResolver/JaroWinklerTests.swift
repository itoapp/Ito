import Testing
@testable import Ito

struct JaroWinklerTests {
    @Test func identicalStrings() async {
        #expect(JaroWinkler.distance("MARTHA", "MARTHA") == 1.0)
    }

    @Test func completelyDifferentStrings() async {
        #expect(JaroWinkler.distance("ABC", "XYZ") == 0.0)
    }

    @Test func knownReferencePairs() async {
        let distance = JaroWinkler.distance("MARTHA", "MARHTA")
        #expect(distance > 0.96 && distance < 0.97)
    }

    @Test func emptyValues() async {
        #expect(JaroWinkler.distance("", "") == 1.0)
        #expect(JaroWinkler.distance("A", "") == 0.0)
        #expect(JaroWinkler.distance("", "B") == 0.0)
    }

    @Test func symmetry() async {
        let d1 = JaroWinkler.distance("DWAYNE", "DUANE")
        let d2 = JaroWinkler.distance("DUANE", "DWAYNE")
        #expect(d1 == d2)
    }

    @Test func scoreBounds() async {
        let distance = JaroWinkler.distance("CRATE", "TRACE")
        #expect(distance >= 0.0 && distance <= 1.0)
    }
}

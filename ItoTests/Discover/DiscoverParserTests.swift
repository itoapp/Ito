import Testing
@testable import Ito

struct DiscoverParserTests {
    @Test func parseCompleteMedia() async throws {
        let service = DiscoverService.shared
        let dict: [String: Any] = [
            "id": 1,
            "title": [
                "english": "English Title",
                "romaji": "Romaji Title",
                "native": "Native Title"
            ],
            "synonyms": ["Syn 1", "Syn 2"]
        ]

        let media = try await #require(service.parseMedia(dict))
        #expect(media.titleEnglish == "English Title")
        #expect(media.titleRomaji == "Romaji Title")
        #expect(media.titleNative == "Native Title")
        #expect(media.title == "English Title")
        #expect(media.synonyms == ["Syn 1", "Syn 2"])
    }

    @Test func parseMissingEnglish() async throws {
        let service = DiscoverService.shared
        let dict: [String: Any] = [
            "id": 2,
            "title": [
                "romaji": "Romaji",
                "native": "Native"
            ]
        ]

        let media = try await #require(service.parseMedia(dict))
        #expect(media.titleEnglish == nil)
        #expect(media.title == "Romaji")
        #expect(media.synonyms.isEmpty)
    }

    @Test func parseOnlyNative() async throws {
        let service = DiscoverService.shared
        let dict: [String: Any] = [
            "id": 3,
            "title": [
                "native": "Native"
            ]
        ]
        let media = try await #require(service.parseMedia(dict))
        #expect(media.title == "Native")
    }
    @Test func parseNestedRecommendations() async throws {
        let service = DiscoverService.shared
        let dict: [String: Any] = [
            "id": 1,
            "title": ["english": "Main English"],
            "recommendations": [
                "nodes": [
                    [
                        "mediaRecommendation": [
                            "id": 2,
                            "title": [
                                "english": "Rec English",
                                "romaji": "Rec Romaji",
                                "native": "Rec Native"
                            ],
                            "synonyms": ["Rec Syn"]
                        ]
                    ]
                ]
            ]
        ]

        let media = try await #require(service.parseMedia(dict))
        let recommendations = try #require(media.recommendations)
        #expect(recommendations.count == 1)

        let rec = recommendations[0]
        #expect(rec.titleEnglish == "Rec English")
        #expect(rec.titleRomaji == "Rec Romaji")
        #expect(rec.titleNative == "Rec Native")
        #expect(rec.title == "Rec English")
        #expect(rec.synonyms == ["Rec Syn"])
    }
}

import Foundation

enum DiscoverHomeSection: Hashable, Sendable {
    case trending
    case popular
    case topRated
    case seasonal
}

struct DiscoverHomeSectionRequest: Equatable, Sendable {
    let section: DiscoverHomeSection
    let mediaType: DiscoverMediaType
    let season: String?
    let seasonYear: Int?
    let perPage: Int
}

struct DiscoverSearchRequest: Equatable, Sendable {
    let query: String
    let mediaType: DiscoverMediaType
    let filters: DiscoverFilters
    let page: Int
    let perPage: Int
}

struct DiscoverPageResult: Equatable, Sendable {
    let media: [DiscoverMedia]
    let hasNextPage: Bool
}

@MainActor
protocol DiscoverHomeFilterServing: AnyObject, Sendable {
    func loadHomeSection(
        _ request: DiscoverHomeSectionRequest
    ) async throws -> [DiscoverMedia]

    func search(_ request: DiscoverSearchRequest) async throws -> DiscoverPageResult
    func loadGenres() async throws -> [String]
    func loadTags() async throws -> [DiscoverTag]
}

@MainActor
protocol DiscoverClock: AnyObject, Sendable {
    var now: Date { get }
    func sleep(milliseconds: Int) async throws
}

@MainActor
final class SystemDiscoverClock: DiscoverClock {
    var now: Date { Date() }

    func sleep(milliseconds: Int) async throws {
        try await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
    }
}

@MainActor
protocol DiscoverCaching: AnyObject, Sendable {
    func homeMedia(
        section: DiscoverHomeSection,
        mediaType: DiscoverMediaType,
        now: Date,
        lifetime: TimeInterval
    ) -> [DiscoverMedia]?

    func storeHomeMedia(
        _ media: [DiscoverMedia],
        section: DiscoverHomeSection,
        mediaType: DiscoverMediaType,
        at timestamp: Date
    )

    func removeHomeMedia(for mediaType: DiscoverMediaType)

    func genres(now: Date, lifetime: TimeInterval) -> [String]?
    func storeGenres(_ genres: [String], at timestamp: Date)
    func tags(now: Date, lifetime: TimeInterval) -> [DiscoverTag]?
    func storeTags(_ tags: [DiscoverTag], at timestamp: Date)
}

@MainActor
final class InMemoryDiscoverCache: DiscoverCaching {
    private struct HomeKey: Hashable {
        let section: DiscoverHomeSection
        let mediaType: DiscoverMediaType
    }

    private struct Entry<Value> {
        let value: Value
        let timestamp: Date
    }

    private var homeEntries: [HomeKey: Entry<[DiscoverMedia]>] = [:]
    private var genresEntry: Entry<[String]>?
    private var tagsEntry: Entry<[DiscoverTag]>?

    func homeMedia(
        section: DiscoverHomeSection,
        mediaType: DiscoverMediaType,
        now: Date,
        lifetime: TimeInterval
    ) -> [DiscoverMedia]? {
        freshValue(
            homeEntries[HomeKey(section: section, mediaType: mediaType)],
            now: now,
            lifetime: lifetime
        )
    }

    func storeHomeMedia(
        _ media: [DiscoverMedia],
        section: DiscoverHomeSection,
        mediaType: DiscoverMediaType,
        at timestamp: Date
    ) {
        homeEntries[HomeKey(section: section, mediaType: mediaType)] = Entry(
            value: media,
            timestamp: timestamp
        )
    }

    func removeHomeMedia(for mediaType: DiscoverMediaType) {
        for section in [
            DiscoverHomeSection.trending,
            .popular,
            .topRated,
            .seasonal
        ] {
            homeEntries.removeValue(
                forKey: HomeKey(section: section, mediaType: mediaType)
            )
        }
    }

    func genres(now: Date, lifetime: TimeInterval) -> [String]? {
        freshValue(genresEntry, now: now, lifetime: lifetime)
    }

    func storeGenres(_ genres: [String], at timestamp: Date) {
        genresEntry = Entry(value: genres, timestamp: timestamp)
    }

    func tags(now: Date, lifetime: TimeInterval) -> [DiscoverTag]? {
        freshValue(tagsEntry, now: now, lifetime: lifetime)
    }

    func storeTags(_ tags: [DiscoverTag], at timestamp: Date) {
        tagsEntry = Entry(value: tags, timestamp: timestamp)
    }

    private func freshValue<Value>(
        _ entry: Entry<Value>?,
        now: Date,
        lifetime: TimeInterval
    ) -> Value? {
        guard let entry,
              now.timeIntervalSince(entry.timestamp) <= lifetime else {
            return nil
        }
        return entry.value
    }
}

extension DiscoverManager: DiscoverHomeFilterServing {
    func loadHomeSection(
        _ request: DiscoverHomeSectionRequest
    ) async throws -> [DiscoverMedia] {
        try await loadUncachedHomeSection(request)
    }

    func search(_ request: DiscoverSearchRequest) async throws -> DiscoverPageResult {
        let result = try await search(
            query: request.query,
            type: request.mediaType,
            filters: request.filters,
            page: request.page,
            perPage: request.perPage
        )
        return DiscoverPageResult(
            media: result.media,
            hasNextPage: result.hasNextPage
        )
    }

    func loadGenres() async throws -> [String] {
        try await loadUncachedGenres()
    }

    func loadTags() async throws -> [DiscoverTag] {
        try await loadUncachedTags()
    }
}

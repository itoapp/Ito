import Foundation
import Combine

// MARK: - Cache Entry

private struct CacheEntry<T: Sendable>: Sendable {
    let data: T
    let timestamp: Date

    var isExpired: Bool {
        Date().timeIntervalSince(timestamp) > 300 // 5 minutes
    }
}

// MARK: - DiscoverManager

@MainActor
public class DiscoverManager: ObservableObject {
    public static let shared = DiscoverManager()

    @Published public var trendingAnime: [DiscoverMedia] = []
    @Published public var trendingManga: [DiscoverMedia] = []
    @Published public var popularAnime: [DiscoverMedia] = []
    @Published public var popularManga: [DiscoverMedia] = []
    @Published public var topRatedAnime: [DiscoverMedia] = []
    @Published public var topRatedManga: [DiscoverMedia] = []
    @Published public var seasonalAnime: [DiscoverMedia] = []

    @Published public var availableGenres: [String] = []
    @Published public var availableTags: [DiscoverTag] = []

    @Published public var isLoadingHome = false

    private var sectionCache: [String: CacheEntry<[DiscoverMedia]>] = [:]
    private var genresCache: CacheEntry<[String]>?
    private var tagsCache: CacheEntry<[DiscoverTag]>?

    private let service = DiscoverService.shared

    private init() {}

    public func clearCache(for type: DiscoverMediaType) {
        let keys = ["trending_\(type.rawValue)", "popular_\(type.rawValue)", "topRated_\(type.rawValue)"]
        for key in keys { sectionCache.removeValue(forKey: key) }
        if type == .anime { sectionCache.removeValue(forKey: "seasonal_anime") }
    }

    // MARK: - Home Sections

    public func loadHomeSections(for type: DiscoverMediaType) async {
        await MainActor.run { isLoadingHome = true }

        async let trending = fetchSection(type: type, sort: .trending, cacheKey: "trending_\(type.rawValue)")
        async let popular = fetchSection(type: type, sort: .popularity, cacheKey: "popular_\(type.rawValue)")
        async let topRated = fetchSection(type: type, sort: .score, cacheKey: "topRated_\(type.rawValue)")

        let (t, p, tr) = await (trending, popular, topRated)

        if type == .anime {
            let seasonal = await fetchSeasonal()
            await MainActor.run {
                self.trendingAnime = t
                self.popularAnime = p
                self.topRatedAnime = tr
                self.seasonalAnime = seasonal
                self.isLoadingHome = false
            }
        } else {
            await MainActor.run {
                self.trendingManga = t
                self.popularManga = p
                self.topRatedManga = tr
                self.isLoadingHome = false
            }
        }
    }

    private func fetchSection(type: DiscoverMediaType, sort: DiscoverSort, cacheKey: String) async -> [DiscoverMedia] {
        if let cached = sectionCache[cacheKey], !cached.isExpired {
            return cached.data
        }
        do {
            let results = try await service.queryMedia(type: type, sort: sort, perPage: 20)
            sectionCache[cacheKey] = CacheEntry(data: results, timestamp: Date())
            return results
        } catch {
            print("[DiscoverManager] fetchSection(\(cacheKey)) failed: \(error)")
            return []
        }
    }

    public func fetchSeasonal() async -> [DiscoverMedia] {
        let cacheKey = "seasonal_anime"
        if let cached = sectionCache[cacheKey], !cached.isExpired {
            return cached.data
        }
        let (season, year) = currentSeason()
        do {
            let results = try await service.queryMedia(type: .anime, sort: .popularity, season: season, seasonYear: year, perPage: 20)
            sectionCache[cacheKey] = CacheEntry(data: results, timestamp: Date())
            return results
        } catch {
            print("[DiscoverManager] fetchSeasonal failed: \(error)")
            return []
        }
    }

    // MARK: - Search

    public func search(query: String, type: DiscoverMediaType, filters: DiscoverFilters = DiscoverFilters(), page: Int = 1) async throws -> (media: [DiscoverMedia], hasNextPage: Bool) {
        let sort: DiscoverSort = query.isEmpty ? filters.sort : .searchMatch
        return try await service.queryMediaPaginated(
            type: type, sort: sort,
            season: filters.season,
            seasonYear: filters.year,
            search: query.isEmpty ? nil : query,
            genres: filters.genres.isEmpty ? nil : filters.genres,
            excludedGenres: filters.excludedGenres.isEmpty ? nil : filters.excludedGenres,
            tags: filters.tags.isEmpty ? nil : filters.tags,
            excludedTags: filters.excludedTags.isEmpty ? nil : filters.excludedTags,
            format: filters.format, status: filters.status,
            countryOfOrigin: filters.countryOfOrigin,
            page: page, perPage: 20
        )
    }

    // MARK: - Genre & Tag Collections

    public func loadGenresAndTags() async {
        async let g = fetchGenres()
        async let t = fetchTags()
        let (genres, tags) = await (g, t)
        await MainActor.run {
            self.availableGenres = genres
            self.availableTags = tags.filter { $0.isAdult != true }
        }
    }

    private func fetchGenres() async -> [String] {
        if let cached = genresCache, !cached.isExpired { return cached.data }
        do {
            let filtered = try await service.fetchGenres()
            genresCache = CacheEntry(data: filtered, timestamp: Date())
            return filtered
        } catch { return [] }
    }

    private func fetchTags() async -> [DiscoverTag] {
        if let cached = tagsCache, !cached.isExpired { return cached.data }
        do {
            let tags = try await service.fetchTags()
            tagsCache = CacheEntry(data: tags, timestamp: Date())
            return tags
        } catch { return [] }
    }

    // MARK: - Single Media Detail

    public func fetchMediaDetails(id: Int) async throws -> DiscoverMedia? {
        return try await service.fetchMediaDetails(id: id)
    }

    // MARK: - Helpers

    private func currentSeason() -> (String, Int) {
        let calendar = Calendar.current
        let now = Date()
        let month = calendar.component(.month, from: now)
        let year = calendar.component(.year, from: now)

        let season: String
        switch month {
        case 1...3: season = "WINTER"
        case 4...6: season = "SPRING"
        case 7...9: season = "SUMMER"
        default: season = "FALL"
        }
        return (season, year)
    }
}

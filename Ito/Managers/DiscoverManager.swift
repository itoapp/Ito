import Foundation
import Combine

// MARK: - Models

struct DiscoverMedia: Identifiable, Codable, Hashable, Sendable {
    let id: Int
    let title: String
    let titleRomaji: String?
    let coverImage: String?
    let bannerImage: String?
    let format: String?
    let status: String?
    let description: String?
    let cleanDescription: String?
    let genres: [String]?
    let averageScore: Int?
    let episodes: Int?
    let chapters: Int?
    let season: String?
    let seasonYear: Int?
    let type: String
    let recommendations: [DiscoverMedia]?
}

struct DiscoverTag: Identifiable, Codable, Hashable, Sendable {
    let id: Int
    let name: String
    let description: String?
    let category: String?
    let isAdult: Bool?
}

enum DiscoverMediaType: String, CaseIterable {
    case anime = "ANIME"
    case manga = "MANGA"
}

enum DiscoverSort: String, CaseIterable {
    case trending = "TRENDING_DESC"
    case popularity = "POPULARITY_DESC"
    case score = "SCORE_DESC"
    case newest = "START_DATE_DESC"
    case searchMatch = "SEARCH_MATCH"

    var displayName: String {
        switch self {
        case .trending: return "Trending"
        case .popularity: return "Popular"
        case .score: return "Top Rated"
        case .newest: return "Newest"
        case .searchMatch: return "Best Match"
        }
    }
}

struct DiscoverFilters: Equatable, Sendable {
    var genres: [String] = []
    var tags: [String] = []
    var format: String?
    var status: String?
    var countryOfOrigin: String?
    var sort: DiscoverSort = .popularity

    var isEmpty: Bool {
        genres.isEmpty && tags.isEmpty && format == nil && status == nil && countryOfOrigin == nil
    }
}

// MARK: - Cache Entry

private struct CacheEntry<T> {
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

    @Published var trendingAnime: [DiscoverMedia] = []
    @Published var trendingManga: [DiscoverMedia] = []
    @Published var popularAnime: [DiscoverMedia] = []
    @Published var popularManga: [DiscoverMedia] = []
    @Published var topRatedAnime: [DiscoverMedia] = []
    @Published var topRatedManga: [DiscoverMedia] = []
    @Published var seasonalAnime: [DiscoverMedia] = []

    @Published var availableGenres: [String] = []
    @Published var availableTags: [DiscoverTag] = []

    @Published var isLoadingHome = false

    private var sectionCache: [String: CacheEntry<[DiscoverMedia]>] = [:]
    private var genresCache: CacheEntry<[String]>?
    private var tagsCache: CacheEntry<[DiscoverTag]>?

    private let apiURL = URL(string: "https://graphql.anilist.co")!

    private init() {}

    func clearCache(for type: DiscoverMediaType) {
        let keys = ["trending_\(type.rawValue)", "popular_\(type.rawValue)", "topRated_\(type.rawValue)"]
        for key in keys { sectionCache.removeValue(forKey: key) }
        if type == .anime { sectionCache.removeValue(forKey: "seasonal_anime") }
    }

    // MARK: - Home Sections

    func loadHomeSections(for type: DiscoverMediaType) async {
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
            let results = try await queryMedia(type: type, sort: sort, perPage: 20)
            sectionCache[cacheKey] = CacheEntry(data: results, timestamp: Date())
            return results
        } catch {
            print("[DiscoverManager] fetchSection(\(cacheKey)) failed: \(error)")
            return []
        }
    }

    private func fetchSeasonal() async -> [DiscoverMedia] {
        let cacheKey = "seasonal_anime"
        if let cached = sectionCache[cacheKey], !cached.isExpired {
            return cached.data
        }
        let (season, year) = currentSeason()
        do {
            let results = try await queryMedia(type: .anime, sort: .popularity, season: season, seasonYear: year, perPage: 20)
            sectionCache[cacheKey] = CacheEntry(data: results, timestamp: Date())
            return results
        } catch {
            print("[DiscoverManager] fetchSeasonal failed: \(error)")
            return []
        }
    }

    // MARK: - Search

    func search(query: String, type: DiscoverMediaType, filters: DiscoverFilters = DiscoverFilters(), page: Int = 1) async throws -> (media: [DiscoverMedia], hasNextPage: Bool) {
        let sort: DiscoverSort = query.isEmpty ? filters.sort : .searchMatch
        return try await queryMediaPaginated(
            type: type, sort: sort, search: query.isEmpty ? nil : query,
            genres: filters.genres.isEmpty ? nil : filters.genres,
            tags: filters.tags.isEmpty ? nil : filters.tags,
            format: filters.format, status: filters.status,
            countryOfOrigin: filters.countryOfOrigin,
            page: page, perPage: 20
        )
    }

    // MARK: - Genre & Tag Collections

    func loadGenresAndTags() async {
        async let g = fetchGenres()
        async let t = fetchTags()
        let (genres, tags) = await (g, t)
        await MainActor.run {
            self.availableGenres = genres
            self.availableTags = tags.filter { $0.isAdult != true }
        }
    }

    private func fetchGenres() async -> [String] {
        if let cached = genresCache, !cached.isExpired {
            return cached.data
        }
        do {
            let body: [String: Any] = ["query": "query { GenreCollection }"]
            let data = try await performRequest(body: body)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataDict = json["data"] as? [String: Any],
               let genres = dataDict["GenreCollection"] as? [String] {
                let filtered = genres.filter { $0 != "Hentai" }
                genresCache = CacheEntry(data: filtered, timestamp: Date())
                return filtered
            }
        } catch {
            print("[DiscoverManager] fetchGenres failed: \(error)")
        }
        return []
    }

    private func fetchTags() async -> [DiscoverTag] {
        if let cached = tagsCache, !cached.isExpired {
            return cached.data
        }
        do {
            let query = "query { MediaTagCollection { id name description category isAdult } }"
            let body: [String: Any] = ["query": query]
            let data = try await performRequest(body: body)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataDict = json["data"] as? [String: Any],
               let tagList = dataDict["MediaTagCollection"] as? [[String: Any]] {
                let tags = tagList.compactMap { dict -> DiscoverTag? in
                    guard let id = dict["id"] as? Int,
                          let name = dict["name"] as? String else { return nil }
                    return DiscoverTag(
                        id: id, name: name,
                        description: dict["description"] as? String,
                        category: dict["category"] as? String,
                        isAdult: dict["isAdult"] as? Bool
                    )
                }
                tagsCache = CacheEntry(data: tags, timestamp: Date())
                return tags
            }
        } catch {
            print("[DiscoverManager] fetchTags failed: \(error)")
        }
        return []
    }

    // MARK: - Single Media Detail

    func fetchMediaDetails(id: Int) async throws -> DiscoverMedia? {
        let graphqlQuery = """
        query ($id: Int) {
          Media(id: $id) {
            id
            title { english romaji native }
            coverImage { large extraLarge }
            bannerImage
            format status
            description(asHtml: false)
            genres
            averageScore
            episodes chapters
            season seasonYear
            type
            recommendations(sort: [RATING_DESC, ID], perPage: 15) {
              nodes {
                mediaRecommendation {
                  id
                  title { english romaji native }
                  coverImage { large extraLarge }
                  bannerImage
                  format status
                  averageScore
                  type
                }
              }
            }
          }
        }
        """

        let body: [String: Any] = ["query": graphqlQuery, "variables": ["id": id]]
        let data = try await performRequest(body: body)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataDict = json["data"] as? [String: Any],
              let mediaDict = dataDict["Media"] as? [String: Any] else {
            return nil
        }

        return parseMedia(mediaDict)
    }

    // MARK: - Core Query

    private func queryMedia(type: DiscoverMediaType, sort: DiscoverSort, season: String? = nil, seasonYear: Int? = nil, search: String? = nil, genres: [String]? = nil, tags: [String]? = nil, format: String? = nil, status: String? = nil, countryOfOrigin: String? = nil, page: Int = 1, perPage: Int = 20) async throws -> [DiscoverMedia] {
        let (media, _) = try await queryMediaPaginated(type: type, sort: sort, season: season, seasonYear: seasonYear, search: search, genres: genres, tags: tags, format: format, status: status, countryOfOrigin: countryOfOrigin, page: page, perPage: perPage)
        return media
    }

    private func queryMediaPaginated(type: DiscoverMediaType, sort: DiscoverSort, season: String? = nil, seasonYear: Int? = nil, search: String? = nil, genres: [String]? = nil, tags: [String]? = nil, format: String? = nil, status: String? = nil, countryOfOrigin: String? = nil, page: Int = 1, perPage: Int = 20) async throws -> (media: [DiscoverMedia], hasNextPage: Bool) {
        let graphqlQuery = """
        query ($page: Int, $perPage: Int, $type: MediaType, $sort: [MediaSort],
               $season: MediaSeason, $seasonYear: Int, $search: String,
               $genres: [String], $tags: [String], $format: [MediaFormat],
               $status: MediaStatus, $countryOfOrigin: CountryCode,
               $isAdult: Boolean = false) {
          Page(page: $page, perPage: $perPage) {
            pageInfo { hasNextPage }
            media(type: $type, sort: $sort, season: $season, seasonYear: $seasonYear,
                  search: $search, genre_in: $genres, tag_in: $tags,
                  format_in: $format, status: $status, countryOfOrigin: $countryOfOrigin,
                  isAdult: $isAdult) {
              id
              title { english romaji native }
              coverImage { large extraLarge }
              bannerImage
              format status
              description(asHtml: false)
              genres
              averageScore
              episodes chapters
              season seasonYear
              type
            }
          }
        }
        """

        var variables: [String: Any] = [
            "page": page,
            "perPage": perPage,
            "type": type.rawValue,
            "sort": [sort.rawValue]
        ]

        if let season = season { variables["season"] = season }
        if let seasonYear = seasonYear { variables["seasonYear"] = seasonYear }
        if let search = search { variables["search"] = search }
        if let genres = genres { variables["genres"] = genres }
        if let tags = tags { variables["tags"] = tags }
        if let format = format { variables["format"] = [format] }
        if let status = status { variables["status"] = status }
        if let country = countryOfOrigin { variables["countryOfOrigin"] = country }

        let body: [String: Any] = ["query": graphqlQuery, "variables": variables]
        let data = try await performRequest(body: body)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataDict = json["data"] as? [String: Any],
              let page = dataDict["Page"] as? [String: Any],
              let pageInfo = page["pageInfo"] as? [String: Any],
              let mediaList = page["media"] as? [[String: Any]] else {
            return ([], false)
        }

        let hasNextPage = pageInfo["hasNextPage"] as? Bool ?? false
        let media = mediaList.compactMap { parseMedia($0) }
        return (media, hasNextPage)
    }

    // MARK: - Parsing

    private func parseMedia(_ dict: [String: Any]) -> DiscoverMedia? {
        guard let id = dict["id"] as? Int else { return nil }

        let titleObj = dict["title"] as? [String: String?]
        let english = titleObj?["english"] as? String
        let romaji = titleObj?["romaji"] as? String
        let native = titleObj?["native"] as? String
        let title = english ?? romaji ?? native ?? "Unknown"

        let coverObj = dict["coverImage"] as? [String: String]
        let cover = coverObj?["extraLarge"] ?? coverObj?["large"]

        let description = dict["description"] as? String

        var parsedRecommendations: [DiscoverMedia]?
        if let recDict = dict["recommendations"] as? [String: Any],
           let nodes = recDict["nodes"] as? [[String: Any]] {
            let recMediaDicts = nodes.compactMap { $0["mediaRecommendation"] as? [String: Any] }
            parsedRecommendations = recMediaDicts.compactMap { recDict in
                // recursive parsing for basic fields, bypassing deeper nesting
                DiscoverManager.shared.parseMedia(recDict)
            }
        }

        return DiscoverMedia(
            id: id,
            title: title,
            titleRomaji: romaji,
            coverImage: cover,
            bannerImage: dict["bannerImage"] as? String,
            format: dict["format"] as? String,
            status: dict["status"] as? String,
            description: description,
            cleanDescription: DiscoverManager.stripHTMLDiscover(description ?? ""),
            genres: dict["genres"] as? [String],
            averageScore: dict["averageScore"] as? Int,
            episodes: dict["episodes"] as? Int,
            chapters: dict["chapters"] as? Int,
            season: dict["season"] as? String,
            seasonYear: dict["seasonYear"] as? Int,
            type: dict["type"] as? String ?? "ANIME",
            recommendations: parsedRecommendations
        )
    }

    // MARK: - Networking

    private func performRequest(body: [String: Any]) async throws -> Data {
        let jsonData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = jsonData

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 429 {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            return try await performRequest(body: body)
        }

        return data
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

    static func stripHTMLDiscover(_ string: String) -> String? {
        guard !string.isEmpty else { return nil }
        var result = string
        if let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }
        let entities: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "),
            ("<br>", "\n"), ("<br/>", "\n"), ("<br />", "\n")
        ]
        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

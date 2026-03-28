import Foundation

public actor DiscoverService {
    public static let shared = DiscoverService()

    private let apiURL = URL(string: "https://graphql.anilist.co")!

    private init() {}

    // MARK: - Genres & Tags

    public func fetchGenres() async throws -> [String] {
        let body: [String: Any] = ["query": "query { GenreCollection }"]
        let data = try await performRequest(body: body)
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let dataDict = json["data"] as? [String: Any],
           let genres = dataDict["GenreCollection"] as? [String] {
            return genres.filter { $0 != "Hentai" }
        }
        return []
    }

    public func fetchTags() async throws -> [DiscoverTag] {
        let query = "query { MediaTagCollection { id name description category isAdult } }"
        let body: [String: Any] = ["query": query]
        let data = try await performRequest(body: body)
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let dataDict = json["data"] as? [String: Any],
           let tagList = dataDict["MediaTagCollection"] as? [[String: Any]] {
            return tagList.compactMap { dict -> DiscoverTag? in
                guard let id = dict["id"] as? Int,
                      let name = dict["name"] as? String else { return nil }
                return DiscoverTag(
                    id: id, name: name,
                    description: dict["description"] as? String,
                    category: dict["category"] as? String,
                    isAdult: dict["isAdult"] as? Bool
                )
            }
        }
        return []
    }

    // MARK: - Single Media Detail

    public func fetchMediaDetails(id: Int) async throws -> DiscoverMedia? {
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

    public func queryMedia(type: DiscoverMediaType, sort: DiscoverSort, season: String? = nil, seasonYear: Int? = nil, search: String? = nil, genres: [String]? = nil, excludedGenres: [String]? = nil, tags: [String]? = nil, excludedTags: [String]? = nil, format: String? = nil, status: String? = nil, countryOfOrigin: String? = nil, page: Int = 1, perPage: Int = 20) async throws -> [DiscoverMedia] {
        let (media, _) = try await queryMediaPaginated(type: type, sort: sort, season: season, seasonYear: seasonYear, search: search, genres: genres, excludedGenres: excludedGenres, tags: tags, excludedTags: excludedTags, format: format, status: status, countryOfOrigin: countryOfOrigin, page: page, perPage: perPage)
        return media
    }

    public func queryMediaPaginated(type: DiscoverMediaType, sort: DiscoverSort, season: String? = nil, seasonYear: Int? = nil, search: String? = nil, genres: [String]? = nil, excludedGenres: [String]? = nil, tags: [String]? = nil, excludedTags: [String]? = nil, format: String? = nil, status: String? = nil, countryOfOrigin: String? = nil, page: Int = 1, perPage: Int = 20) async throws -> (media: [DiscoverMedia], hasNextPage: Bool) {
        let graphqlQuery = """
        query ($page: Int, $perPage: Int, $type: MediaType, $sort: [MediaSort],
               $season: MediaSeason, $seasonYear: Int, $search: String,
               $genres: [String], $excludedGenres: [String],
               $tags: [String], $excludedTags: [String],
               $format: [MediaFormat],
               $status: MediaStatus, $countryOfOrigin: CountryCode,
               $isAdult: Boolean = false) {
          Page(page: $page, perPage: $perPage) {
            pageInfo { hasNextPage }
            media(type: $type, sort: $sort, season: $season, seasonYear: $seasonYear,
                  search: $search,
                  genre_in: $genres, genre_not_in: $excludedGenres,
                  tag_in: $tags, tag_not_in: $excludedTags,
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
        if let genres = genres, !genres.isEmpty { variables["genres"] = genres }
        if let excludedGenres = excludedGenres, !excludedGenres.isEmpty { variables["excludedGenres"] = excludedGenres }
        if let tags = tags, !tags.isEmpty { variables["tags"] = tags }
        if let excludedTags = excludedTags, !excludedTags.isEmpty { variables["excludedTags"] = excludedTags }
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

    public func parseMedia(_ dict: [String: Any]) -> DiscoverMedia? {
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
                self.parseMedia(recDict)
            }
        }

        let cleanDescription = (description ?? "").strippingHTML()

        return DiscoverMedia(
            id: id,
            title: title,
            titleRomaji: romaji,
            coverImage: cover,
            bannerImage: dict["bannerImage"] as? String,
            format: dict["format"] as? String,
            status: dict["status"] as? String,
            description: description,
            cleanDescription: cleanDescription,
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
}

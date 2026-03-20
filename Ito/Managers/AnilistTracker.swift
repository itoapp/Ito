import Foundation
import Combine

public class AnilistTracker: TrackerProvider {
    public let identifier = "anilist"
    public let name = "AniList"

    @Published public private(set) var anilistToken: String?
    @Published public private(set) var username: String?

    public var isAuthenticated: Bool {
        return anilistToken != nil
    }

    private let tokenKey = "anilist_access_token"
    private let usernameKey = "anilist_username"
    private let clientId = "36931"
    private let callbackScheme = "ito"

    public init() {
        self.anilistToken = UserDefaults.standard.string(forKey: tokenKey)
        self.username = UserDefaults.standard.string(forKey: usernameKey)
    }

    @MainActor
    public func authenticate(using oauthManager: OAuthManager) async throws {
        let authURLString = "https://anilist.co/api/v2/oauth/authorize?client_id=\(clientId)&response_type=token"
        guard let url = URL(string: authURLString) else {
            throw URLError(.badURL)
        }

        let callbackURL = try await oauthManager.authenticate(url: url, callbackScheme: callbackScheme)

        guard let fragment = callbackURL.fragment else {
            throw URLError(.cannotParseResponse)
        }

        let params = fragment.components(separatedBy: "&").reduce(into: [String: String]()) { result, param in
            let pair = param.components(separatedBy: "=")
            if pair.count == 2 {
                result[pair[0]] = pair[1]
            }
        }

        guard let token = params["access_token"] else {
            throw URLError(.userAuthenticationRequired)
        }

        self.anilistToken = token
        UserDefaults.standard.set(token, forKey: self.tokenKey)

        Task {
            do {
                try await self.fetchAnilistViewer(token: token)
            } catch {
                print("Failed to fetch viewer: \(error)")
            }
        }
    }

    public func logout() {
        self.anilistToken = nil
        self.username = nil
        UserDefaults.standard.removeObject(forKey: tokenKey)
        UserDefaults.standard.removeObject(forKey: usernameKey)
    }

    public func searchMedia(title: String, isAnime: Bool) async throws -> [TrackerMedia] {
        guard let token = anilistToken else { throw URLError(.userAuthenticationRequired) }

        let type = isAnime ? "ANIME" : "MANGA"
        let query = """
        query ($search: String, $type: MediaType) {
            Page(page: 1, perPage: 5) {
                media(search: $search, type: $type, sort: SEARCH_MATCH) {
                    id
                    title {
                        romaji
                        english
                        native
                    }
                    coverImage {
                        large
                    }
                    format
                    episodes
                    chapters
                }
            }
        }
        """

        let variables: [String: Any] = [
            "search": title,
            "type": type
        ]

        let body: [String: Any] = ["query": query, "variables": variables]
        let jsonData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: URL(string: "https://graphql.anilist.co")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = jsonData

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 429 {
            throw URLError(.backgroundSessionInUseByAnotherProcess)
        }

        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let dataDict = json["data"] as? [String: Any],
           let page = dataDict["Page"] as? [String: Any],
           let mediaList = page["media"] as? [[String: Any]] {

            return mediaList.compactMap { dict -> TrackerMedia? in
                guard let idInt = dict["id"] as? Int,
                      let titleObj = dict["title"] as? [String: String?] else { return nil }

                let id = String(idInt)
                let romaji = titleObj["romaji"] ?? ""
                let english = titleObj["english"] ?? ""
                let native = titleObj["native"] ?? ""

                let title = english ?? romaji ?? native ?? "Unknown Title"
                let coverObj = dict["coverImage"] as? [String: String]
                let cover = coverObj?["large"]

                let format = dict["format"] as? String
                let episodes = dict["episodes"] as? Int
                let chapters = dict["chapters"] as? Int

                return TrackerMedia(id: id, title: title, titleRomaji: romaji, coverImage: cover, format: format, episodes: episodes, chapters: chapters)
            }
        }

        return []
    }

    public func updateProgress(mediaId: String, progress: Int?, status: String?) async throws {
        guard let token = anilistToken else { throw URLError(.userAuthenticationRequired) }
        guard let idInt = Int(mediaId) else { throw URLError(.badURL) }

        if let progress = progress {
            do {
                if let entry = try await getMediaListEntry(mediaId: mediaId),
                   let currentProgress = entry.progress {
                    if currentProgress >= progress && (status == nil || entry.status == status) {
                        return
                    }
                }
            } catch {
                print("Failed to fetch existing entry before updating, proceeding with update.")
            }
        }

        let mutation = """
        mutation ($mediaId: Int, $progress: Int, $status: MediaListStatus) {
            SaveMediaListEntry(mediaId: $mediaId, progress: $progress, status: $status) {
                id
                progress
                status
            }
        }
        """

        var variables: [String: Any] = [
            "mediaId": idInt
        ]

        if let progress = progress {
            variables["progress"] = progress
        }

        if let status = status {
            variables["status"] = status
        }

        let body: [String: Any] = ["query": mutation, "variables": variables]
        let jsonData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: URL(string: "https://graphql.anilist.co")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = jsonData

        let (_, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse {
            if httpResponse.statusCode == 429 {
                throw URLError(.backgroundSessionInUseByAnotherProcess)
            } else if httpResponse.statusCode != 200 {
                throw URLError(.badServerResponse)
            }
        }
    }

    public func getMediaListEntry(mediaId: String) async throws -> TrackerMediaEntry? {
        guard let token = anilistToken else { throw URLError(.userAuthenticationRequired) }
        guard let username = username else { return nil }
        guard let idInt = Int(mediaId) else { throw URLError(.badURL) }

        let query = """
        query ($mediaId: Int, $userName: String) {
            MediaList(mediaId: $mediaId, userName: $userName) {
                status
                progress
                score
                startedAt {
                    year
                    month
                    day
                }
                completedAt {
                    year
                    month
                    day
                }
            }
        }
        """

        let variables: [String: Any] = [
            "mediaId": idInt,
            "userName": username
        ]

        let body: [String: Any] = ["query": query, "variables": variables]
        let jsonData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: URL(string: "https://graphql.anilist.co")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = jsonData

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 429 {
            throw URLError(.backgroundSessionInUseByAnotherProcess)
        }

        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let dataDict = json["data"] as? [String: Any],
           let entry = dataDict["MediaList"] as? [String: Any] {

            let status = entry["status"] as? String
            let progress = entry["progress"] as? Int
            let score = entry["score"] as? Double

            var startDate: Date?
            if let start = entry["startedAt"] as? [String: Any?],
               let year = start["year"] as? Int, let month = start["month"] as? Int, let day = start["day"] as? Int {
                var components = DateComponents()
                components.year = year
                components.month = month
                components.day = day
                startDate = Calendar.current.date(from: components)
            }

            var finishDate: Date?
            if let end = entry["completedAt"] as? [String: Any?],
               let year = end["year"] as? Int, let month = end["month"] as? Int, let day = end["day"] as? Int {
                var components = DateComponents()
                components.year = year
                components.month = month
                components.day = day
                finishDate = Calendar.current.date(from: components)
            }

            return TrackerMediaEntry(status: status, progress: progress, score: score, startDate: startDate, finishDate: finishDate)
        }

        return nil
    }

    private func fetchAnilistViewer(token: String) async throws {
        let query = """
        query {
            Viewer {
                name
            }
        }
        """

        let body: [String: Any] = ["query": query]
        let jsonData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: URL(string: "https://graphql.anilist.co")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = jsonData

        let (data, _) = try await URLSession.shared.data(for: request)

        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let dataDict = json["data"] as? [String: Any],
           let viewer = dataDict["Viewer"] as? [String: Any],
           let name = viewer["name"] as? String {

            await MainActor.run {
                self.username = name
                UserDefaults.standard.set(name, forKey: self.usernameKey)
            }
        } else {
            throw URLError(.cannotParseResponse)
        }
    }
}

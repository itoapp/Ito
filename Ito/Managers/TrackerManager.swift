import Combine
import Foundation
import AuthenticationServices

public class TrackerManager: ObservableObject {
    public static let shared = TrackerManager()

    @Published public private(set) var anilistToken: String?
    @Published public private(set) var anilistUsername: String?

    // Independent mapping: Local Media Key (String) -> AniList ID (Int)
    @Published public private(set) var trackerMappings: [String: Int] = [:]

    private let tokenKey = "anilist_access_token"
    private let usernameKey = "anilist_username"
    private let mappingsKey = "Ito.TrackerMappings"

    // Replace this with your actual AniList Client ID
    private let clientId = "36931"
    // The custom scheme configured in Info.plist (e.g., ito://anilist-auth)
    private let callbackScheme = "ito"

    private init() {
        self.anilistToken = UserDefaults.standard.string(forKey: tokenKey)
        self.anilistUsername = UserDefaults.standard.string(forKey: usernameKey)

        if let data = UserDefaults.standard.data(forKey: mappingsKey),
           let decoded = try? JSONDecoder().decode([String: Int].self, from: data) {
            self.trackerMappings = decoded
        }
    }

    public func link(localId: String, anilistId: Int) {
        trackerMappings[localId] = anilistId
        if let encoded = try? JSONEncoder().encode(trackerMappings) {
            UserDefaults.standard.set(encoded, forKey: mappingsKey)
        }
        // Also keep LibraryItem up-to-date for backward compatibility if it is saved
        LibraryManager.shared.setAnilistId(for: localId, anilistId: anilistId)
    }

    public func unlink(localId: String) {
        trackerMappings.removeValue(forKey: localId)
        if let encoded = try? JSONEncoder().encode(trackerMappings) {
            UserDefaults.standard.set(encoded, forKey: mappingsKey)
        }
        // Keep LibraryItem synchronized
        LibraryManager.shared.removeAnilistId(for: localId)
    }

    public func getAnilistId(for localId: String) -> Int? {
        if let mappedId = trackerMappings[localId] {
            return mappedId
        }
        // Fallback to LibraryManager check
        return LibraryManager.shared.getAnilistId(for: localId)
    }

    public var isAnilistAuthenticated: Bool {
        return anilistToken != nil
    }

    @MainActor
    public func authenticateWithAnilist() async throws {
        let authURLString = "https://anilist.co/api/v2/oauth/authorize?client_id=\(clientId)&response_type=token"
        guard let url = URL(string: authURLString) else {
            throw URLError(.badURL)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callbackURL, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let callbackURL = callbackURL else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                    return
                }

                // AniList implicit grant returns the token in the URL fragment:
                // ito://anilist-auth#access_token=...&token_type=Bearer&expires_in=31536000
                guard let fragment = callbackURL.fragment else {
                    continuation.resume(throwing: URLError(.cannotParseResponse))
                    return
                }

                let params = fragment.components(separatedBy: "&").reduce(into: [String: String]()) { result, param in
                    let pair = param.components(separatedBy: "=")
                    if pair.count == 2 {
                        result[pair[0]] = pair[1]
                    }
                }

                guard let token = params["access_token"] else {
                    continuation.resume(throwing: URLError(.userAuthenticationRequired))
                    return
                }

                DispatchQueue.main.async {
                    self.anilistToken = token
                    UserDefaults.standard.set(token, forKey: self.tokenKey)
                }

                // Fetch the username
                Task {
                    do {
                        try await self.fetchAnilistViewer(token: token)
                    } catch {
                        print("Failed to fetch viewer: \(error)")
                    }
                }

                continuation.resume()
            }

            session.presentationContextProvider = AuthPresentationContext.shared
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }
    }

    public func logoutAnilist() {
        self.anilistToken = nil
        self.anilistUsername = nil
        UserDefaults.standard.removeObject(forKey: tokenKey)
        UserDefaults.standard.removeObject(forKey: usernameKey)
    }

    // MARK: - API Calls

    /// Searches AniList for a matching Media ID based on title and type
    public func searchAnilistMedia(title: String, isAnime: Bool) async throws -> Int? {
        guard let token = anilistToken else { throw URLError(.userAuthenticationRequired) }

        let type = isAnime ? "ANIME" : "MANGA"
        let query = """
        query ($search: String, $type: MediaType) {
            Page(page: 1, perPage: 1) {
                media(search: $search, type: $type, sort: POPULARITY_DESC) {
                    id
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
            print("AniList API Rate Limited!")
            throw URLError(.backgroundSessionInUseByAnotherProcess)
        }

        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let dataDict = json["data"] as? [String: Any],
           let page = dataDict["Page"] as? [String: Any],
           let mediaList = page["media"] as? [[String: Any]],
           let firstMedia = mediaList.first,
           let id = firstMedia["id"] as? Int {
            return id
        }

        return nil
    }

    public func searchAnilistMediaFull(title: String, isAnime: Bool) async throws -> [AnilistMedia] {
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
            print("AniList API Rate Limited!")
            throw URLError(.backgroundSessionInUseByAnotherProcess)
        }

        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let dataDict = json["data"] as? [String: Any],
           let page = dataDict["Page"] as? [String: Any],
           let mediaList = page["media"] as? [[String: Any]] {

            return mediaList.compactMap { dict -> AnilistMedia? in
                guard let id = dict["id"] as? Int,
                      let titleObj = dict["title"] as? [String: String?] else { return nil }

                let romaji = titleObj["romaji"] ?? ""
                let english = titleObj["english"] ?? ""
                let native = titleObj["native"] ?? ""

                // Prioritize English, then Romaji, then Native
                let title = english ?? romaji ?? native ?? "Unknown Title"

                let coverObj = dict["coverImage"] as? [String: String]
                let cover = coverObj?["large"]

                let format = dict["format"] as? String
                let episodes = dict["episodes"] as? Int
                let chapters = dict["chapters"] as? Int

                return AnilistMedia(id: id, title: title, titleRomaji: romaji, coverImage: cover, format: format, episodes: episodes, chapters: chapters)
            }
        }

        return []
    }

    /// Updates the user's progress on a given AniList mediaId
    public func updateProgress(mediaId: Int, progress: Int) async throws {
        guard let token = anilistToken else { throw URLError(.userAuthenticationRequired) }

        let mutation = """
        mutation ($mediaId: Int, $progress: Int) {
            SaveMediaListEntry(mediaId: $mediaId, progress: $progress) {
                id
                progress
            }
        }
        """

        let variables: [String: Any] = [
            "mediaId": mediaId,
            "progress": progress
        ]

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
                print("AniList API Rate Limited!")
                throw URLError(.backgroundSessionInUseByAnotherProcess)
            } else if httpResponse.statusCode != 200 {
                print("AniList Update Failed with status: \(httpResponse.statusCode)")
                throw URLError(.badServerResponse)
            } else {
                print("AniList Update Successful: MediaID \(mediaId) -> Progress \(progress)")
            }
        }
    }

    public func getMediaListEntry(mediaId: Int) async throws -> [String: Any]? {
        guard let token = anilistToken else { throw URLError(.userAuthenticationRequired) }
        guard let username = anilistUsername else {
            // If we don't have the username yet, we can try to fetch the viewer ID first or just return nil for now.
            // Ideally ensure username is fetched upon login.
            return nil
        }

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
            "mediaId": mediaId,
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
            print("AniList API Rate Limited!")
            throw URLError(.backgroundSessionInUseByAnotherProcess)
        }

        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let dataDict = json["data"] as? [String: Any],
           let entry = dataDict["MediaList"] as? [String: Any] {
            return entry
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
                self.anilistUsername = name
                UserDefaults.standard.set(name, forKey: self.usernameKey)
            }
        } else {
            throw URLError(.cannotParseResponse)
        }
    }
}

class AuthPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = AuthPresentationContext()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // Fallback for getting the key window
        return UIApplication.shared.connectedScenes
            .filter { $0.activationState == .foregroundActive }
            .compactMap { $0 as? UIWindowScene }
            .first?.windows
            .filter { $0.isKeyWindow }.first ?? ASPresentationAnchor()
    }
}

import Foundation

public struct TrackerMediaEntry {
    public let status: String?
    public let progress: Int?
    public let score: Double?
    public let startDate: Date?
    public let finishDate: Date?

    public init(status: String?, progress: Int?, score: Double?, startDate: Date?, finishDate: Date?) {
        self.status = status
        self.progress = progress
        self.score = score
        self.startDate = startDate
        self.finishDate = finishDate
    }
}

public struct TrackerMedia: Identifiable, Codable {
    public let id: String
    public let title: String
    public let titleRomaji: String?
    public let coverImage: String?
    public let format: String?
    public let episodes: Int?
    public let chapters: Int?

    public init(id: String, title: String, titleRomaji: String?, coverImage: String?, format: String?, episodes: Int?, chapters: Int?) {
        self.id = id
        self.title = title
        self.titleRomaji = titleRomaji
        self.coverImage = coverImage
        self.format = format
        self.episodes = episodes
        self.chapters = chapters
    }
}

@MainActor
public protocol TrackerProvider: ObservableObject {
    var identifier: String { get } // e.g., "anilist"
    var name: String { get } // e.g., "AniList"
    var isAuthenticated: Bool { get }
    var username: String? { get }

    func authenticate(using oauthManager: OAuthManager) async throws
    func logout()

    func searchMedia(title: String, isAnime: Bool) async throws -> [TrackerMedia]
    func updateProgress(mediaId: String, progress: Int?, status: String?) async throws
    func getMediaListEntry(mediaId: String) async throws -> TrackerMediaEntry?
}

import Foundation
import Combine

public protocol ProgressTracking: ObservableObject {
    func markAsRead(media: MediaIdentity, chapterId: String, chapterNum: Float?) async throws
    func markAsWatched(media: MediaIdentity, episodeId: String, episodeNum: Float?) async throws
    func isRead(media: MediaIdentity, chapterId: String, chapterNum: Float?) -> Bool
    func markReadUpTo(media: MediaIdentity, maxChapterNum: Float) async throws
    func lastReadChapter(for media: MediaIdentity) -> String?
    func readChapterNumbers(for media: MediaIdentity) -> Set<Float>
    func reload() async throws
}

import Combine
import Foundation
import SwiftUI

/// Manages reading progress, tracking which chapters have been read,
/// and the last read chapter per manga.
@MainActor
public class ReadProgressManager: ObservableObject {
    public static let shared = ReadProgressManager()

    // keys: manga ID, values: set of chapter IDs
    @Published public private(set) var readChapters: [String: Set<String>] = [:]

    // keys: manga ID, values: set of read chapter numbers
    @Published public private(set) var readChapterNumbers: [String: Set<Float>] = [:]

    // keys: manga ID, values: last read chapter ID
    @Published public private(set) var lastReadChapter: [String: String] = [:]

    private let readChaptersKey = "Ito.ReadChapters"
    private let readChapterNumbersKey = "Ito.ReadChapterNumbers"
    private let lastReadChapterKey = "Ito.LastReadChapter"

    private init() {
        loadProgress()
    }

    private func loadProgress() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: readChaptersKey),
            let decoded = try? JSONDecoder().decode([String: Set<String>].self, from: data) {
            self.readChapters = decoded
        }

        if let data = defaults.data(forKey: readChapterNumbersKey),
            let decoded = try? JSONDecoder().decode([String: Set<Float>].self, from: data) {
            self.readChapterNumbers = decoded
        }

        if let data = defaults.data(forKey: lastReadChapterKey),
            let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            self.lastReadChapter = decoded
        }
    }

    private func saveProgress() {
        let defaults = UserDefaults.standard
        if let encoded = try? JSONEncoder().encode(readChapters) {
            defaults.set(encoded, forKey: readChaptersKey)
        }
        if let encoded = try? JSONEncoder().encode(readChapterNumbers) {
            defaults.set(encoded, forKey: readChapterNumbersKey)
        }
        if let encoded = try? JSONEncoder().encode(lastReadChapter) {
            defaults.set(encoded, forKey: lastReadChapterKey)
        }
    }

    /// Mark a chapter as read
    public func markAsRead(mangaId: String, chapterId: String, chapterNum: Float? = nil) {
        if readChapters[mangaId] == nil {
            readChapters[mangaId] = []
        }
        readChapters[mangaId]?.insert(chapterId)

        if let num = chapterNum {
            if readChapterNumbers[mangaId] == nil {
                readChapterNumbers[mangaId] = []
            }
            readChapterNumbers[mangaId]?.insert(num)
        }

        lastReadChapter[mangaId] = chapterId

        // Clear the unread badge automatically when the user reads a chapter
        UpdateManager.shared.decrementBadge(for: mangaId)

        saveProgress()
    }

    /// Mark an episode as watched (reusing the same structure as chapters)
    public func markAsWatched(animeId: String, episodeId: String, episodeNum: Float? = nil) {
        markAsRead(mangaId: animeId, chapterId: episodeId, chapterNum: episodeNum)
    }

    /// Check if a chapter/episode is read/watched
    public func isRead(mangaId: String, chapterId: String, chapterNum: Float? = nil) -> Bool {
        if readChapters[mangaId]?.contains(chapterId) ?? false {
            return true
        }
        if let num = chapterNum, let nums = readChapterNumbers[mangaId], nums.contains(num) {
            return true
        }
        return false
    }

    /// Mark all chapters up to a given number as read (Useful for tracker syncing)
    public func markReadUpTo(mangaId: String, maxChapterNum: Float) {
        if readChapterNumbers[mangaId] == nil {
            readChapterNumbers[mangaId] = []
        }

        // Add all integers up to the maxChapterNum. 
        // Note: For decimals (e.g. 15.5) we won't try to guess, but this covers standard integers nicely.
        let maxInt = Int(maxChapterNum)
        if maxInt > 0 {
            for i in 1...maxInt {
                readChapterNumbers[mangaId]?.insert(Float(i))
            }
        }
        // Also ensure the exact float is marked
        readChapterNumbers[mangaId]?.insert(maxChapterNum)

        // Bulk operation — fully clear the badge. Next refresh will recalculate.
        UpdateManager.shared.clearBadge(for: mangaId)

        saveProgress()
    }

    /// Get the last read chapter ID for a manga
    public func getLastRead(mangaId: String) -> String? {
        return lastReadChapter[mangaId]
    }
}

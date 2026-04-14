import Foundation
@preconcurrency import ito_runner

public protocol ChapterDisplayable: Identifiable {
    var key: String { get }
    var title: String? { get }
    var chapterNumber: Float? { get }
    var scanlator: String? { get }
    var dateUpload: String? { get }
    var isPaywalled: Bool { get }
}

extension ChapterDisplayable {
    public var isPaywalled: Bool { false }
}

nonisolated extension Manga.Chapter: ChapterDisplayable {
    public var chapterNumber: Float? { chapter }
    public var dateUpload: String? {
        guard let ts = dateUpdated else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(ts)).formatted(date: .abbreviated, time: .omitted)
    }
    public var isPaywalled: Bool { paywalled ?? false }
}

nonisolated extension Anime.Episode: ChapterDisplayable {
    public var chapterNumber: Float? { episode }
    public var scanlator: String? { lang?.uppercased() }
    public var dateUpload: String? {
        guard let ts = dateUpdated else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(ts)).formatted(date: .abbreviated, time: .omitted)
    }
    public var isPaywalled: Bool { paywalled ?? false }
}

nonisolated extension Novel.Chapter: ChapterDisplayable {
    public var chapterNumber: Float? { chapter }
    public var dateUpload: String? {
        guard let ts = dateUpdated else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(ts)).formatted(date: .abbreviated, time: .omitted)
    }
    public var isPaywalled: Bool { paywalled ?? false }
}

import Foundation
import SwiftUI

public struct PluginSearchResult: Identifiable {
    public let id: String
    public let title: String
    public let cover: String?
    public let subtitle: String?
    public let pluginName: String?
    public let destination: AnyView

    public init(id: String, title: String, cover: String?, subtitle: String?, pluginName: String? = nil, destination: AnyView) {
        self.id = id
        self.title = title
        self.cover = cover
        self.subtitle = subtitle
        self.pluginName = pluginName
        self.destination = destination
    }
}

public enum SearchScope: String, CaseIterable, Identifiable {
    case all = "All"
    case manga = "Manga"
    case anime = "Anime"
    case novel = "Novel"

    public var id: String { rawValue }
}

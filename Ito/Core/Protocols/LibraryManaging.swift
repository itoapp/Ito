import Foundation
import Combine
import ito_runner

public protocol LibraryManaging: ObservableObject {
    var items: [LibraryItem] { get }
    func isSaved(id: String) -> Bool
    func removeItem(withId id: String)
    func toggleSaveManga(manga: Manga, pluginId: String)
    func toggleSaveNovel(novel: Novel, pluginId: String)
    func saveResolvedMedia(media: ResolvedPluginMedia, pluginId: String, anilistId: Int?)

    func toggleSaveAnime(anime: Anime, pluginId: String)

    func setAnilistId(for itemId: String, anilistId: Int)
    func removeAnilistId(for itemId: String)
    func getAnilistId(for itemId: String) -> Int?
}

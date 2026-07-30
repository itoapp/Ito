import Foundation
import Combine
import ito_runner

public protocol LibraryManaging: ObservableObject {
    var items: [LibraryItem] { get }
    func isSaved(id: String) -> Bool
    func removeItem(withId id: String)
    func toggleSaveManga(manga: Manga, pluginId: String)
    func toggleSaveNovel(novel: Novel, pluginId: String)
    func toggleSaveAnime(anime: Anime, pluginId: String)
}

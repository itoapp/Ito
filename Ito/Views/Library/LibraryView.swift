import SwiftUI
import Nuke
import NukeUI
import ito_runner

struct LibraryView: View {
    @StateObject private var libraryManager = LibraryManager.shared
    
    let columns = [
        GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 16)
    ]
    
    var body: some View {
        NavigationView {
            ScrollView {
                if libraryManager.items.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: "books.vertical")
                            .font(.system(size: 60))
                            .foregroundStyle(.secondary)
                            .padding(.top, 100)

                        Text("Your Library is Empty")
                            .font(.title2)
                            .fontWeight(.semibold)

                        Text("Manga and Anime you save will appear here.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                } else {
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(libraryManager.items) { item in
                            LibraryItemView(item: item)
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("Library")
        }
        .navigationViewStyle(.stack)
    }
}

struct LibraryItemView: View {
    let item: LibraryItem
    @ObservedObject private var pluginManager = PluginManager.shared
    
    var body: some View {
        NavigationLink(destination: DeferredPluginView(item: item)) {
            cardContent
        }
        .buttonStyle(PlainButtonStyle())
        .contextMenu {
            Button(role: .destructive, action: {
                LibraryManager.shared.removeItem(withId: item.id)
            }) {
                Label("Remove from Library", systemImage: "trash")
            }
        }
    }
    
    private var isPluginInstalled: Bool {
        pluginManager.installedPlugins[item.pluginId] != nil
    }
    
    private var cardContent: some View {
        VStack(alignment: .leading) {
            ZStack(alignment: .topTrailing) {
                if let coverURL = item.coverUrl, let url = URL(string: coverURL) {
                    LazyImage(url: url) { state in
                        if let image = state.image {
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else if state.error != nil {
                            Color.red.opacity(0.3)
                        } else {
                            ZStack {
                                Color.gray.opacity(0.3)
                                ProgressView()
                            }
                        }
                    }
                    .processors([.resize(width: 300)])
                } else {
                    ZStack {
                        Color.gray.opacity(0.3)
                        Image(systemName: "photo.on.rectangle.angled")
                            .foregroundColor(.secondary)
                    }
                }
                
                // Type badge only
                Text(item.isAnime ? "Anime" : "Manga")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(item.isAnime ? Color.blue : Color.orange)
                    .foregroundColor(.white)
                    .cornerRadius(4)
                    .padding(4)
                
                if !isPluginInstalled {
                    ZStack {
                        Color.black.opacity(0.6)
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.yellow)
                            .font(.largeTitle)
                    }
                }
            }
            .frame(height: 150)
            .cornerRadius(8)
            .clipped()
            
            Text(item.title)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .foregroundColor(isPluginInstalled ? .primary : .secondary)
        }
    }
}

struct DeferredPluginView: View {
    let item: LibraryItem
    @State private var runner: ItoRunner? = nil
    @State private var errorMessage: String? = nil
    
    // Decoded instances
    @State private var decodedAnime: Anime? = nil
    @State private var decodedManga: Manga? = nil

    var body: some View {
        Group {
            if let error = errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundColor(.red)
                    Text("Error loading plugin")
                        .font(.headline)
                    Text(error)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            } else if let runner = runner {
                if item.isAnime, let anime = decodedAnime {
                    AnimeView(runner: runner, anime: anime, pluginId: item.pluginId)
                } else if !item.isAnime, let manga = decodedManga {
                    MangaView(runner: runner, manga: manga, pluginId: item.pluginId)
                } else {
                    Text("Failed to decode saved item.")
                }
            } else {
                ProgressView("Starting plugin...")
            }
        }
        .onAppear {
            print("▶️ [DEBUG-UI] DeferredPluginView.onAppear for item: \(item.title)")
            Task {
                await loadRunnerAndItem()
            }
        }
        .onDisappear {
            print("⏹️ [DEBUG-UI] DeferredPluginView.onDisappear for item: \(item.title)")
        }
    }
    
    private func loadRunnerAndItem() async {
        do {
            if item.isAnime {
                self.decodedAnime = try JSONDecoder().decode(Anime.self, from: item.rawPayload)
            } else {
                self.decodedManga = try JSONDecoder().decode(Manga.self, from: item.rawPayload)
            }
            
            let pluginRunner = try await PluginManager.shared.getRunner(for: item.pluginId)
            await MainActor.run {
                self.runner = pluginRunner
            }
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
            }
        }
    }
}

#Preview {
    LibraryView()
}

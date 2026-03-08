import SwiftUI
import ito_runner

struct LibraryView: View {
    @StateObject private var libraryManager = LibraryManager.shared
    
    let columns = [
        GridItem(.adaptive(minimum: 100, maximum: 120), spacing: 16)
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
    
    @State private var runner: ItoRunner? = nil
    @State private var isLoaded = false
    @State private var errorMessage: String? = nil
    
    // Decoded instances
    @State private var decodedAnime: Anime? = nil
    @State private var decodedManga: Manga? = nil
    
    var body: some View {
        Group {
            if let runner = self.runner, isLoaded {
                if item.isAnime, let anime = decodedAnime {
                    NavigationLink(destination: AnimeView(runner: runner, anime: anime, pluginId: item.pluginId)) {
                        cardContent
                    }
                    .buttonStyle(PlainButtonStyle())
                } else if !item.isAnime, let manga = decodedManga {
                    NavigationLink(destination: MangaView(runner: runner, manga: manga, pluginId: item.pluginId)) {
                        cardContent
                    }
                    .buttonStyle(PlainButtonStyle())
                } else {
                    cardContent
                }
            } else {
                cardContent
                    .onTapGesture {
                        if !isLoaded {
                            print("LibraryItemView tapped but runner is not ready yet.")
                        }
                    }
            }
        }
        .onAppear {
            if runner == nil {
                Task {
                    await initRunner()
                }
            }
        }
    }
    
    private var cardContent: some View {
        VStack(alignment: .leading) {
            ZStack(alignment: .topTrailing) {
                if let coverURL = item.coverUrl, let url = URL(string: coverURL) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .empty:
                            Color.gray.opacity(0.3)
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        case .failure:
                            Color.red.opacity(0.3)
                        @unknown default:
                            EmptyView()
                        }
                    }
                } else {
                    Color.gray.opacity(0.3)
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
                
                if !isLoaded && runner != nil {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.4))
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
                .foregroundColor(.primary)
        }
    }
    
    private func initRunner() async {
        do {
            if item.isAnime {
                self.decodedAnime = try JSONDecoder().decode(Anime.self, from: item.rawPayload)
            } else {
                self.decodedManga = try JSONDecoder().decode(Manga.self, from: item.rawPayload)
            }
            
            // To properly launch the viewer, we need the plugin loaded.
            // Normally this requires a central PluginManager to fetch the URL, but we will mock fetching the local bundled URL
            // assuming the user dragged it in, or it's accessible.
            // For now, since BrowseView loads them from drag/drop, we might need a way to get the loaded URL by pluginId.
            // We'll construct a dummy URL assuming the plugin exists in the app's Application Support/Plugins directory.
            
            let fileManager = FileManager.default
            guard let appSupportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
            let pluginsDir = appSupportDir.appendingPathComponent("Plugins")
            let pluginURL = pluginsDir.appendingPathComponent("\(item.pluginId).ito")
            
            if FileManager.default.fileExists(atPath: pluginURL.path) {
                let pluginRunner = ItoRunner()
                await pluginRunner.setNetModule(AppNetModule())
                await pluginRunner.setStdModule(DefaultStdModule())
                await pluginRunner.setDefaultsModule(DefaultDefaultsModule(pluginId: item.pluginId))
                await pluginRunner.setHtmlModule(DefaultHtmlModule())
                await pluginRunner.setJsModule(DefaultJsModule())
                
                _ = try await pluginRunner.loadBundle(from: pluginURL)
                
                await MainActor.run {
                    self.runner = pluginRunner
                    self.isLoaded = true
                }
            } else {
                print("Missing plugin file for \(item.pluginId)")
                await MainActor.run {
                    self.errorMessage = "Plugin not installed"
                }
            }
        } catch {
            print("Failed to init library item: \(error)")
        }
    }
}

#Preview {
    LibraryView()
}

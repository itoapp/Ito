import SwiftUI
import Nuke
import NukeUI
import ito_runner

// MARK: - Anime Views

struct AnimeCardView: View {
    let anime: Anime
    let plugin: InstalledPlugin
    let runner: ItoRunner?

    var body: some View {
        NavigationLink(destination: AnimeView(runner: runner!, anime: anime, pluginId: plugin.url.deletingPathExtension().lastPathComponent)) {
            VStack(alignment: .leading, spacing: 4) {
                if let coverURL = anime.cover, let url = URL(string: coverURL) {
                    LazyImage(url: url) { state in
                        if let image = state.image {
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 110, height: 160)
                                .cornerRadius(8)
                                .clipped()
                        } else if state.error != nil {
                            Color.red.opacity(0.3)
                                .frame(width: 110, height: 160)
                                .cornerRadius(8)
                        } else {
                            Color.gray.opacity(0.3)
                                .frame(width: 110, height: 160)
                                .cornerRadius(8)
                        }
                    }
                    .processors([.resize(width: 220)])
                } else {
                    Color.gray.opacity(0.3)
                        .frame(width: 110, height: 160)
                        .cornerRadius(8)
                }
                
                Text(anime.title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: 110, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }
}

struct AnimeBigCardView: View {
    let anime: Anime
    let plugin: InstalledPlugin
    let runner: ItoRunner?

    var body: some View {
        NavigationLink(destination: AnimeView(runner: runner!, anime: anime, pluginId: plugin.url.deletingPathExtension().lastPathComponent)) {
            VStack(alignment: .leading, spacing: 8) {
                if let coverURL = anime.cover, let url = URL(string: coverURL) {
                    LazyImage(url: url) { state in
                        if let image = state.image {
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 240, height: 150)
                                .cornerRadius(12)
                                .clipped()
                        } else if state.error != nil {
                            Color.red.opacity(0.3)
                                .frame(width: 240, height: 150)
                                .cornerRadius(12)
                        } else {
                            Color.gray.opacity(0.3)
                                .frame(width: 240, height: 150)
                                .cornerRadius(12)
                        }
                    }
                    .processors([.resize(width: 480)])
                } else {
                    Color.gray.opacity(0.3)
                        .frame(width: 240, height: 150)
                        .cornerRadius(12)
                }
                
                Text(anime.title)
                    .font(.body)
                    .fontWeight(.bold)
                    .lineLimit(1)
                    .frame(width: 240, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }
}

struct AnimeRowView: View {
    let anime: Anime
    let plugin: InstalledPlugin
    let runner: ItoRunner?

    var body: some View {
        ZStack {
            if let runner = self.runner {
                NavigationLink(destination: AnimeView(runner: runner, anime: anime, pluginId: plugin.url.deletingPathExtension().lastPathComponent)) {
                    EmptyView()
                }
                .opacity(0)
            }

            HStack(alignment: .top, spacing: 12) {
                if let coverURL = anime.cover, let url = URL(string: coverURL) {
                    LazyImage(url: url) { state in
                        if let image = state.image {
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 60, height: 90)
                                .cornerRadius(6)
                                .clipped()
                        } else if state.error != nil {
                            Color.red.opacity(0.3)
                                .frame(width: 60, height: 90)
                                .cornerRadius(6)
                        } else {
                            Color.gray.opacity(0.3)
                                .frame(width: 60, height: 90)
                                .cornerRadius(6)
                        }
                    }
                    .processors([.resize(width: 120)])
                } else {
                    Color.gray.opacity(0.3)
                        .frame(width: 60, height: 90)
                        .cornerRadius(6)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(anime.title)
                        .font(.headline)
                        .lineLimit(2)

                    if let studios = anime.studios, !studios.isEmpty {
                        Text(studios.joined(separator: ", "))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal)
    }
}

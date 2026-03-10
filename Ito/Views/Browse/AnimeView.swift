import SwiftUI
import Nuke
import NukeUI
import ito_runner

struct IdentifiableEpisode: Identifiable {
    let id: String
    let episode: Anime.Episode
    init(_ episode: Anime.Episode) {
        self.id = episode.key
        self.episode = episode
    }
}

struct AnimeView: View {
    let runner: ItoRunner
    @State var anime: Anime
    let pluginId: String

    @State private var isLoaded = false
    @State private var errorMessage: String?
    @State private var watchingEpisode: IdentifiableEpisode?
    @State private var selectedSeason: String?

    @State private var showTrackerSearch = false
    @State private var showTrackerEdit = false
    @State private var trackingMedia: AnilistMedia?
    @State private var isDescriptionExpanded = false

    @ObservedObject var libraryManager = LibraryManager.shared
    @EnvironmentObject var progressManager: ReadProgressManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header: Cover + Info
                HStack(alignment: .top, spacing: 16) {
                    if let coverURL = anime.cover, let url = URL(string: coverURL) {
                        LazyImage(url: url) { state in
                            if let image = state.image {
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 100, height: 150)
                                    .cornerRadius(8)
                                    .clipped()
                            } else if state.error != nil {
                                Color.red.opacity(0.3)
                                    .frame(width: 100, height: 150)
                                    .cornerRadius(8)
                            } else {
                                Color.gray.opacity(0.3)
                                    .frame(width: 100, height: 150)
                                    .cornerRadius(8)
                            }
                        }
                        .processors([.resize(width: 200)])
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(anime.title)
                            .font(.title2)
                            .fontWeight(.bold)

                        if let studios = anime.studios, !studios.isEmpty {
                            Text("Studio: \(studios.joined(separator: ", "))")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }

                        HStack {
                            if let status = statusText(for: anime.status) {
                                Text(status)
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.secondary.opacity(0.2))
                                    .cornerRadius(4)
                            }

                            Text(pluginId.capitalized)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.secondary.opacity(0.2))
                                .cornerRadius(4)
                        }

                        // Action Buttons
                        HStack(spacing: 12) {
                            Button(action: {
                                LibraryManager.shared.toggleSaveAnime(anime: anime, pluginId: pluginId)
                            }) {
                                HStack {
                                    Image(systemName: libraryManager.isSaved(id: anime.key) ? "bookmark.fill" : "bookmark")
                                    Text(libraryManager.isSaved(id: anime.key) ? "Saved" : "Save")
                                }
                                .font(.subheadline)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.blue.opacity(0.2))
                                .foregroundColor(.blue)
                                .cornerRadius(6)
                            }

                            // Tracker Sync Button
                            if TrackerManager.shared.isAnilistAuthenticated {
                                Button(action: {
                                    if let existingId = TrackerManager.shared.getAnilistId(for: anime.key) {
                                        // Construct a partial AnilistMedia object since we only need the ID to fetch details
                                        self.trackingMedia = AnilistMedia(id: existingId, title: anime.title, titleRomaji: nil, coverImage: anime.cover, format: "TV", episodes: nil, chapters: nil)
                                    } else {
                                        showTrackerSearch = true
                                    }
                                }) {
                                    HStack {
                                        Image(systemName: TrackerManager.shared.getAnilistId(for: anime.key) != nil ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                                        Text(TrackerManager.shared.getAnilistId(for: anime.key) != nil ? "Tracking" : "Track")
                                    }
                                    .font(.subheadline)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(TrackerManager.shared.getAnilistId(for: anime.key) != nil ? Color.purple.opacity(0.2) : Color.green.opacity(0.2))
                                    .foregroundColor(TrackerManager.shared.getAnilistId(for: anime.key) != nil ? .purple : .green)
                                    .cornerRadius(6)
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(.horizontal)
                .sheet(isPresented: $showTrackerSearch) {
                    TrackerSearchSheet(title: anime.title, isAnime: true) { media, progress in
                        print("Tracked: \(media.title) (ID: \(media.id))")

                        // Link the tracker ID even if not saved in Library
                        TrackerManager.shared.link(localId: anime.key, anilistId: media.id)

                        if let prog = progress, UserDefaults.standard.object(forKey: "Ito.AutoSyncAnilistToLocal") as? Bool ?? true {
                            ReadProgressManager.shared.markReadUpTo(mangaId: anime.key, maxChapterNum: Float(prog))
                        }
                    }
                }
                .sheet(item: $trackingMedia) { media in
                    TrackerDetailsSheet(media: media, onSave: { progress in
                        if let prog = progress, UserDefaults.standard.object(forKey: "Ito.AutoSyncAnilistToLocal") as? Bool ?? true {
                            ReadProgressManager.shared.markReadUpTo(mangaId: anime.key, maxChapterNum: Float(prog))
                        }
                    }, onDelete: {
                        TrackerManager.shared.unlink(localId: anime.key)
                    })
                }

                // Tags
                if let tags = anime.tags, !tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(tags, id: \.self) { tag in
                                Text(tag)
                                    .font(.caption)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(Color.gray.opacity(0.15))
                                    .cornerRadius(12)
                            }
                        }
                        .padding(.horizontal)
                    }
                }

                // Description
                if let description = anime.description, !description.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(description)
                            .font(.body)
                            .lineLimit(isDescriptionExpanded ? nil : 3)

                        Text(isDescriptionExpanded ? "Tap to show less" : "Tap to show more")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.blue)
                    }
                    .padding(.horizontal)
                    .contentShape(Rectangle()) // Makes the whole VStack tappable
                    .onTapGesture {
                        withAnimation {
                            isDescriptionExpanded.toggle()
                        }
                    }
                }

                Divider()
                    .padding(.vertical, 8)

                Text("Episodes")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .padding(.horizontal)

                if let seasons = anime.seasons, !seasons.isEmpty {
                    Picker("Season", selection: $selectedSeason) {
                        ForEach(seasons, id: \.key) { season in
                            Text(season.title).tag(season.key as String?)
                        }
                    }
                    .pickerStyle(.menu)
                    .padding(.horizontal)
                }

                // Episode List
                if isLoaded {
                    if let episodes = anime.episodes, !episodes.isEmpty {
                        LazyVStack(spacing: 0) {
                            ForEach(episodes, id: \.key) { episode in
                                let isWatched = progressManager.isRead(mangaId: anime.key, chapterId: episode.key, chapterNum: episode.episode)

                                Button(action: {
                                    self.watchingEpisode = IdentifiableEpisode(episode)
                                }) {
                                    HStack(alignment: .top) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(episodeTitle(for: episode))
                                                .font(.headline)
                                                .fontWeight(isWatched ? .regular : .semibold)
                                                .foregroundColor(isWatched ? .secondary : .primary)

                                            if let date = episode.dateUpdated {
                                                Text(formatDate(date))
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                            }
                                        }

                                        Spacer()

                                        if isWatched {
                                            Image(systemName: "checkmark.circle")
                                                .foregroundColor(.secondary)
                                                .padding(.trailing, 4)
                                        } else if let lang = episode.lang {
                                            Text(lang)
                                                .font(.caption2)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.secondary.opacity(0.2))
                                                .cornerRadius(4)
                                        }

                                        Image(systemName: "play.circle")
                                            .font(.title2)
                                            .foregroundColor(isWatched ? .secondary : .blue)
                                    }
                                    .padding(.vertical, 12)
                                    .padding(.horizontal)
                                    .contentShape(Rectangle())
                                    .opacity(isWatched ? 0.6 : 1.0)
                                }
                                .buttonStyle(PlainButtonStyle())

                                Divider()
                            }
                        }
                    } else {
                        Text("No episodes found.")
                            .foregroundColor(.secondary)
                            .padding(.horizontal)
                    }
                } else if errorMessage != nil {
                    Text("Failed to load details.")
                        .foregroundColor(.red)
                        .padding(.horizontal)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding()
                }
            }
            .padding(.vertical)
        }
        .navigationTitle("Anime Details")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $watchingEpisode) { identified in
            VideoPlayerView(
                runner: runner,
                anime: anime,
                episode: identified.episode
            )
        }
        .task {
            await loadDetails()
        }
    }

    private func loadDetails() async {
        guard !isLoaded else { return }
        do {
            let updatedAnime = try await runner.getAnimeUpdate(
                anime: anime, needsDetails: true, needsEpisodes: true)
            await MainActor.run {
                self.anime = updatedAnime
                if let firstSeason = updatedAnime.seasons?.first(where: { $0.isCurrent })
                    ?? updatedAnime.seasons?.first {
                    self.selectedSeason = firstSeason.key
                }
                self.isLoaded = true
            }
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.isLoaded = true
            }
        }
    }

    private func statusText(for status: Anime.Status) -> String? {
        switch status {
        case .Unknown: return nil
        case .Ongoing: return "Ongoing"
        case .Completed: return "Completed"
        case .Cancelled: return "Cancelled"
        case .Hiatus: return "Hiatus"
        }
    }

    private func episodeTitle(for episode: Anime.Episode) -> String {
        if let title = episode.title, !title.isEmpty {
            return title
        } else if let num = episode.episode {
            return
                "Episode \(num.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", num) : String(num))"
        } else {
            return "Episode"
        }
    }

    private func formatDate(_ timestamp: Double) -> String {
        let date = Date(timeIntervalSince1970: timestamp)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

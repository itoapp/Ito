import SwiftUI
import ito_runner

struct IdentifiableChapter: Identifiable {
    let id: String
    let chapter: Manga.Chapter
    init(_ chapter: Manga.Chapter) {
        self.id = chapter.key
        self.chapter = chapter
    }
}

struct MangaView: View {
    let runner: ItoRunner
    @State var manga: Manga
    let pluginId: String

    @State private var isLoaded = false
    @State private var errorMessage: String? = nil
    @State private var readingChapter: IdentifiableChapter? = nil
    
    @State private var showTrackerSearch = false
    @State private var showTrackerEdit = false
    @State private var trackingMedia: AnilistMedia? = nil

    @EnvironmentObject var progressManager: ReadProgressManager
    @ObservedObject var libraryManager = LibraryManager.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header: Cover + Info
                HStack(alignment: .top, spacing: 16) {
                    if let coverURL = manga.cover, let url = URL(string: coverURL) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .empty:
                                Color.gray.opacity(0.3)
                                    .frame(width: 100, height: 150)
                                    .cornerRadius(8)
                            case .success(let image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 100, height: 150)
                                    .cornerRadius(8)
                                    .clipped()
                            case .failure:
                                Color.red.opacity(0.3)
                                    .frame(width: 100, height: 150)
                                    .cornerRadius(8)
                            @unknown default:
                                EmptyView()
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(manga.title)
                            .font(.title2)
                            .fontWeight(.bold)

                        if let artist = manga.artist, !artist.isEmpty {
                            Text("Artist: \(artist)")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        } else if let authors = manga.authors, !authors.isEmpty {
                            Text("Author: \(authors.joined(separator: ", "))")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }

                        HStack {
                            if let status = statusText(for: manga.status) {
                                Text(status)
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.blue.opacity(0.1))
                                    .foregroundColor(.blue)
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
                                LibraryManager.shared.toggleSaveManga(manga: manga, pluginId: pluginId)
                            }) {
                                HStack {
                                    Image(systemName: libraryManager.isSaved(id: manga.key) ? "bookmark.fill" : "bookmark")
                                    Text(libraryManager.isSaved(id: manga.key) ? "Saved" : "Save")
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
                                    if let existingId = LibraryManager.shared.getAnilistId(for: manga.key) {
                                        // Construct a partial AnilistMedia object
                                        self.trackingMedia = AnilistMedia(id: existingId, title: manga.title, titleRomaji: nil, coverImage: manga.cover, format: "MANGA", episodes: nil, chapters: nil)
                                    } else {
                                        showTrackerSearch = true
                                    }
                                }) {
                                    HStack {
                                        Image(systemName: LibraryManager.shared.getAnilistId(for: manga.key) != nil ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                                        Text(LibraryManager.shared.getAnilistId(for: manga.key) != nil ? "Tracking" : "Track")
                                    }
                                    .font(.subheadline)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(LibraryManager.shared.getAnilistId(for: manga.key) != nil ? Color.purple.opacity(0.2) : Color.green.opacity(0.2))
                                    .foregroundColor(LibraryManager.shared.getAnilistId(for: manga.key) != nil ? .purple : .green)
                                    .cornerRadius(6)
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(.horizontal)
                .sheet(isPresented: $showTrackerSearch) {
                    TrackerSearchSheet(title: manga.title, isAnime: false) { media in
                        print("Tracked: \(media.title) (ID: \(media.id))")
                        LibraryManager.shared.setAnilistId(for: manga.key, anilistId: media.id)
                    }
                }
                .sheet(item: $trackingMedia) { media in
                    TrackerDetailsSheet(media: media, onSave: {
                        // Refresh
                    }, onDelete: {
                        LibraryManager.shared.removeAnilistId(for: manga.key)
                    })
                }

                // Tags
                if let tags = manga.tags, !tags.isEmpty {
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
                if let description = manga.description, !description.isEmpty {
                    Text(description)
                        .font(.body)
                        .padding(.horizontal)
                }

                Divider()

                // Chapters
                if !isLoaded && errorMessage == nil {
                    ProgressView("Loading Chapters...")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding()
                } else if let error = errorMessage {
                    Text("Error: \(error)")
                        .foregroundColor(.red)
                        .padding()
                } else {
                    if let chapters = manga.chapters, !chapters.isEmpty {

                        // Read / Resume Button
                        if let target = resumeReadingChapter {
                            let isResume = progressManager.getLastRead(mangaId: manga.key) != nil
                            Button(action: {
                                self.readingChapter = IdentifiableChapter(target)
                            }) {
                                HStack {
                                    Image(systemName: isResume ? "book.fill" : "play.fill")
                                    Text(isResume ? "Resume Reading" : "Start Reading")
                                        .fontWeight(.semibold)
                                }
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(12)
                            }
                            .padding(.horizontal)
                            .padding(.bottom, 8)
                        }

                        Text("Chapters")
                            .font(.title2)
                            .fontWeight(.bold)
                            .padding(.horizontal)

                        LazyVStack(spacing: 0) {
                            ForEach(chapters, id: \.key) { chapter in
                                let isRead = progressManager.isRead(
                                    mangaId: manga.key, chapterId: chapter.key, chapterNum: chapter.chapter)

                                Button(action: {
                                    self.readingChapter = IdentifiableChapter(chapter)
                                }) {
                                    HStack(alignment: .center, spacing: 12) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            if let title = chapter.title, !title.isEmpty {
                                                Text(title)
                                                    .font(.body)
                                                    .fontWeight(isRead ? .regular : .semibold)
                                                    .foregroundColor(isRead ? .secondary : .primary)
                                                    .lineLimit(2)
                                            } else {
                                                Text("Chapter \(chapter.chapter ?? 0)")
                                                    .font(.body)
                                                    .fontWeight(isRead ? .regular : .semibold)
                                                    .foregroundColor(isRead ? .secondary : .primary)
                                                    .lineLimit(1)
                                            }

                                            HStack(spacing: 6) {
                                                if let date = chapter.dateUpdated {
                                                    Text(
                                                        "\(Date(timeIntervalSince1970: TimeInterval(date)).formatted(.dateTime.year().month().day()))"
                                                    )
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                                }
                                                
                                                if let scanlator = chapter.scanlator {
                                                    Text("•")
                                                        .font(.caption)
                                                        .foregroundColor(.secondary)
                                                    Text(scanlator)
                                                        .font(.caption)
                                                        .foregroundColor(.secondary)
                                                        .lineLimit(1)
                                                }
                                            }
                                        }

                                        Spacer()

                                        // Paywall logic
                                        if let paywalled = chapter.paywalled, paywalled {
                                            Image(systemName: "lock.fill")
                                                .foregroundColor(.yellow)
                                                .font(.caption)
                                                .padding(6)
                                                .background(Color.yellow.opacity(0.2))
                                                .clipShape(Circle())
                                        } else if isRead {
                                            Image(systemName: "checkmark.circle")
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    .padding()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color(.systemBackground))
                                    // Slight dimming for the entire row if read
                                    .opacity(isRead ? 0.6 : 1.0)
                                }
                                .buttonStyle(.plain)

                                Divider()
                            }
                        }
                    } else {
                        Text("No chapters found.")
                            .foregroundColor(.secondary)
                            .padding()
                    }
                }
            }
            .padding(.vertical)
        }
        .navigationTitle(manga.title)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $readingChapter) { wrapper in
            ReaderView(runner: runner, manga: manga, currentChapter: wrapper.chapter)
        }
        .task {
            await loadDetails()
        }
    }

    private func loadDetails() async {
        guard !isLoaded else { return }
        do {
            let updatedManga = try await runner.getMangaUpdate(manga: manga)
            await MainActor.run {
                self.manga = updatedManga
                self.isLoaded = true
            }
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.isLoaded = true
            }
        }
    }

    private var resumeReadingChapter: Manga.Chapter? {
        guard let chapters = manga.chapters, !chapters.isEmpty else { return nil }

        // If we have a last read chapter, try to find it
        if let lastReadId = progressManager.getLastRead(mangaId: manga.key),
            let lastRead = chapters.first(where: { $0.key == lastReadId })
        {
            return lastRead
        }

        // Otherwise, return the chronologically first chapter (which is typically the last element in the array)
        return chapters.last
    }

    private func statusText(for status: Manga.Status) -> String? {
        switch status {
        case .Ongoing: return "Ongoing"
        case .Completed: return "Completed"
        case .Cancelled: return "Cancelled"
        case .Hiatus: return "Hiatus"
        case .Unknown: return nil
        }
    }
}

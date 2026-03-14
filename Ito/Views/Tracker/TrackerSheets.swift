import SwiftUI
import NukeUI

struct TrackerSearchSheet: View {
    let title: String
    let isAnime: Bool

    @State private var searchQuery: String
    @State private var searchResults: [AnilistMedia] = []
    @State private var isLoading = false
    @State private var selectedMedia: AnilistMedia?
    @State private var errorMessage: String?

    @State private var showDetailsSheet = false

    // Updated: Now expects the media, the progress, and the selected status
    var onTrack: (AnilistMedia, Int?, String?) -> Void
    @Environment(\.dismiss) var dismiss

    init(title: String, isAnime: Bool, onTrack: @escaping (AnilistMedia, Int?, String?) -> Void) {
        self.title = title
        self.isAnime = isAnime
        self._searchQuery = State(initialValue: title)
        self.onTrack = onTrack
    }

    var body: some View {
        NavigationView {
            VStack {
                // Search Bar
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.gray)
                    TextField("Search", text: $searchQuery, onCommit: performSearch)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    if isLoading {
                        ProgressView()
                    }
                }
                .padding()

                if let error = errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                        .padding(.horizontal)
                }

                List(searchResults) { media in
                    HStack {
                        if let cover = media.coverImage, let url = URL(string: cover) {
                            LazyImage(url: url) { state in
                                if let image = state.image {
                                    image.resizable().aspectRatio(contentMode: .fill)
                                } else {
                                    Color.gray.opacity(0.3)
                                }
                            }
                            .frame(width: 50, height: 75)
                            .cornerRadius(4)
                        }

                        VStack(alignment: .leading) {
                            Text(media.title)
                                .font(.headline)
                                .lineLimit(2)
                            if let romaji = media.titleRomaji {
                                Text(romaji)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                            Text(media.format ?? (isAnime ? "Anime" : "Manga"))
                                .font(.caption2)
                                .padding(4)
                                .background(Color.blue.opacity(0.1))
                                .cornerRadius(4)
                        }

                        Spacer()

                        if selectedMedia?.id == media.id {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.title2)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        self.selectedMedia = media
                    }
                }

                ZStack {
                    if let selectedMedia = selectedMedia {
                        NavigationLink(
                            destination: TrackerDetailsSheet(media: selectedMedia, onSave: { progress, newStatus in
                                // Updated: Passing the newStatus back to the parent closure
                                onTrack(selectedMedia, progress, newStatus)
                                showDetailsSheet = false
                                dismiss() // Dismiss the search sheet itself
                            }),
                            isActive: $showDetailsSheet
                        ) {
                            EmptyView()
                        }
                    }

                    Button(action: {
                        if selectedMedia != nil {
                            // Launch details sheet via NavigationLink activation
                            showDetailsSheet = true
                        }
                    }) {
                        Text("Select Series")
                            .fontWeight(.bold)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(selectedMedia == nil ? Color.gray : Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                    .disabled(selectedMedia == nil)
                }
                .padding()
            }
            .navigationTitle("Track Series")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(trailing: Button("Cancel") { dismiss() })
            .task {
                performSearch()
            }
        }
    }

    private func performSearch() {
        guard !searchQuery.isEmpty else { return }
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let results = try await TrackerManager.shared.searchAnilistMediaFull(title: searchQuery, isAnime: isAnime)
                await MainActor.run {
                    self.searchResults = results
                    self.isLoading = false

                    // Auto-select first match if it's highly relevant (optional)
                    if let first = results.first, first.title.lowercased() == searchQuery.lowercased() {
                        self.selectedMedia = first
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }
}

struct TrackerDetailsSheet: View {
    let media: AnilistMedia
    var showCancelButton: Bool = false

    // Updated: Closure now accepts progress and status string
    var onSave: (Int?, String?) -> Void
    var onDelete: (() -> Void)?

    @State private var status: String? = "PLANNING"
    @State private var progress: String = "0"
    @State private var score: Double = 0
    @State private var startDate = Date()
    // Changed to optional so we don't force a finish date
    @State private var finishDate: Date?
    @State private var isSaving = false
    @State private var isLoadingEntry = true

    // Tracks if we actually fetched a remote entry or if this is a fresh form
    @State private var isNewEntry = true

    let statuses = ["CURRENT", "PLANNING", "COMPLETED", "DROPPED", "PAUSED", "REPEATING"]

    private var currentStatusLabel: String {
        let format = media.format ?? ""
        if format == "MANGA" || format == "NOVEL" || format == "ONE_SHOT" {
            return "Reading"
        } else {
            return "Watching"
        }
    }

    private func displayLabel(for statusOption: String) -> String {
        if statusOption == "CURRENT" {
            return currentStatusLabel
        }
        return statusOption.capitalized
    }

    @State private var showSyncAlert = false
    @State private var maxLocalProgress: Int?

    @Environment(\.dismiss) var dismiss

    var body: some View {
        Form {
                if isLoadingEntry {
                    HStack {
                        Spacer()
                        ProgressView("Checking existing progress...")
                        Spacer()
                    }
                } else {
                    Section(header: Text("Series Info")) {
                        HStack {
                            if let cover = media.coverImage, let url = URL(string: cover) {
                                LazyImage(url: url) { state in
                                    if let image = state.image {
                                        image.resizable().aspectRatio(contentMode: .fill)
                                    } else {
                                        Color.gray
                                    }
                                }
                                .frame(width: 60, height: 90)
                                .cornerRadius(6)
                            }
                            Text(media.title)
                                .font(.headline)
                        }
                    }

                    Section(header: Text("Progress")) {
                        Picker("Status", selection: $status) {
                            ForEach(statuses, id: \.self) { statusOption in
                                Text(displayLabel(for: statusOption))
                                    .tag(String?.some(statusOption))
                            }
                        }

                        HStack {
                            Text("Progress")
                            Spacer()
                            TextField("0", text: $progress)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 50)

                            Stepper("", onIncrement: {
                                if let val = Int(progress) { progress = String(val + 1) }
                            }, onDecrement: {
                                if let val = Int(progress), val > 0 { progress = String(val - 1) }
                            })
                            .labelsHidden()

                            if let total = media.episodes ?? media.chapters {
                                Text("/ \(total)")
                                    .foregroundColor(.secondary)
                            } else {
                                Text("/ ?")
                                    .foregroundColor(.secondary)
                            }
                        }

                        HStack {
                            Text("Score")
                            Spacer()
                            Slider(value: $score, in: 0...10, step: 0.5)
                            Text(String(format: "%.1f", score))
                        }
                    }

                    Section(header: Text("Dates")) {
                        // Always show Started Date
                        DatePicker("Started", selection: $startDate, displayedComponents: .date)

                        // Only show Finished Date if it exists or if status is Completed/Dropped,
                        // otherwise offer a toggle or just use an optional binding
                        if finishDate != nil {
                            DatePicker("Finished", selection: Binding(get: { finishDate ?? Date() }, set: { finishDate = $0 }), displayedComponents: .date)
                            Button("Remove Finish Date") {
                                finishDate = nil
                            }
                            .foregroundColor(.red)
                        } else {
                            Button("Add Finish Date") {
                                finishDate = Date()
                            }
                        }
                    }
                    Section {
                        Button(action: {
                            calculateLocalProgress()
                        }) {
                            Label("Sync Local History", systemImage: "arrow.triangle.2.circlepath")
                        }

                        Button(action: {
                            let urlStr = media.format == "MANGA" || media.format == "NOVEL" || media.format == "ONE_SHOT"
                                ? "https://anilist.co/manga/\(media.id)"
                                : "https://anilist.co/anime/\(media.id)"
                            if let url = URL(string: urlStr) {
                                UIApplication.shared.open(url)
                            }
                        }) {
                            Label("View on AniList", systemImage: "safari")
                        }

                        if !isNewEntry {
                            Button(role: .destructive, action: {
                                if let onDelete = onDelete {
                                    onDelete()
                                }
                                dismiss()
                            }) {
                                Label("Stop Tracking", systemImage: "trash")
                                    .foregroundColor(.red)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Update Entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if showCancelButton {
                        // Updated: pass nil for both progress and status when canceling
                        Button("Cancel") { onSave(nil, nil); dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: saveProgress) {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text("Save").fontWeight(.bold)
                        }
                    }
                }
            }
            .alert("Sync Local History", isPresented: $showSyncAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Sync") {
                    if let maxLoc = maxLocalProgress {
                        self.progress = String(maxLoc)
                    }
                }
            } message: {
                if let maxLoc = maxLocalProgress {
                    Text("We found local reading/watching history up to chapter/episode \(maxLoc). Do you want to update your AniList progress to match?")
                } else {
                    Text("No local reading or watching history was found for this series.")
                }
            }
            .task {
                guard isLoadingEntry else { return }
                await fetchExistingEntry()
            }
            .onChange(of: progress) { newValue in
                if let val = Int(newValue), val > 0, status == "PLANNING" {
                    status = "CURRENT"
                }
            }
    }

    private func calculateLocalProgress() {
        // Find if we have a mapping to this AniList ID
        let matchingMappings = TrackerManager.shared.trackerMappings.filter { $0.value == media.id }

        // Find the maximum progress across any mapped local items (or fallback to LibraryManager search)
        var highest: Int?

        for (localId, _) in matchingMappings {
            if let readNumbers = ReadProgressManager.shared.readChapterNumbers[localId], let maxNum = readNumbers.max() {
                if let current = highest {
                    highest = max(current, Int(maxNum))
                } else {
                    highest = Int(maxNum)
                }
            }
        }

        // Backward compatibility: If no mapping found in TrackerManager, check LibraryManager directly
        if highest == nil {
            if let matchingItem = LibraryManager.shared.items.first(where: { $0.anilistId == media.id }) {
                if let readNumbers = ReadProgressManager.shared.readChapterNumbers[matchingItem.id] {
                    if let maxNum = readNumbers.max() {
                        highest = Int(maxNum)
                    }
                }
            }
        }

        self.maxLocalProgress = highest
        self.showSyncAlert = true
    }

    private func fetchExistingEntry() async {
        do {
            if let entry = try await TrackerManager.shared.getMediaListEntry(mediaId: media.id) {
                print("Found existing entry: \(entry)")
                await MainActor.run {
                    self.isNewEntry = false

                    if let statusStr = entry["status"] as? String {
                        self.status = statusStr
                    } else {
                        self.status = "PLANNING"
                    }
                    if let prog = entry["progress"] as? Int {
                        self.progress = String(prog)
                    }
                    if let scoreVal = entry["score"] as? Double {
                        self.score = scoreVal
                    }

                    // Parse Dates if available
                    if let start = entry["startedAt"] as? [String: Any?],
                       let year = start["year"] as? Int, let month = start["month"] as? Int, let day = start["day"] as? Int {
                        var components = DateComponents()
                        components.year = year
                        components.month = month
                        components.day = day
                        if let date = Calendar.current.date(from: components) {
                            self.startDate = date
                        }
                    }

                    if let end = entry["completedAt"] as? [String: Any?],
                       let year = end["year"] as? Int, let month = end["month"] as? Int, let day = end["day"] as? Int {
                        var components = DateComponents()
                        components.year = year
                        components.month = month
                        components.day = day
                        if let date = Calendar.current.date(from: components) {
                            self.finishDate = date
                        }
                    }
                }
            } else {
                // No entry found, treat as new.
                // Default start/finish dates are already set to Date() by state initialization.
                // We keep them as is so user can just hit save.
                await MainActor.run {
                    self.isNewEntry = true
                }
            }
        } catch {
            print("Failed to fetch existing entry: \(error)")
            // If error (e.g. 404 or auth error), assume new entry or offline
            await MainActor.run {
                self.isNewEntry = true
            }
        }

        await MainActor.run {
            self.isLoadingEntry = false
        }
    }

    private func saveProgress() {
            isSaving = true
            Task {
                var savedProgress: Int?
                let progInt = Int(progress)
                let effectiveStatus = status

                do {
                    try await TrackerManager.shared.updateProgress(mediaId: media.id, progress: progInt, status: effectiveStatus)
                    savedProgress = progInt
                } catch {
                    print("Failed saving TrackerProgress with status: \(error.localizedDescription)")
                }

                await MainActor.run {
                    isSaving = false
                    onSave(savedProgress, effectiveStatus)
                    dismiss() // NEW: Tell the sheet to close after saving!
                }
            }
        }
}

// Data Model for Search
public struct AnilistMedia: Identifiable, Codable {
    public let id: Int
    public let title: String
    public let titleRomaji: String?
    public let coverImage: String?
    public let format: String?
    public let episodes: Int?
    public let chapters: Int?
}

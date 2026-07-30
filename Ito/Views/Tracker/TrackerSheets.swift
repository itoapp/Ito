import OSLog
import SwiftUI
import NukeUI

public struct TrackerSheetOrchestrator: View {
    let mediaIdentity: MediaIdentity
    let title: String
    let isAnime: Bool
    var onTracked: ((TrackerMedia, Int?, String?) -> Void)?

    @Environment(\.dismiss) var dismiss
    @EnvironmentObject private var trackerManager: TrackerManager

    @State private var selectedProvider: (any TrackerProvider)?
    @State private var showPersistenceError = false

    public init(
        mediaIdentity: MediaIdentity,
        title: String,
        isAnime: Bool,
        onTracked: ((TrackerMedia, Int?, String?) -> Void)? = nil
    ) {
        self.mediaIdentity = mediaIdentity
        self.title = title
        self.isAnime = isAnime
        self.onTracked = onTracked
    }

    public var body: some View {
        let authenticatedProviders = trackerManager.authenticatedProviders

        if authenticatedProviders.isEmpty {
            NavigationView {
                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 50))
                        .foregroundColor(.orange)
                    Text("No Trackers Authenticated")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("Please go to Settings > Trackers to log in to a service like AniList before tracking.")
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                }
                .navigationTitle("Track Series")
                .navigationBarTitleDisplayMode(.inline)
                .navigationBarItems(trailing: Button("Close") { dismiss() })
            }
        } else if authenticatedProviders.count == 1 {
            // Bypass selection
            let provider = authenticatedProviders.first!
            if let existingId = trackerManager.trackerId(for: mediaIdentity, providerId: provider.identifier) {
                let media = TrackerMedia(id: existingId, title: title, titleRomaji: nil, coverImage: nil, format: nil, episodes: nil, chapters: nil)
                NavigationView {
                    TrackerDetailsSheet(provider: provider, mediaIdentity: mediaIdentity, media: media, showCancelButton: true, onSave: { progress, status in
                        onTracked?(media, progress, status)
                        dismiss()
                        return true
                    }, onDelete: {
                        onTracked?(media, nil, nil) // notify deleted
                    })
                }
            } else {
                TrackerSearchSheet(provider: provider, mediaIdentity: mediaIdentity, title: title, isAnime: isAnime) { media, progress, status in
                    await linkAndPublish(media, provider: provider, progress: progress, status: status)
                }
                .alert("Tracker Change Not Saved", isPresented: $showPersistenceError) {
                    Button("OK", role: .cancel) { }
                } message: {
                    Text("Your tracker change couldn't be saved. Please try again.")
                }
            }
        } else {
            // Selection Sheet
            if let provider = selectedProvider {
                if let existingId = trackerManager.trackerId(for: mediaIdentity, providerId: provider.identifier) {
                    let media = TrackerMedia(id: existingId, title: title, titleRomaji: nil, coverImage: nil, format: nil, episodes: nil, chapters: nil)
                    TrackerDetailsSheet(provider: provider, mediaIdentity: mediaIdentity, media: media, showCancelButton: true, onSave: { progress, status in
                        onTracked?(media, progress, status)
                        dismiss()
                        return true
                    }, onDelete: {
                        onTracked?(media, nil, nil)
                    })
                } else {
                    TrackerSearchSheet(provider: provider, mediaIdentity: mediaIdentity, title: title, isAnime: isAnime) { media, progress, status in
                        await linkAndPublish(media, provider: provider, progress: progress, status: status)
                    }
                    .alert("Tracker Change Not Saved", isPresented: $showPersistenceError) {
                        Button("OK", role: .cancel) { }
                    } message: {
                        Text("Your tracker change couldn't be saved. Please try again.")
                    }
                }
            } else {
                NavigationView {
                    List(authenticatedProviders, id: \.identifier) { provider in
                        Button(action: {
                            selectedProvider = provider
                        }) {
                            HStack {
                                Text(provider.name)
                                    .foregroundColor(.primary)
                                Spacer()
                                if trackerManager.trackerId(for: mediaIdentity, providerId: provider.identifier) != nil {
                                    Text("Tracked")
                                        .font(.caption)
                                        .foregroundColor(.green)
                                        .padding(.trailing, 4)
                                }
                                Image(systemName: "chevron.right")
                                    .foregroundColor(.gray)
                            }
                        }
                    }
                    .navigationTitle("Select Tracker")
                    .navigationBarTitleDisplayMode(.inline)
                    .navigationBarItems(trailing: Button("Cancel") { dismiss() })
                }
                .modifier(PresentationDetentsModifier())
            }
        }
    }

    private func linkAndPublish(
        _ media: TrackerMedia,
        provider: any TrackerProvider,
        progress: Int?,
        status: String?
    ) async -> Bool {
        do {
            try await trackerManager.link(
                media: mediaIdentity,
                providerId: provider.identifier,
                remoteMediaId: media.id
            )
            onTracked?(media, progress, status)
            return true
        } catch {
            showPersistenceError = true
            return false
        }
    }
}

struct PresentationDetentsModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.presentationDetents([.medium, .large])
        } else {
            content
        }
    }
}

struct TrackerSearchSheet: View {
    let provider: any TrackerProvider
    let mediaIdentity: MediaIdentity
    let title: String
    let isAnime: Bool

    @State private var searchQuery: String
    @State private var searchResults: [TrackerMedia] = []
    @State private var isLoading = false
    @State private var selectedMedia: TrackerMedia?
    @State private var errorMessage: String?

    @State private var showDetailsSheet = false

    var onTrack: (TrackerMedia, Int?, String?) async -> Bool
    @Environment(\.dismiss) var dismiss

    init(
        provider: any TrackerProvider,
        mediaIdentity: MediaIdentity,
        title: String,
        isAnime: Bool,
        onTrack: @escaping (TrackerMedia, Int?, String?) async -> Bool
    ) {
        self.provider = provider
        self.mediaIdentity = mediaIdentity
        self.title = title
        self.isAnime = isAnime
        self._searchQuery = State(initialValue: title)
        self.onTrack = onTrack
    }

    var body: some View {
        NavigationView {
            VStack {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.gray)
                    TextField("Search \(provider.name)", text: $searchQuery, onCommit: performSearch)
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
                            destination: TrackerDetailsSheet(provider: provider, mediaIdentity: mediaIdentity, media: selectedMedia, onSave: { progress, newStatus in
                                let didTrack = await onTrack(selectedMedia, progress, newStatus)
                                if didTrack {
                                    showDetailsSheet = false
                                    dismiss()
                                }
                                return didTrack
                            }),
                            isActive: $showDetailsSheet
                        ) {
                            EmptyView()
                        }
                    }

                    Button(action: {
                        if selectedMedia != nil {
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
            .navigationTitle("Search on \(provider.name)")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(leading: Button("Back") { dismiss() }, trailing: Button("Cancel") { dismiss() })
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
                let results = try await provider.searchMedia(title: searchQuery, isAnime: isAnime)
                await MainActor.run {
                    self.searchResults = results
                    self.isLoading = false
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
    let provider: any TrackerProvider
    let mediaIdentity: MediaIdentity
    let media: TrackerMedia
    var showCancelButton: Bool = false

    var onSave: (Int?, String?) async -> Bool
    var onDelete: (() -> Void)?

    @State private var status: String? = "PLANNING"
    @State private var progress: String = "0"
    @State private var score: Double = 0
    @State private var startDate = Date()
    @State private var finishDate: Date?
    @State private var isSaving = false
    @State private var isUnlinking = false
    @State private var isLoadingEntry = true
    @State private var isNewEntry = true
    @State private var showPersistenceError = false

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
    @EnvironmentObject private var progressManager: ReadProgressManager
    @EnvironmentObject private var trackerManager: TrackerManager

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
                    DatePicker("Started", selection: $startDate, displayedComponents: .date)

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
                        Label("View on \(provider.name)", systemImage: "safari")
                    }

                    if !isNewEntry {
                        Button(role: .destructive, action: stopTracking) {
                            HStack {
                                if isUnlinking {
                                    ProgressView()
                                        .accessibilityLabel("Stopping tracking")
                                }
                                Label("Stop Tracking", systemImage: "trash")
                                    .foregroundColor(.red)
                            }
                        }
                        .disabled(isUnlinking)
                    }
                }
            }
        }
        .navigationTitle("Update Entry")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if showCancelButton {
                    Button("Cancel") {
                        Task { @MainActor in
                            _ = await onSave(nil, nil)
                            dismiss()
                        }
                    }
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
                Text("We found local reading/watching history up to chapter/episode \(maxLoc). Do you want to update your \(provider.name) progress to match?")
            } else {
                Text("No local reading or watching history was found for this series.")
            }
        }
        .alert("Tracker Change Not Saved", isPresented: $showPersistenceError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Your tracker change couldn't be saved. Please try again.")
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

    private func stopTracking() {
        isUnlinking = true
        Task { @MainActor in
            do {
                try await trackerManager.unlink(
                    media: mediaIdentity,
                    providerId: provider.identifier
                )
                onDelete?()
                dismiss()
            } catch {
                isUnlinking = false
                showPersistenceError = true
            }
        }
    }

    private func calculateLocalProgress() {
        if let maxNum = progressManager.readChapterNumbers(for: mediaIdentity).max() {
            self.maxLocalProgress = Int(maxNum)
            self.showSyncAlert = true
        } else {
            self.maxLocalProgress = nil
            self.showSyncAlert = true
        }
    }

    private func fetchExistingEntry() async {
        do {
            if let entry = try await provider.getMediaListEntry(mediaId: media.id) {
                await MainActor.run {
                    self.isNewEntry = false

                    if let statusStr = entry.status {
                        self.status = statusStr
                    } else {
                        self.status = "PLANNING"
                    }
                    if let prog = entry.progress {
                        self.progress = String(prog)
                    }
                    if let scoreVal = entry.score {
                        self.score = scoreVal
                    }
                    if let start = entry.startDate {
                        self.startDate = start
                    }
                    if let end = entry.finishDate {
                        self.finishDate = end
                    }
                }
            } else {
                await MainActor.run {
                    self.isNewEntry = true
                }
            }
        } catch {
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
        Task { @MainActor in
            var savedProgress: Int?
            let progInt = Int(progress)
            let effectiveStatus = status

            do {
                try await provider.updateProgress(mediaId: media.id, progress: progInt, status: effectiveStatus)
                savedProgress = progInt
            } catch {
                AppLogger.ui.error("Failed saving TrackerProgress with status: \(error.localizedDescription)")
            }

            isSaving = false
            let shouldDismiss = await onSave(savedProgress, effectiveStatus)
            if shouldDismiss {
                dismiss()
            }
        }
    }
}

import SwiftUI
import Nuke
import NukeUI
import ito_runner

// MARK: - LibraryGroup (avoids tuple inference issues with ForEach)

private struct LibraryGroup: Identifiable {
    let id: String          // section label, e.g. "Anime"
    let icon: String        // SF Symbol name
    let items: [LibraryItem]
}

// MARK: - LibraryView

struct LibraryView: View {
    @StateObject private var libraryManager = LibraryManager.shared
    @StateObject private var updateManager = UpdateManager.shared
    @State private var searchText = ""
    @State private var isEditing = false

    private let columns = [
        GridItem(.adaptive(minimum: 100, maximum: 140), spacing: 12)
    ]

    // Group items by type, preserving a fixed display order.
    // Relies only on effectiveType case matching — no external MediaType reference needed.
    private var groupedItems: [LibraryGroup] {
        let order: [(label: String, icon: String, match: (LibraryItem) -> Bool)] = [
            ("Anime", "play.tv", { $0.effectiveType == .anime }),
            ("Manga", "book.closed", { $0.effectiveType == .manga }),
            ("Novels", "doc.text", { $0.effectiveType == .novel })
        ]
        return order.compactMap { label, icon, match in
            let filtered = filteredItems.filter(match)
            return filtered.isEmpty ? nil : LibraryGroup(id: label, icon: icon, items: filtered)
        }
    }

    private var filteredItems: [LibraryItem] {
        guard !searchText.isEmpty else { return libraryManager.items }
        return libraryManager.items.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationView {
            ZStack(alignment: .top) {
                Group {
                    if libraryManager.items.isEmpty {
                        emptyStateView
                    } else if !searchText.isEmpty && filteredItems.isEmpty {
                        noResultsView
                    } else {
                        contentScrollView
                    }
                }

                // Determinate Progress Banner
                if updateManager.isRefreshing {
                    UpdateProgressBanner(
                        current: updateManager.itemsCheckedCurrentRun,
                        total: updateManager.totalItemsToCheck
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(2)
                }
            }
            .navigationTitle("Library")
            .toolbar { toolbarContent }
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .automatic),
                prompt: "Search library"
            )
        }
        .navigationViewStyle(.stack)
    }

    // MARK: Content

    private var contentScrollView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                ForEach(groupedItems) { group in
                    Section {
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(group.items) { item in
                                LibraryItemView(item: item, isEditing: isEditing)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                    } header: {
                        SectionHeaderView(
                            label: group.id,
                            icon: group.icon,
                            count: group.items.count
                        )
                    }
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 16)
        }
        .refreshable {
            await updateManager.checkForUpdates()
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            HStack(spacing: 16) {
                NavigationLink(destination: HistoryView()) {
                    Image(systemName: "clock.arrow.circlepath")
                }
                if !libraryManager.items.isEmpty {
                    Button {
                        Task {
                            await updateManager.checkForUpdates()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(updateManager.isRefreshing)
                }
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            if !libraryManager.items.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isEditing.toggle()
                    }
                } label: {
                    Text(isEditing ? "Done" : "Edit")
                        .font(.body)
                        .fontWeight(isEditing ? .semibold : .regular)
                }
            }
        }
    }

    // MARK: Empty / No Results States

    private var emptyStateView: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 52, weight: .thin))
                .foregroundStyle(.tertiary)

            Text("Your Library is Empty")
                .font(.title3)
                .fontWeight(.semibold)

            Text("Manga, anime, and novels you save\nwill appear here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 60) // optical center adjustment
    }

    private var noResultsView: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 44, weight: .thin))
                .foregroundStyle(.tertiary)

            Text("No Results")
                .font(.title3)
                .fontWeight(.semibold)

            Text("Nothing in your library matches\n\"\(searchText)\".")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 60)
    }
}

// MARK: - Section Header

struct SectionHeaderView: View {
    let label: String
    let icon: String   // SF Symbol — resolved by LibraryView, no MediaType needed
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(label)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            Text("·  \(count)")
                .font(.subheadline)
                .foregroundStyle(.tertiary)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            // Frosted glass effect using material
            Rectangle()
                .fill(.background)
                .ignoresSafeArea(edges: .horizontal)
        )
    }
}

// MARK: - LibraryItemView

struct LibraryItemView: View {
    let item: LibraryItem
    let isEditing: Bool

    @ObservedObject private var pluginManager = PluginManager.shared
    @StateObject private var updateManager = UpdateManager.shared
    @State private var wiggleAngle: Double = Double.random(in: -1.2...1.2)
    // Separate from isEditing so repeatForever never causes isEditing to re-diff
    @State private var isWiggling: Bool = false

    private var isPluginInstalled: Bool {
        pluginManager.installedPlugins[item.pluginId] != nil
    }

    // Checks if we have an unread badge to show
    private var badgeCount: Int {
        updateManager.unreadCounts[item.id] ?? 0
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Main card tappable area
            NavigationLink(destination: DeferredPluginView(item: item)) {
                cardContent
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(isEditing)
            .contextMenu {
                Button(role: .destructive) {
                    LibraryManager.shared.removeItem(withId: item.id)
                } label: {
                    Label("Remove from Library", systemImage: "trash")
                }
            }

            // Edit mode delete badge (top-leading, iOS home screen pattern)
            if isEditing {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        LibraryManager.shared.removeItem(withId: item.id)
                    }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white, .red)
                        .background(Color.white.clipShape(Circle()).padding(3))
                }
                .offset(x: -6, y: -6)
                .transition(.scale.combined(with: .opacity))
                .zIndex(1)
            }
        }
        // Wiggle driven by isWiggling, not isEditing — prevents badge flicker
        .rotationEffect(.degrees(isWiggling ? wiggleAngle : 0))
        .animation(
            isWiggling
                ? .easeInOut(duration: 0.12).repeatForever(autoreverses: true)
                : .easeInOut(duration: 0.15),
            value: isWiggling
        )
        .onChange(of: isEditing) { editing in
            withAnimation {
                isWiggling = editing
            }
        }
    }

    // MARK: Card Layout

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            coverImageView
            metadataView
        }
    }

    private var metadataView: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title)
                .font(.footnote)
                .fontWeight(.medium)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .foregroundColor(isPluginInstalled ? .primary : .secondary)

            if !isPluginInstalled {
                Label("Plugin missing", systemImage: "exclamationmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
        }
    }

    // MARK: Cover Image

    private var coverImageView: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let targetSize = CGSize(
                width: width * UIScreen.main.scale,
                height: width * 1.5 * UIScreen.main.scale
            )

            ZStack(alignment: .topTrailing) {
                coverContent(width: width, targetSize: targetSize)

                // Non-threatening plugin badge — small, top-trailing
                if !isPluginInstalled {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.orange, Color(.systemBackground))
                        .padding(5)
                } else if badgeCount > 0 && !isEditing {
                    // HIG-compliant Unread Badge
                    Text("\(badgeCount)")
                        .font(.caption2.weight(.bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.red))
                        .overlay(Capsule().stroke(Color(UIColor.systemBackground), lineWidth: 1.5))
                        .padding(4)
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .aspectRatio(2 / 3, contentMode: .fit)
        .cornerRadius(8)
        .clipped()
    }

    @ViewBuilder
    private func coverContent(width: CGFloat, targetSize: CGSize) -> some View {
        if let coverURL = item.coverUrl, let url = URL(string: coverURL) {
            LazyImage(url: url) { state in
                if let image = state.image {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: width)
                        .saturation(isPluginInstalled ? 1.0 : 0.35)
                } else if state.error != nil {
                    coverPlaceholder(icon: "photo.slash")
                } else {
                    ShimmerView()
                }
            }
            .processors([.resize(size: targetSize)])
        } else {
            coverPlaceholder(icon: "photo.on.rectangle.angled")
        }
    }

    private func coverPlaceholder(icon: String) -> some View {
        ZStack {
            Color(.secondarySystemFill)
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Pressable Button Style

/// Gives NavigationLink a native-feeling scale press without losing the tap highlight.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Shimmer Loading View

struct ShimmerView: View {
    @State private var phase: CGFloat = -1.0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(.secondarySystemFill)

                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: Color.white.opacity(0.25), location: 0.45),
                        .init(color: Color.white.opacity(0.25), location: 0.55),
                        .init(color: .clear, location: 1.0)
                    ]),
                    startPoint: UnitPoint(x: phase, y: 0.5),
                    endPoint: UnitPoint(x: phase + 0.6, y: 0.5)
                )
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .onAppear {
            withAnimation(
                .linear(duration: 1.3)
                .repeatForever(autoreverses: false)
            ) {
                phase = 1.4
            }
        }
    }
}

// MARK: - DeferredPluginView

struct DeferredPluginView: View {
    let item: LibraryItem

    @State private var runner: ItoRunner?
    @State private var errorMessage: String?
    @State private var loadTask: Task<Void, Never>?

    @State private var decodedAnime: Anime?
    @State private var decodedManga: Manga?
    @State private var decodedNovel: Novel?

    var body: some View {
        Group {
            if let error = errorMessage {
                errorView(error)
            } else if let runner = runner {
                resolvedContentView(runner: runner)
            } else {
                loadingView
            }
        }
        .onAppear {
            // Guard: don't re-fire if already loaded
            guard runner == nil, errorMessage == nil else { return }
            loadTask = Task { await loadRunnerAndItem() }
        }
        .onDisappear {
            loadTask?.cancel()
            loadTask = nil
        }
    }

    // MARK: Resolved Content

    @ViewBuilder
    private func resolvedContentView(runner: ItoRunner) -> some View {
        switch item.effectiveType {
        case .anime:
            if let anime = decodedAnime {
                AnimeView(runner: runner, anime: anime, pluginId: item.pluginId)
            } else {
                errorView("Failed to decode the saved anime data.")
            }
        case .manga:
            if let manga = decodedManga {
                MangaView(runner: runner, manga: manga, pluginId: item.pluginId)
            } else {
                errorView("Failed to decode the saved manga data.")
            }
        case .novel:
            if let novel = decodedNovel {
                NovelView(runner: runner, novel: novel, pluginId: item.pluginId)
            } else {
                errorView("Failed to decode the saved novel data.")
            }
        }
    }

    // MARK: States

    private var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Loading…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 42, weight: .thin))
                .foregroundStyle(.red)

            Text("Couldn't Load Plugin")
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Load

    private func loadRunnerAndItem() async {
        do {
            // Decode payload first — cheap, synchronous-ish
            switch item.effectiveType {
            case .anime:
                let val = try JSONDecoder().decode(Anime.self, from: item.rawPayload)
                await MainActor.run { decodedAnime = val }
            case .manga:
                let val = try JSONDecoder().decode(Manga.self, from: item.rawPayload)
                await MainActor.run { decodedManga = val }
            case .novel:
                let val = try JSONDecoder().decode(Novel.self, from: item.rawPayload)
                await MainActor.run { decodedNovel = val }
            }

            // Bail early if user navigated away
            try Task.checkCancellation()

            let pluginRunner = try await PluginManager.shared.getRunner(for: item.pluginId)

            try Task.checkCancellation()

            await MainActor.run { runner = pluginRunner }

        } catch is CancellationError {
            // User navigated away — discard silently, don't update state
        } catch {
            await MainActor.run { errorMessage = error.localizedDescription }
        }
    }
}

// MARK: - UpdateProgressBanner

struct UpdateProgressBanner: View {
    let current: Int
    let total: Int

    var body: some View {
        HStack {
            ProgressView()
                .scaleEffect(0.8)
                .padding(.trailing, 4)
            Text("Checking for updates... \(current)/\(total)")
                .font(.footnote)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(.thickMaterial)
                .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 3)
        )
        .padding(.top, 8)
    }
}

// MARK: - Preview

struct LibraryView_Previews: PreviewProvider {
    static var previews: some View {
        LibraryView()
    }
}

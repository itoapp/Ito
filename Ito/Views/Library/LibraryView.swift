import SwiftUI
import Nuke
import NukeUI
import ito_runner

// MARK: - LibraryGroup (avoids tuple inference issues with ForEach)

private struct LibraryGroup: Identifiable {
    let id: String          // category id
    let name: String        // category name
    let isSystem: Bool
    let items: [LibraryItem]
}

// MARK: - LibraryView

struct LibraryView: View {
    @StateObject private var libraryManager = LibraryManager.shared
    @StateObject private var updateManager = UpdateManager.shared

    @AppStorage(UserDefaultsKeys.layoutStyle) private var rawLayoutStyle: Int = LibraryLayoutStyle.sectioned.rawValue
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var searchText = ""
    @State private var isEditing = false
    @State private var selectedCategoryId: String? // nil means "All"

    @State private var itemToCategorize: String?

    // Backup State
    @State private var isExportingBackup = false
    @State private var generatedBackup: BackupDocument?
    @State private var backupError: String?
    @State private var showBackupError = false

    private var layoutStyle: LibraryLayoutStyle {
        LibraryLayoutStyle(rawValue: rawLayoutStyle) ?? .sectioned
    }

    private let columns = [
        GridItem(.adaptive(minimum: 100, maximum: 140), spacing: 12)
    ]

    private var filteredItems: [LibraryItem] {
        guard !searchText.isEmpty else { return libraryManager.items }
        return libraryManager.items.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var currentGroupedItems: [LibraryGroup] {
        let allLinks = libraryManager.links

        return libraryManager.categories.compactMap { cat in
            let itemIds = allLinks.filter { $0.categoryId == cat.id }.map { $0.itemId }
            let itemsForCat = filteredItems.filter { itemIds.contains($0.id) }

            // In tabbed mode, if a category is selected and it's not this one, skip
            if layoutStyle == .tabbed, let selected = selectedCategoryId, selected != cat.id {
                return nil
            }

            // In sectioned mode, don't show empty categories unless it's the only one
            if layoutStyle == .sectioned && itemsForCat.isEmpty && libraryManager.categories.count > 1 {
                return nil
            }

            return LibraryGroup(id: cat.id, name: cat.name, isSystem: cat.isSystemCategory, items: itemsForCat)
        }
    }

    var body: some View {
        NavigationView {
            ZStack(alignment: .top) {
                if libraryManager.isLoading {
                    loadingSkeletonView
                } else if libraryManager.items.isEmpty {
                    emptyStateView
                } else {
                    mainContentView
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
            .fileExporter(
                isPresented: $isExportingBackup,
                document: generatedBackup,
                contentType: .itoBackup,
                defaultFilename: generatedBackup?.fileURL?.lastPathComponent ?? "ItoBackup"
            ) { result in
                switch result {
                case .success(let url):
                    print("Exported to \(url)")
                case .failure(let error):
                    backupError = error.localizedDescription
                    showBackupError = true
                }
            }
            .alert(isPresented: $showBackupError) {
                Alert(title: Text("Backup Error"), message: Text(backupError ?? "Unknown error"), dismissButton: .default(Text("OK")))
            }
        }
        .navigationViewStyle(.stack)
        .onAppear {
            updateDiscordStatus()
        }
        .onChange(of: selectedCategoryId) { _ in
            updateDiscordStatus()
        }
    }

    private func updateDiscordStatus() {
        let categoryName = libraryManager.categories.first(where: { $0.id == selectedCategoryId })?.name
        DiscordRPCManager.shared.updateLibraryStatus(categoryName: categoryName)
    }

    // MARK: Content

    private var mainContentView: some View {
        VStack(spacing: 0) {
            if layoutStyle == .tabbed {
                pillBar
                Divider()
            }

            if !searchText.isEmpty && currentGroupedItems.allSatisfy({ $0.items.isEmpty }) {
                noResultsView
            } else {
                contentScrollView
            }
        }
    }

    private var contentScrollView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                if layoutStyle == .tabbed && selectedCategoryId == nil {
                    // "All" view
                    Section {
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(filteredItems) { item in
                                LibraryItemView(item: item, isEditing: isEditing) {
                                    itemToCategorize = item.id
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                    }
                } else {
                    ForEach(currentGroupedItems) { group in
                        Section {
                            if group.items.isEmpty {
                                actionableEmptyState(for: group.name)
                            } else {
                                LazyVGrid(columns: columns, spacing: 14) {
                                    ForEach(group.items) { item in
                                        LibraryItemView(item: item, isEditing: isEditing) {
                                            itemToCategorize = item.id
                                        }
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.bottom, 24)
                            }
                        } header: {
                            if layoutStyle == .sectioned {
                                SectionHeaderView(
                                    label: group.name,
                                    icon: group.isSystem ? "tray" : "folder",
                                    count: group.items.count
                                )
                            }
                        }
                    }
                }
            }
            .padding(.top, layoutStyle == .sectioned ? 4 : 16)
            .padding(.bottom, 16)
        }
        .refreshable {
            await updateManager.checkForUpdates()
        }
        .sheet(item: Binding(
            get: { itemToCategorize.map { SheetIdentifiable(id: $0) } },
            set: { itemToCategorize = $0?.id }
        )) { wrapper in
            CategoryAssignmentSheet(itemId: wrapper.id)
        }
    }

    // MARK: Pill Bar

    @ViewBuilder
    private var pillBar: some View {
        if dynamicTypeSize >= .accessibility1 {
            Picker("Category", selection: $selectedCategoryId) {
                Text("All").tag(String?.none)
                ForEach(libraryManager.categories) { cat in
                    Text(cat.name).tag(String?.some(cat.id))
                }
            }
            .pickerStyle(.menu)
            .padding(.horizontal)
            .padding(.vertical, 8)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    pillButton(title: "All", id: nil)
                    ForEach(libraryManager.categories) { cat in
                        pillButton(title: cat.name, id: cat.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
    }

    private func pillButton(title: String, id: String?) -> some View {
        let isSelected = selectedCategoryId == id
        return Button {
            withAnimation(.snappy) {
                selectedCategoryId = id
            }
        } label: {
            Text(title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 16)
                .frame(minWidth: 44, minHeight: 44)
                .background(isSelected ? Color.accentColor : Color(.systemGray5))
                .foregroundColor(isSelected ? .white : .primary)
                .clipShape(Capsule())
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

                NavigationLink(destination: CategorySettingsView()) {
                    Image(systemName: "folder.badge.gearshape")
                        .accessibilityLabel("Manage Categories")
                }
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            HStack(spacing: 16) {
                Button {
                    withAnimation {
                        rawLayoutStyle = (layoutStyle == .sectioned) ? LibraryLayoutStyle.tabbed.rawValue : LibraryLayoutStyle.sectioned.rawValue
                    }
                } label: {
                    Image(systemName: layoutStyle == .sectioned ? "rectangle.grid.1x2" : "square.grid.2x2")
                }
                .accessibilityLabel("Switch to \(layoutStyle == .sectioned ? "tabbed" : "sectioned") layout")

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

                Menu {
                    Button {
                        Task {
                            do {
                                let tempURL = try await BackupManager.shared.createBackupFile()
                                self.generatedBackup = BackupDocument(url: tempURL)
                                self.isExportingBackup = true
                            } catch {
                                self.backupError = error.localizedDescription
                                self.showBackupError = true
                            }
                        }
                    } label: {
                        Label("Export Library", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    // MARK: Skeleton Loading

    private var loadingSkeletonView: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(0..<8, id: \.self) { _ in
                    let fakeItem = LibraryItem(id: UUID().uuidString, title: "Loading Item Title", coverUrl: nil, pluginId: "", isAnime: false, pluginType: .manga, rawPayload: Data(), anilistId: nil)
                    LibraryItemView(item: fakeItem, isEditing: false)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
        }
        .redacted(reason: .placeholder)
        .allowsHitTesting(false)
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
        .padding(.bottom, 60)
    }

    private func actionableEmptyState(for categoryName: String) -> some View {
        VStack(spacing: 14) {
            Text("No items in \(categoryName).")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button("Browse Discover") {
                // Future routing to Discover tab
            }
            .font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
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
    let icon: String // SF Symbol
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
    var onAssignCategories: (() -> Void)?

    @ObservedObject private var pluginManager = PluginManager.shared
    @StateObject private var updateManager = UpdateManager.shared
    @State private var wiggleAngle: Double = Double.random(in: -1.2...1.2)
    @State private var isWiggling: Bool = false

    private var isPluginInstalled: Bool {
        pluginManager.installedPlugins[item.pluginId] != nil
    }

    private var badgeCount: Int {
        updateManager.newChapterCounts[item.id] ?? 0
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            NavigationLink(destination: DeferredPluginView(item: item)) {
                cardContent
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(isEditing)
            .contextMenu {
                Button {
                    onAssignCategories?()
                } label: {
                    Label("Add to List...", systemImage: "list.bullet.rectangle")
                }

                Button(role: .destructive) {
                    LibraryManager.shared.removeItem(withId: item.id)
                } label: {
                    Label("Remove from Library", systemImage: "trash")
                }
            }

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
        .rotationEffect(.degrees(isWiggling ? wiggleAngle : 0))
        .animation(
            isWiggling ? .easeInOut(duration: 0.12).repeatForever(autoreverses: true) : .easeInOut(duration: 0.15),
            value: isWiggling
        )
        .onChange(of: isEditing) { editing in
            withAnimation {
                isWiggling = editing
            }
        }
    }

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

    private var coverImageView: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let targetSize = CGSize(
                width: width * UIScreen.main.scale,
                height: width * 1.5 * UIScreen.main.scale
            )

            ZStack(alignment: .topTrailing) {
                coverContent(width: width, targetSize: targetSize)

                if !isPluginInstalled {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.orange, Color(.systemBackground))
                        .padding(5)
                } else if badgeCount > 0 && !isEditing {
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
            Color.itoCardBackground
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tertiary)
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

    @State private var isMissingPlugin = false
    @State private var isDownloadingPlugin = false

    var body: some View {
        Group {
            if isMissingPlugin {
                missingPluginView
            } else if let error = errorMessage {
                errorView(error)
            } else if let runner = runner {
                resolvedContentView(runner: runner)
            } else {
                loadingView
            }
        }
        .onAppear {
            guard runner == nil, errorMessage == nil else { return }
            loadTask = Task { await loadRunnerAndItem() }
        }
        .onDisappear {
            loadTask?.cancel()
            loadTask = nil
        }
    }

    @ViewBuilder
    private func resolvedContentView(runner: ItoRunner) -> some View {
        switch item.effectiveType {
        case .anime:
            if let anime = decodedAnime {
                MediaDetailView(runner: runner, media: anime, pluginId: item.pluginId) { try await runner.getAnimeUpdate(anime: $0, needsDetails: true, needsEpisodes: true) }
            } else {
                errorView("Failed to decode the saved anime data.")
            }
        case .manga:
            if let manga = decodedManga {
                MediaDetailView(runner: runner, media: manga, pluginId: item.pluginId) { try await runner.getMangaUpdate(manga: $0) }
            } else {
                errorView("Failed to decode the saved manga data.")
            }
        case .novel:
            if let novel = decodedNovel {
                MediaDetailView(runner: runner, media: novel, pluginId: item.pluginId) { try await runner.getNovelUpdate(novel: $0) }
            } else {
                errorView("Failed to decode the saved novel data.")
            }
        }
    }

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

    private var missingPluginView: some View {
        VStack(spacing: 20) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 52, weight: .thin))
                .foregroundStyle(.blue)

            VStack(spacing: 6) {
                Text("Extension Required")
                    .font(.title3)
                    .fontWeight(.semibold)

                Text("To read this content, you must install the '\(item.pluginId)' extension.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if isDownloadingPlugin {
                ProgressView("Searching & Installing...")
                    .padding(.top, 10)
            } else {
                Button {
                    Task { await installMissingPlugin() }
                } label: {
                    Text("Search Repositories & Install")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(Color.blue)
                        .clipShape(Capsule())
                }
                .padding(.top, 10)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func installMissingPlugin() async {
        isDownloadingPlugin = true
        defer { isDownloadingPlugin = false }

        // ALWAYS refresh repositories first when explicitly installing a missing plugin.
        // This ensures if the user rebuilt their extensions locally or upstream updated, 
        // we won't throw Hash Mismatches due to stale stored data.
        await RepoManager.shared.refreshAll()

        var targetPkg: RepoPackage?
        var foundRepoUrl: String?

        for repo in RepoManager.shared.repositories {
            if let pkg = repo.index?.packages.first(where: { $0.id == item.pluginId }) {
                targetPkg = pkg
                foundRepoUrl = repo.url
                break
            }
        }

        guard let pkg = targetPkg, let url = foundRepoUrl else {
            errorMessage = "Couldn't find this extension in any of your repositories."
            isMissingPlugin = false
            return
        }

        do {
            try await RepoManager.shared.installPackage(pkg, repositoryUrl: url)

            // Retry loading
            isMissingPlugin = false
            await loadRunnerAndItem()

        } catch {
            errorMessage = "Failed to install extension: \(error.localizedDescription)"
            isMissingPlugin = false
        }
    }

    private func loadRunnerAndItem() async {
        do {
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

            try Task.checkCancellation()
            let pluginRunner = try await PluginManager.shared.getRunner(for: item.pluginId)
            try Task.checkCancellation()
            await MainActor.run { runner = pluginRunner }

        } catch is CancellationError {
        } catch let error as URLError where error.code == .fileDoesNotExist {
            await MainActor.run { isMissingPlugin = true }
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

private struct SheetIdentifiable: Identifiable {
    let id: String
}

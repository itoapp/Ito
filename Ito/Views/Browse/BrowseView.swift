import SwiftUI
import UniformTypeIdentifiers
import NukeUI
import ito_runner

extension UTType {
    static var ito: UTType {
        UTType(exportedAs: "moe.itoapp.ito", conformingTo: .zip)
    }
}

// MARK: - BrowseView

struct BrowseView: View {
    @StateObject private var pluginManager = PluginManager.shared
    @StateObject private var repoManager = RepoManager.shared

    @State private var errorMessage: String?
    @State private var showDeleteConfirmation = false
    @State private var pendingDeleteOffsets: IndexSet?
    @State private var isInstallingUpdate: String? // plugin id currently updating

    private var sortedPlugins: [InstalledPlugin] {
        pluginManager.installedPlugins.values.sorted { $0.info.name < $1.info.name }
    }

    struct UpdateItem: Identifiable {
        var id: String { pkg.id }
        let pkg: RepoPackage
        let repoUrl: String
    }

    private var availableUpdates: [UpdateItem] {
        var updates: [String: UpdateItem] = [:]
        for repo in repoManager.repositories {
            guard let packages = repo.index?.packages else { continue }
            for pkg in packages {
                if let installed = pluginManager.installedPlugins[pkg.id] {
                    if installed.info.version.compare(pkg.version, options: .numeric) == .orderedAscending {
                        if let existing = updates[pkg.id] {
                            if existing.pkg.version.compare(pkg.version, options: .numeric) == .orderedAscending {
                                updates[pkg.id] = UpdateItem(pkg: pkg, repoUrl: repo.url)
                            }
                        } else {
                            updates[pkg.id] = UpdateItem(pkg: pkg, repoUrl: repo.url)
                        }
                    }
                }
            }
        }
        return Array(updates.values).sorted { $0.pkg.name < $1.pkg.name }
    }

    var body: some View {
        NavigationView {
            ZStack {
                if pluginManager.installedPlugins.isEmpty {
                    emptyStateView
                } else {
                    pluginListView
                }

                errorToastView
            }
            .contentShape(Rectangle())
            .onDrop(of: [.item, .fileURL, .ito], isTargeted: nil) { providers in
                handleDrop(providers: providers)
            }
            .onOpenURL { url in
                print("System routed .onOpenURL trigger with \(url)")
                Task { await handleOpenURL(url) }
            }
            .navigationTitle("Browse")
            .navigationBarItems(trailing: repositoriesButton)
            .navigationViewStyle(.stack)
        }
        // Destructive delete confirmation
        .confirmationDialog(
            "Remove Plugin",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let offsets = pendingDeleteOffsets {
                    performDelete(at: offsets)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteOffsets = nil
            }
        } message: {
            Text("This plugin will be permanently removed from your device.")
        }
    }

    // MARK: - Subviews

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            Text("No Plugins Installed")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Drop a .ito plugin file here, or browse repositories to find and install plugins.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            NavigationLink(destination: RepositoriesView()) {
                Label("Browse Repositories", systemImage: "globe")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var pluginListView: some View {
        List {
            let updates = availableUpdates

            if !updates.isEmpty {
                Section {
                    ForEach(updates) { updateItem in
                        UpdateRowView(
                            updateItem: updateItem,
                            isInstalling: isInstallingUpdate == updateItem.id
                        ) {
                            Task { await installUpdate(updateItem) }
                        }
                    }
                } header: {
                    HStack {
                        Text("Updates Available")
                        Spacer()
                        Text("\(updates.count)")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }
                }
            }

            Section {
                ForEach(sortedPlugins, id: \.id) { plugin in
                    NavigationLink(destination: SourceView(plugin: plugin)) {
                        PluginRowView(plugin: plugin)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            if let index = sortedPlugins.firstIndex(where: { $0.id == plugin.id }) {
                                pendingDeleteOffsets = IndexSet(integer: index)
                                showDeleteConfirmation = true
                            }
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Installed")
                    Spacer()
                    Text("\(sortedPlugins.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .refreshable {
            await repoManager.refreshAll()
        }
    }

    @ViewBuilder
    private var errorToastView: some View {
        if let error = errorMessage {
            VStack {
                Spacer()
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.white)
                    Text(error)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                    Spacer()
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            errorMessage = nil
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.red.opacity(0.92))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var repositoriesButton: some View {
        NavigationLink(destination: RepositoriesView()) {
            Image(systemName: "globe")
        }
        .accessibilityLabel("Repositories")
        .accessibilityHint("Manage plugin repositories")
    }

    // MARK: - Actions

    private func installUpdate(_ updateItem: UpdateItem) async {
        isInstallingUpdate = updateItem.id
        defer { isInstallingUpdate = nil }
        do {
            try await repoManager.installPackage(updateItem.pkg, repositoryUrl: updateItem.repoUrl)
        } catch {
            await MainActor.run {
                withAnimation {
                    errorMessage = "Update failed: \(error.localizedDescription)"
                }
            }
            // Auto-dismiss error after 4 seconds
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await MainActor.run {
                withAnimation {
                    if errorMessage?.hasPrefix("Update failed") == true {
                        errorMessage = nil
                    }
                }
            }
        }
    }

    private func getPluginsDirectory() -> URL? {
        let fileManager = FileManager.default
        guard let appSupportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let pluginsDir = appSupportDir.appendingPathComponent("Plugins")

        if !fileManager.fileExists(atPath: pluginsDir.path) {
            do {
                try fileManager.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
            } catch {
                print("Failed to create plugins directory: \(error)")
                return nil
            }
        }
        return pluginsDir
    }

    private func performDelete(at offsets: IndexSet) {
        Task {
            let toDelete = offsets.map { sortedPlugins[$0] }
            let fileManager = FileManager.default

            for plugin in toDelete {
                do {
                    try fileManager.removeItem(at: plugin.url)
                } catch {
                    await MainActor.run {
                        withAnimation {
                            errorMessage = "Failed to remove \(plugin.info.name): \(error.localizedDescription)"
                        }
                    }
                }
            }
            await pluginManager.reloadInstalledPlugins()
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        print("Received drop with \(providers.count) providers")
        guard let provider = providers.first else { return false }

        let itoType = UTType.ito.identifier
        let archiveType = UTType.archive.identifier
        let zipType = UTType.zip.identifier
        let fileURLType = UTType.fileURL.identifier

        var loadedType: String?
        if provider.hasItemConformingToTypeIdentifier(itoType) {
            loadedType = itoType
        } else if provider.hasItemConformingToTypeIdentifier(archiveType) {
            loadedType = archiveType
        } else if provider.hasItemConformingToTypeIdentifier(zipType) {
            loadedType = zipType
        } else if provider.hasItemConformingToTypeIdentifier(fileURLType) {
            loadedType = fileURLType
        }

        guard let typeToLoad = loadedType else { return false }

        provider.loadFileRepresentation(forTypeIdentifier: typeToLoad) { url, error in
            guard let tempURL = url else {
                Task { @MainActor in
                    withAnimation { self.errorMessage = "Failed to load dropped file: \(String(describing: error))" }
                }
                return
            }

            guard tempURL.pathExtension.lowercased() == "ito" else {
                Task { @MainActor in
                    withAnimation { self.errorMessage = "Please drop a valid .ito plugin file." }
                }
                return
            }

            let fileManager = FileManager.default
            Task { @MainActor in
                guard let pluginsDir = self.getPluginsDirectory() else {
                    withAnimation { self.errorMessage = "Failed to access plugins directory." }
                    return
                }
                let destinationURL = pluginsDir.appendingPathComponent(tempURL.lastPathComponent)

                do {
                    if fileManager.fileExists(atPath: destinationURL.path) {
                        try fileManager.removeItem(at: destinationURL)
                    }
                    try fileManager.copyItem(at: tempURL, to: destinationURL)
                    Task { await pluginManager.reloadInstalledPlugins() }
                } catch {
                    withAnimation { self.errorMessage = "File copy error: \(error.localizedDescription)" }
                }
            }
        }
        return true
    }

    private func handleOpenURL(_ url: URL) async {
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }

        let fileManager = FileManager.default
        guard let pluginsDir = getPluginsDirectory() else {
            await MainActor.run { withAnimation { self.errorMessage = "Failed to access plugins directory." } }
            return
        }
        let destinationURL = pluginsDir.appendingPathComponent(url.lastPathComponent)

        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: url, to: destinationURL)
            await pluginManager.reloadInstalledPlugins()
        } catch {
            await MainActor.run { withAnimation { self.errorMessage = "URL Open error: \(error.localizedDescription)" } }
        }
    }
}

// MARK: - UpdateRowView

struct UpdateRowView: View {
    let updateItem: BrowseView.UpdateItem
    let isInstalling: Bool
    let onUpdate: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let icon = updateItem.pkg.iconUrl,
               let url = URL(string: "\(updateItem.repoUrl)/\(icon)") {
                LazyImage(url: url) { state in
                    if let image = state.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.secondary.opacity(0.2)
                    }
                }
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: "puzzlepiece.extension.fill")
                    .foregroundStyle(.blue)
                    .imageScale(.large)
                    .frame(width: 40, height: 40)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(updateItem.pkg.name)
                    .font(.headline)
                Text("v\(updateItem.pkg.version) available")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isInstalling {
                ProgressView()
                    .progressViewStyle(.circular)
                    .frame(width: 70)
            } else {
                Button("Update", action: onUpdate)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - PluginRowView

struct PluginRowView: View {
    let plugin: InstalledPlugin

    var body: some View {
        HStack(spacing: 12) {
            if let iconData = plugin.iconData, let uiImage = UIImage(data: iconData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: "puzzlepiece.extension.fill")
                    .foregroundStyle(.blue)
                    .imageScale(.large)
                    .frame(width: 40, height: 40)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.info.name)
                    .font(.headline)
                Text("v\(plugin.info.version) • \(plugin.info.author ?? "Unknown")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            PluginTypeBadge(type: plugin.info.type)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - PluginTypeBadge

struct PluginTypeBadge: View {
    let type: PluginType

    private var style: (title: String, icon: String, color: Color) {
        switch type {
        case .anime: return ("Anime", "play.tv", .purple)
        case .manga: return ("Manga", "book.closed", .orange)
        case .novel: return ("Novel", "text.book.closed", .green)
        }
    }

    var body: some View {
        Label(style.title, systemImage: style.icon)
            .font(.caption2.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(style.color.opacity(0.15))
            .foregroundStyle(style.color)
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

// MARK: - Preview

struct BrowseView_Previews: PreviewProvider {
    static var previews: some View {
        BrowseView()
    }
}

import SwiftUI
import UniformTypeIdentifiers
import ito_runner

extension UTType {
    static var ito: UTType {
        UTType(exportedAs: "com.kunihir0.ito", conformingTo: .zip)
    }
}

struct BrowseView: View {
    @StateObject private var pluginManager = PluginManager.shared
    @StateObject private var repoManager = RepoManager.shared
    @State private var errorMessage: String? = nil

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
                    // Check if repo version is strictly higher than installed version
                    if installed.info.version.compare(pkg.version, options: .numeric) == .orderedAscending {
                        // If we already queued an update for this plugin ID from another repo, only replace if this version is even higher
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
                    VStack(spacing: 20) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 60))
                            .foregroundStyle(.secondary)

                        Text("Drop hianime.ito Here")
                            .font(.title2)
                            .fontWeight(.semibold)

                        Text(
                            "Drag the packaged .ito plugin directly from Finder onto this screen."
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        let updates = availableUpdates
                        if !updates.isEmpty {
                            Section(header: Text("Updates")) {
                                ForEach(updates) { updateItem in
                                    HStack {
                                        if let icon = updateItem.pkg.iconUrl, let url = URL(string: "\(updateItem.repoUrl)/\(icon)") {
                                            AsyncImage(url: url) { image in
                                                image.resizable()
                                            } placeholder: {
                                                Color.gray
                                            }
                                            .frame(width: 40, height: 40)
                                            .cornerRadius(8)
                                        } else {
                                            Image(systemName: "puzzlepiece.extension.fill")
                                                .foregroundColor(.blue)
                                                .imageScale(.large)
                                                .frame(width: 40, height: 40)
                                        }

                                        VStack(alignment: .leading) {
                                            Text(updateItem.pkg.name)
                                                .font(.headline)
                                            Text("v\(updateItem.pkg.version) available")
                                                .font(.subheadline)
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer()
                                        Button("Update") {
                                            Task {
                                                do {
                                                    try await repoManager.installPackage(updateItem.pkg, repositoryUrl: updateItem.repoUrl)
                                                } catch {
                                                    errorMessage = "Update failed: \(error.localizedDescription)"
                                                }
                                            }
                                        }
                                        .buttonStyle(.borderedProminent)
                                    }
                                }
                            }
                        }

                        Section(header: Text("Browse")) {
                            ForEach(sortedPlugins, id: \.id) { plugin in
                                NavigationLink(destination: SourceView(plugin: plugin)) {
                                    PluginRowView(plugin: plugin)
                                }
                            }
                            .onDelete(perform: deletePlugin)
                        }
                    }
                    .refreshable {
                        await repoManager.refreshAll()
                    }
                }

                if let error = errorMessage {
                    VStack {
                        Spacer()
                        Text("Error: \(error)")
                            .foregroundColor(.white)
                            .padding()
                            .background(Color.red.opacity(0.8))
                            .cornerRadius(8)
                            .padding(.bottom)
                    }
                }
            }
            // Ensure the entire view grabs drop hit-tests
            .contentShape(Rectangle())
            .onDrop(of: [.item, .fileURL, .ito], isTargeted: nil) { providers in
                handleDrop(providers: providers)
            }
            .onOpenURL { url in
                print("System routed .onOpenURL trigger with \(url)")
                Task { await handleOpenURL(url) }
            }
            .navigationTitle("Browse")
            .navigationBarItems(trailing: NavigationLink(destination: RepositoriesView()) {
                Image(systemName: "globe")
            })
            .navigationViewStyle(.stack)
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

    private func deletePlugin(at offsets: IndexSet) {
        let fileManager = FileManager.default
        
        offsets.forEach { index in
            let plugin = sortedPlugins[index]
            do {
                try fileManager.removeItem(at: plugin.url)
            } catch {
                print("Failed to delete plugin: \(error)")
            }
        }
        
        Task {
            await pluginManager.reloadInstalledPlugins()
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        print("Received drop with \(providers.count) providers")
        guard let provider = providers.first else {
            return false
        }

        let itoType = UTType.ito.identifier
        let archiveType = UTType.archive.identifier
        let zipType = UTType.zip.identifier
        let fileURLType = UTType.fileURL.identifier

        var loadedType: String? = nil
        if provider.hasItemConformingToTypeIdentifier(itoType) {
            loadedType = itoType
        } else if provider.hasItemConformingToTypeIdentifier(archiveType) {
            loadedType = archiveType
        } else if provider.hasItemConformingToTypeIdentifier(zipType) {
            loadedType = zipType
        } else if provider.hasItemConformingToTypeIdentifier(fileURLType) {
            loadedType = fileURLType
        }

        guard let typeToLoad = loadedType else {
            return false
        }

        provider.loadFileRepresentation(forTypeIdentifier: typeToLoad) { url, error in
            guard let tempURL = url else {
                DispatchQueue.main.async {
                    self.errorMessage = "Failed to load dropped file: \(String(describing: error))"
                }
                return
            }

            guard tempURL.pathExtension.lowercased() == "ito" else {
                DispatchQueue.main.async {
                    self.errorMessage = "Please drop a valid .ito plugin file."
                }
                return
            }

            let fileManager = FileManager.default
            
            DispatchQueue.main.async {
                guard let pluginsDir = self.getPluginsDirectory() else {
                    self.errorMessage = "Failed to access plugins directory."
                    return
                }
                let destinationURL = pluginsDir.appendingPathComponent(tempURL.lastPathComponent)

                do {
                    if fileManager.fileExists(atPath: destinationURL.path) {
                        try fileManager.removeItem(at: destinationURL)
                    }
                    try fileManager.copyItem(at: tempURL, to: destinationURL)
                    
                    Task {
                        await pluginManager.reloadInstalledPlugins()
                    }
                } catch {
                    self.errorMessage = "File copy error: \(error.localizedDescription)"
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
            await MainActor.run { self.errorMessage = "Failed to access plugins directory." }
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
            await MainActor.run { self.errorMessage = "URL Open error: \(error.localizedDescription)" }
        }
    }
}

struct PluginRowView: View {
    let plugin: InstalledPlugin

    var body: some View {
        HStack {
            if let iconData = plugin.iconData, let uiImage = UIImage(data: iconData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 40, height: 40)
                    .cornerRadius(8)
            } else {
                Image(systemName: "puzzlepiece.extension.fill")
                    .foregroundColor(.blue)
                    .imageScale(.large)
                    .frame(width: 40, height: 40)
            }
            
            VStack(alignment: .leading) {
                Text(plugin.info.name)
                    .font(.headline)
                Text("v\(plugin.info.version) • \(plugin.info.author ?? "Unknown")")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text(plugin.info.type == .anime ? "ANIME" : "MANGA")
                .font(.caption2)
                .fontWeight(.bold)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    plugin.info.type == .anime
                        ? Color.purple.opacity(0.2)
                        : Color.orange.opacity(0.2)
                )
                .foregroundColor(
                    plugin.info.type == .anime ? .purple : .orange
                )
                .cornerRadius(4)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    BrowseView()
}

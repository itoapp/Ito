import SwiftUI
import UniformTypeIdentifiers
import ito_runner

extension UTType {
    static var ito: UTType {
        UTType(exportedAs: "com.kunihir0.ito", conformingTo: .zip)
    }
}

struct LoadedPlugin: Hashable {
    let url: URL
    let info: PluginInfo?

    // Hashable conformance based on URL since URLs are unique in the documents directory
    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }

    static func == (lhs: LoadedPlugin, rhs: LoadedPlugin) -> Bool {
        return lhs.url == rhs.url
    }
}

struct BrowseView: View {
    @State private var installedPlugins: [LoadedPlugin] = []
    @State private var errorMessage: String? = nil

    var body: some View {
        NavigationView {
            ZStack {
                if installedPlugins.isEmpty {
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
                        ForEach(installedPlugins, id: \.url) { plugin in
                            NavigationLink(destination: SourceView(plugin: plugin)) {
                                HStack {
                                    Image(systemName: "puzzlepiece.extension.fill")
                                        .foregroundColor(.blue)
                                        .imageScale(.large)
                                    VStack(alignment: .leading) {
                                        Text(
                                            plugin.url.deletingPathExtension().lastPathComponent
                                                .capitalized
                                        )
                                        .font(.headline)
                                        Text("Local Plugin")
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)
                                    }

                                    Spacer()

                                    if let info = plugin.info {
                                        Text(info.type == .anime ? "ANIME" : "MANGA")
                                            .font(.caption2)
                                            .fontWeight(.bold)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(
                                                info.type == .anime
                                                    ? Color.purple.opacity(0.2)
                                                    : Color.orange.opacity(0.2)
                                            )
                                            .foregroundColor(
                                                info.type == .anime ? .purple : .orange
                                            )
                                            .cornerRadius(4)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .onDelete(perform: deletePlugin)
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
            .navigationViewStyle(.stack)
            .onAppear {
                loadInstalledPlugins()
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

    private func loadInstalledPlugins() {
        let fileManager = FileManager.default
        guard let pluginsDir = getPluginsDirectory() else { return }

        do {
            let files = try fileManager.contentsOfDirectory(
                at: pluginsDir, includingPropertiesForKeys: nil)
            let urls = files.filter { $0.pathExtension == "ito" }.sorted(by: {
                $0.lastPathComponent < $1.lastPathComponent
            })

            // For now, load ItoRunner just to extract the manifest, we'll discard it
            self.installedPlugins = []
            Task {
                var loaded: [LoadedPlugin] = []
                for url in urls {
                    let runner = ItoRunner()
                    do {
                        let manifest = try await runner.loadBundle(from: url)
                        loaded.append(LoadedPlugin(url: url, info: manifest?.info))
                    } catch {
                        print("Failed to inspect plugin \(url.lastPathComponent): \(error)")
                        loaded.append(LoadedPlugin(url: url, info: nil))
                    }
                }

                await MainActor.run {
                    self.installedPlugins = loaded
                }
            }
        } catch {
            print("Error loading installed plugins: \(error)")
        }
    }

    private func deletePlugin(at offsets: IndexSet) {
        let fileManager = FileManager.default
        offsets.forEach { index in
            let plugin = installedPlugins[index]
            do {
                try fileManager.removeItem(at: plugin.url)
            } catch {
                print("Failed to delete plugin: \(error)")
            }
        }
        loadInstalledPlugins()
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        print("Received drop with \(providers.count) providers")
        guard let provider = providers.first else {
            print("No providers found")
            return false
        }

        print("Registered types on provider: \(provider.registeredTypeIdentifiers)")

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
            print(
                "Provider does not conform to any accepted file type. Types: \(provider.registeredTypeIdentifiers)"
            )
            return false
        }

        print("Provider conforms to \(typeToLoad), loading file representation...")

        provider.loadFileRepresentation(forTypeIdentifier: typeToLoad) { url, error in
            print(
                "Loaded file representation. URL: \(String(describing: url)), Error: \(String(describing: error))"
            )
            guard let tempURL = url else {
                print("Failed to get tempURL")
                DispatchQueue.main.async {
                    self.errorMessage = "Failed to load dropped file: \(String(describing: error))"
                }
                return
            }

            guard tempURL.pathExtension.lowercased() == "ito" else {
                print("Dropped file is not an .ito file. It is: \(tempURL.pathExtension)")
                DispatchQueue.main.async {
                    self.errorMessage = "Please drop a valid .ito plugin file."
                }
                return
            }

            // The URL provided by loadFileRepresentation is temporary and deleted after the closure.
            // We must copy it to our own sandbox safely.
            let fileManager = FileManager.default
            
            // Use our shared helper or inline logic (since we can't access instance method easily in closure without self capture, 
            // but we are in a closure capturing self implicitly or explicitly).
            // Actually, we are in `provider.loadFileRepresentation` closure.
            // We can capture `self` but let's just re-implement safely or use `self.getPluginsDirectory()` if available.
            // Since `getPluginsDirectory` is private on `BrowseView`, we can access it via `self`.
            
            DispatchQueue.main.async {
                guard let pluginsDir = self.getPluginsDirectory() else {
                    self.errorMessage = "Failed to access plugins directory."
                    return
                }
                let destinationURL = pluginsDir.appendingPathComponent(tempURL.lastPathComponent)
                print("Copying from \(tempURL) to \(destinationURL)")

                do {
                    if fileManager.fileExists(atPath: destinationURL.path) {
                        print("Removing old file at \(destinationURL.path)")
                        try fileManager.removeItem(at: destinationURL)
                    }
                    try fileManager.copyItem(at: tempURL, to: destinationURL)
                    print("Successfully copied file.")

                    self.loadInstalledPlugins()
                } catch {
                    print("Copy failed: \(error.localizedDescription)")
                    self.errorMessage = "File copy error: \(error.localizedDescription)"
                }
            }
        }
        print("Returning true from handleDrop")
        return true
    }

    private func handleOpenURL(_ url: URL) async {
        print("Executing handleOpenURL for: \(url)")
        // Gain access to the security-scoped URL picked by the system
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }

        let fileManager = FileManager.default
        guard let pluginsDir = getPluginsDirectory() else {
            await MainActor.run {
                self.errorMessage = "Failed to access plugins directory."
            }
            return
        }
        let destinationURL = pluginsDir.appendingPathComponent(url.lastPathComponent)

        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: url, to: destinationURL)
            print("Successfully natively copied OpenURL to sandbox.")

            await MainActor.run {
                self.loadInstalledPlugins()
            }
        } catch {
            print("Failed to copy OpenURL: \(error)")
            await MainActor.run {
                self.errorMessage = "URL Open error: \(error.localizedDescription)"
            }
        }
    }
}

#Preview {
    BrowseView()
}

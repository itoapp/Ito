import SwiftUI
import CryptoKit
import NukeUI
import ito_runner

struct RepositoriesView: View {
    @StateObject private var repoManager = RepoManager.shared
    @State private var showingAddRepo = false
    @State private var newRepoUrl = ""
    @State private var errorMessage: String? = nil
    
    var body: some View {
        List {
            if repoManager.repositories.isEmpty {
                Text("No repositories added. Add one to discover plugins!")
                    .foregroundColor(.secondary)
            }
            
            ForEach(repoManager.repositories) { repo in
                NavigationLink(destination: RepoDetailView(repository: repo)) {
                    VStack(alignment: .leading) {
                        Text(repo.index?.repoName ?? "Unknown Repository")
                            .font(.headline)
                        Text(repo.url)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .onDelete(perform: deleteRepo)
        }
        .navigationTitle("Repositories")
        .navigationBarItems(
            trailing: Button(action: { showingAddRepo = true }) {
                Image(systemName: "plus")
            }
        )
        .sheet(isPresented: $showingAddRepo) {
            NavigationView {
                Form {
                    Section(header: Text("Repository URL"), footer: Text("Enter the full URL to the repository. The app will fetch the index.json from this URL.")) {
                        TextField("https://example.com/repo", text: $newRepoUrl)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                    }
                }
                .navigationTitle("Add Repository")
                .navigationBarTitleDisplayMode(.inline)
                .navigationBarItems(
                    leading: Button("Cancel") {
                        showingAddRepo = false
                        newRepoUrl = ""
                    },
                    trailing: Button("Add") {
                        Task {
                            await addRepo()
                            showingAddRepo = false
                        }
                    }
                    .disabled(newRepoUrl.isEmpty)
                )
            }
        }
        .alert(isPresented: .constant(errorMessage != nil)) {
            Alert(
                title: Text("Error"),
                message: Text(errorMessage ?? ""),
                dismissButton: .default(Text("OK")) { errorMessage = nil }
            )
        }
        .refreshable {
            await repoManager.refreshAll()
        }
    }
    
    private func deleteRepo(at offsets: IndexSet) {
        offsets.forEach { index in
            repoManager.removeRepository(url: repoManager.repositories[index].url)
        }
    }
    
    private func addRepo() async {
        guard !newRepoUrl.isEmpty else { return }
        do {
            try await repoManager.addRepository(url: newRepoUrl)
            newRepoUrl = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct RepoDetailView: View {
    let repository: Repository
    @StateObject private var repoManager = RepoManager.shared
    @StateObject private var pluginManager = PluginManager.shared
    @State private var searchQuery = ""
    
    var filteredPackages: [RepoPackage] {
        guard let index = repository.index else { return [] }
        if searchQuery.isEmpty {
            return index.packages
        } else {
            return index.packages.filter { pkg in
                pkg.name.localizedCaseInsensitiveContains(searchQuery) ||
                pkg.pluginType.localizedCaseInsensitiveContains(searchQuery)
            }
        }
    }
    
    var body: some View {
        List {
            if let index = repository.index {
                Section(header: Text(index.description)) {
                    ForEach(filteredPackages, id: \.id) { pkg in
                        HStack {
                            if let icon = pkg.iconUrl, let url = URL(string: "\(repository.url)/\(icon)") {
                                LazyImage(url: url) { state in
                                    if let image = state.image {
                                        image.resizable()
                                    } else {
                                        Color.gray
                                    }
                                }
                                .frame(width: 40, height: 40)
                                .cornerRadius(8)
                            } else {
                                Color.gray
                                    .frame(width: 40, height: 40)
                                    .cornerRadius(8)
                            }
                            
                            VStack(alignment: .leading) {
                                Text(pkg.name)
                                    .font(.headline)
                                Text("v\(pkg.version) • \(pkg.pluginType.capitalized)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            if !repoManager.isCompatible(minAppVersion: pkg.minAppVersion) {
                                Text("Requires v\(pkg.minAppVersion)")
                                    .font(.caption2)
                                    .foregroundColor(.red)
                            } else {
                                // O(1) synchronous lookup!
                                if let installedPlugin = pluginManager.installedPlugins[pkg.id] {
                                    if installedPlugin.info.version.compare(pkg.version, options: .numeric) == .orderedAscending {
                                        Button("Update") {
                                            Task { await installPackage(pkg) }
                                        }
                                        .buttonStyle(.borderedProminent)
                                    } else {
                                        Text("Installed")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .background(Color.secondary.opacity(0.1))
                                            .cornerRadius(12)
                                    }
                                } else {
                                    Button("Install") {
                                        Task { await installPackage(pkg) }
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            } else {
                Text("Repository index is missing or invalid.")
            }
        }
        .searchable(text: $searchQuery, prompt: "Search packages...")
        .navigationTitle(repository.index?.repoName ?? "Repository")
    }
    
    private func installPackage(_ pkg: RepoPackage) async {
        do {
            try await repoManager.installPackage(pkg, repositoryUrl: repository.url)
        } catch {
            print("Install failed: \(error)")
        }
    }
}

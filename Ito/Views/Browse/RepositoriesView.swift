import SwiftUI
import CryptoKit
import NukeUI
import ito_runner

// MARK: - RepositoriesView

struct RepositoriesView: View {
    @StateObject private var repoManager = RepoManager.shared
    @State private var showingAddRepo = false
    @State private var newRepoUrl = ""
    @State private var isAddingRepo = false
    @State private var addRepoError: String?
    @State private var showDeleteConfirmation = false
    @State private var pendingDeleteOffsets: IndexSet?

    var body: some View {
        Group {
            if repoManager.repositories.isEmpty {
                emptyStateView
            } else {
                repoListView
            }
        }
        .navigationTitle("Repositories")
        .navigationBarItems(
            trailing: Button {
                showingAddRepo = true
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Add Repository")
        )
        .sheet(isPresented: $showingAddRepo) {
            addRepoSheet
        }
        .confirmationDialog(
            "Remove Repository",
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
            Text("This repository and all its associated data will be removed.")
        }
        .refreshable {
            await repoManager.refreshAll()
        }
    }

    // MARK: - Subviews

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "globe.badge.chevron.backward")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            Text("No Repositories")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Add a repository URL to discover and install plugins.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                showingAddRepo = true
            } label: {
                Label("Add Repository", systemImage: "plus")
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

    private var repoListView: some View {
        List {
            ForEach(repoManager.repositories) { repo in
                NavigationLink(destination: RepoDetailView(repository: repo)) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(repo.index?.repoName ?? "Unknown Repository")
                            .font(.headline)
                        Text(repo.url)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let count = repo.index?.packages.count {
                            Text("\(count) package\(count == 1 ? "" : "s")")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        if let index = repoManager.repositories.firstIndex(where: { $0.id == repo.id }) {
                            pendingDeleteOffsets = IndexSet(integer: index)
                            showDeleteConfirmation = true
                        }
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
            }
        }
    }

    private var addRepoSheet: some View {
        NavigationView {
            Form {
                Section {
                    TextField("https://example.com/repo", text: $newRepoUrl)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .disabled(isAddingRepo)
                } header: {
                    Text("Repository URL")
                } footer: {
                    Text("Enter the full URL to the repository. The app will fetch index.json from this address.")
                }

                if let error = addRepoError {
                    Section {
                        Label(error, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.red)
                            .font(.subheadline)
                    }
                }
            }
            .navigationTitle("Add Repository")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(
                leading: Button("Cancel") {
                    showingAddRepo = false
                    newRepoUrl = ""
                    addRepoError = nil
                }
                .disabled(isAddingRepo),
                trailing: Group {
                    if isAddingRepo {
                        ProgressView()
                            .progressViewStyle(.circular)
                    } else {
                        Button {
                            Task { await addRepo() }
                        } label: {
                            Text("Add")
                                .font(.body.weight(.semibold))
                        }
                        .disabled(newRepoUrl.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            )
        }
    }

    // MARK: - Actions

    private func performDelete(at offsets: IndexSet) {
        offsets.forEach { index in
            repoManager.removeRepository(url: repoManager.repositories[index].url)
        }
    }

    private func addRepo() async {
        let trimmed = newRepoUrl.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        isAddingRepo = true
        addRepoError = nil

        do {
            try await repoManager.addRepository(url: trimmed)
            newRepoUrl = ""
            showingAddRepo = false
        } catch {
            addRepoError = error.localizedDescription
        }

        isAddingRepo = false
    }
}

// MARK: - RepoDetailView

struct RepoDetailView: View {
    let repository: Repository
    @StateObject private var repoManager = RepoManager.shared
    @StateObject private var pluginManager = PluginManager.shared

    @State private var searchQuery = ""
    @State private var installingPackageId: String?
    @State private var errorMessage: String?

    var filteredPackages: [RepoPackage] {
        guard let index = repository.index else { return [] }
        guard !searchQuery.isEmpty else { return index.packages }
        return index.packages.filter { pkg in
            pkg.name.localizedCaseInsensitiveContains(searchQuery) ||
            pkg.pluginType.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                if repository.index == nil {
                    missingIndexView
                } else {
                    packageListView
                }
            }

            errorToastView
        }
        .searchable(text: $searchQuery, prompt: "Search packages")
        .navigationTitle(repository.index?.repoName ?? "Repository")
        .navigationBarTitleDisplayMode(.large)
    }

    // MARK: - Subviews

    private var missingIndexView: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(.secondary)

            Text("Index Unavailable")
                .font(.title3)
                .fontWeight(.semibold)

            Text("The repository index could not be loaded. Pull to refresh or check the repository URL.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var packageListView: some View {
        List {
            if let description = repository.index?.description, !description.isEmpty {
                Section {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if filteredPackages.isEmpty {
                    Text("No packages match your search.")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                } else {
                    ForEach(filteredPackages, id: \.id) { pkg in
                        PackageRowView(
                            pkg: pkg,
                            repositoryUrl: repository.url,
                            installState: installState(for: pkg),
                            isInstalling: installingPackageId == pkg.id
                        ) {
                            Task { await installPackage(pkg) }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Packages")
                    Spacer()
                    if let total = repository.index?.packages.count {
                        Text("\(total)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var errorToastView: some View {
        if let error = errorMessage {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.white)
                Text(error)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { errorMessage = nil }
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

    // MARK: - Helpers

    enum InstallState {
        case incompatible(minVersion: String)
        case updateAvailable
        case installed
        case notInstalled
    }

    private func installState(for pkg: RepoPackage) -> InstallState {
        guard repoManager.isCompatible(minAppVersion: pkg.minAppVersion) else {
            return .incompatible(minVersion: pkg.minAppVersion)
        }
        guard let installed = pluginManager.installedPlugins[pkg.id] else {
            return .notInstalled
        }
        if installed.info.version.compare(pkg.version, options: .numeric) == .orderedAscending {
            return .updateAvailable
        }
        return .installed
    }

    // MARK: - Actions

    private func installPackage(_ pkg: RepoPackage) async {
        installingPackageId = pkg.id
        do {
            try await repoManager.installPackage(pkg, repositoryUrl: repository.url)
        } catch {
            await MainActor.run {
                withAnimation { errorMessage = "Failed to install \(pkg.name): \(error.localizedDescription)" }
            }
            // Auto-dismiss after 4s
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await MainActor.run {
                withAnimation { errorMessage = nil }
            }
        }
        installingPackageId = nil
    }
}

// MARK: - PackageRowView

struct PackageRowView: View {
    let pkg: RepoPackage
    let repositoryUrl: String
    let installState: RepoDetailView.InstallState
    let isInstalling: Bool
    let onAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            iconView

            VStack(alignment: .leading, spacing: 2) {
                Text(pkg.name)
                    .font(.headline)
                Text("v\(pkg.version) • \(pkg.pluginType.capitalized)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            actionView
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var iconView: some View {
        if let icon = pkg.iconUrl, let url = URL(string: "\(repositoryUrl)/\(icon)") {
            LazyImage(url: url) { state in
                if let image = state.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.secondary.opacity(0.15)
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
    }

    @ViewBuilder
    private var actionView: some View {
        if isInstalling {
            ProgressView()
                .progressViewStyle(.circular)
                .frame(width: 72)
        } else {
            switch installState {
            case .incompatible(let minVersion):
                Text("Requires v\(minVersion)")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.trailing)

            case .updateAvailable:
                Button("Update", action: onAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

            case .installed:
                Label("Installed", systemImage: "checkmark")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(Capsule())

            case .notInstalled:
                Button("Install", action: onAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
    }
}

// MARK: - Preview

struct RepositoriesView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            RepositoriesView()
        }
    }
}

import SwiftUI
import GRDB
import ito_runner

// MARK: - MigrationReportView

/// Presented as a sheet after a backup restore completes.
/// HIG: Sheets are appropriate for "task-specific workflows" that present
/// additional information after an action. The user initiated a restore,
/// so surfacing resolution options in a sheet is the correct pattern.
struct MigrationReportView: View {
    let report: MigrationReport
    let onDismiss: () -> Void

    @StateObject private var repoManager = RepoManager.shared
    @StateObject private var pluginManager = PluginManager.shared

    @State private var installingSourceId: String?
    @State private var remappingPlugin: MigrationReport.UnresolvedPlugin?
    @State private var showRemapPicker = false
    @State private var resolvedSources: Set<String> = []
    @State private var installError: String?
    @State private var showInstallError = false

    var body: some View {
        NavigationView {
            List {
                summarySection
                unresolvedSourcesSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Import Results")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // HIG: "Use labels like 'Done' consistently to indicate completion."
                // Placed as confirmationAction per HIG toolbar guidance.
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDismiss)
                        .font(.headline)
                }
            }
            .sheet(isPresented: $showRemapPicker) {
                if let target = remappingPlugin {
                    RemapPickerView(
                        foreignId: target.foreignId,
                        onSelect: { selectedPluginId in
                            applyRemap(foreignId: target.foreignId, newPluginId: selectedPluginId)
                            showRemapPicker = false
                            remappingPlugin = nil
                        },
                        onCancel: {
                            showRemapPicker = false
                            remappingPlugin = nil
                        }
                    )
                }
            }
            // HIG: Alerts inform people about a problem or a change.
            // Installation failure is an unexpected problem → alert is correct.
            .alert("Installation Failed", isPresented: $showInstallError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(installError ?? "An unknown error occurred.")
            }
        }
    }

    // MARK: - Summary Section

    @ViewBuilder
    private var summarySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                // HIG: Use SF Symbols that match the semantic meaning.
                // checkmark.circle for success tone, exclamationmark.triangle for warning.
                let activeCount = report.unresolvedPlugins.filter { !resolvedSources.contains($0.foreignId) }.count
                let allResolved = activeCount == 0

                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(report.totalItemsImported) items imported")
                            .font(.headline)
                        if allResolved {
                            Text("All sources resolved")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("\(activeCount) source\(activeCount == 1 ? "" : "s") need\(activeCount == 1 ? "s" : "") attention")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: allResolved ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(allResolved ? .green : .orange)
                        .symbolRenderingMode(.multicolor)
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Unresolved Sources Section

    @ViewBuilder
    private var unresolvedSourcesSection: some View {
        // HIG: Section headers should be clear, single-word or short-phrase labels.
        Section {
            ForEach(report.unresolvedPlugins) { plugin in
                unresolvedPluginRow(plugin)
            }
        } header: {
            Text("Sources")
        } footer: {
            Text("Install missing extensions, remap them to an existing Ito plugin, or skip to handle later from your library.")
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func unresolvedPluginRow(_ plugin: MigrationReport.UnresolvedPlugin) -> some View {
        let isResolved = resolvedSources.contains(plugin.foreignId)

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                // HIG: Use Label for icon+text pairs. Display the foreign source name
                // prominently so the user can identify what they're acting on.
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(plugin.foreignId)
                            .font(.body)
                            .fontWeight(.medium)
                        Text("\(plugin.affectedItemCount) item\(plugin.affectedItemCount == 1 ? "" : "s") affected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: isResolved ? "checkmark.circle.fill" : "puzzlepiece.extension")
                        .foregroundStyle(isResolved ? .green : .orange)
                }

                Spacer()

                if !isResolved {
                    confidenceBadge(plugin.confidence, isInstalled: plugin.isInstalled)
                }
            }

            if !isResolved {
                // HIG: Button roles communicate intent. Normal for install/remap,
                // no destructive action here. Capsule shape provides clear tap targets.
                // HIG: "Maintain movement in progress indicators" — ProgressView shown inline.
                HStack(spacing: 8) {
                    if !plugin.isInstalled && plugin.confidence >= 45 {
                        Button {
                            Task { await autoInstall(plugin: plugin) }
                        } label: {
                            Group {
                                if installingSourceId == plugin.foreignId {
                                    ProgressView()
                                        .controlSize(.mini)
                                } else {
                                    Label("Install", systemImage: "arrow.down.circle")
                                }
                            }
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(.blue.opacity(0.12))
                            .foregroundStyle(.blue)
                            .clipShape(Capsule())
                        }
                        .disabled(installingSourceId != nil)
                    }

                    Button {
                        remappingPlugin = plugin
                        showRemapPicker = true
                    } label: {
                        Label("Remap", systemImage: "arrow.triangle.swap")
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(.purple.opacity(0.12))
                            .foregroundStyle(.purple)
                            .clipShape(Capsule())
                    }

                    Button {
                        withAnimation { _ = resolvedSources.insert(plugin.foreignId) }
                    } label: {
                        Text("Skip")
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(.secondary.opacity(0.12))
                            .foregroundStyle(.secondary)
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .animation(.default, value: isResolved)
        .opacity(isResolved ? 0.5 : 1.0)
    }

    // MARK: - Confidence Badge

    /// HIG: Status indicators should use semantic colors (green/yellow/red)
    /// and include a text label for accessibility rather than relying solely on color.
    @ViewBuilder
    private func confidenceBadge(_ confidence: Int, isInstalled: Bool) -> some View {
        if isInstalled && confidence >= 45 {
            Text("Ready")
                .font(.caption2)
                .fontWeight(.medium)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.green.opacity(0.15))
                .foregroundStyle(.green)
                .clipShape(Capsule())
        } else if confidence >= 20 {
            Text("Low Match")
                .font(.caption2)
                .fontWeight(.medium)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.yellow.opacity(0.15))
                .foregroundStyle(.orange)
                .clipShape(Capsule())
        } else {
            Text("Not Found")
                .font(.caption2)
                .fontWeight(.medium)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.red.opacity(0.15))
                .foregroundStyle(.red)
                .clipShape(Capsule())
        }
    }

    // MARK: - Actions

    private func autoInstall(plugin: MigrationReport.UnresolvedPlugin) async {
        installingSourceId = plugin.foreignId

        await RepoManager.shared.refreshAll()

        var targetPkg: RepoPackage?
        var foundRepoUrl: String?

        for repo in RepoManager.shared.repositories {
            if let pkg = repo.index?.packages.first(where: { $0.id == plugin.resolvedId }) {
                targetPkg = pkg
                foundRepoUrl = repo.url
                break
            }
        }

        if let pkg = targetPkg, let url = foundRepoUrl {
            do {
                try await RepoManager.shared.installPackage(pkg, repositoryUrl: url)
                // Refresh plugin cache so library stops showing "missing plugin"
                await PluginManager.shared.reloadInstalledPlugins()
                withAnimation { _ = resolvedSources.insert(plugin.foreignId) }
            } catch {
                installError = "Could not install \"\(plugin.foreignId)\": \(error.localizedDescription)"
                showInstallError = true
            }
        } else {
            installError = "The extension \"\(plugin.resolvedId)\" was not found in any of your repositories."
            showInstallError = true
        }

        installingSourceId = nil
    }

    private func applyRemap(foreignId: String, newPluginId: String) {
        // 1. Persist the user alias for future imports
        PluginResolver.shared.saveUserAlias(foreignId: foreignId, itoPluginId: newPluginId)

        // 2. Find all affected items and the old resolved ID
        guard let plugin = report.unresolvedPlugins.first(where: { $0.foreignId == foreignId }) else { return }
        let oldPluginId = plugin.resolvedId

        // 3. Batch update all LibraryItems in the database
        Task {
            do {
                try await AppDatabase.shared.dbPool.write { db in
                    let items = try LibraryItem.filter(Column("pluginId") == oldPluginId).fetchAll(db)
                    for var item in items {
                        let mangaKey = item.id.replacingOccurrences(of: "\(oldPluginId)_", with: "")
                        let newId = "\(newPluginId)_\(mangaKey)"

                        try LibraryItem.deleteOne(db, key: item.id)

                        try db.execute(
                            sql: "UPDATE itemCategoryLink SET itemId = ? WHERE itemId = ?",
                            arguments: [newId, item.id]
                        )

                        try db.execute(
                            sql: "UPDATE readingHistoryRecord SET libraryItemId = ?, mediaKey = ?, pluginId = ? WHERE pluginId = ? AND libraryItemId = ?",
                            arguments: [newId, newId, newPluginId, oldPluginId, item.id]
                        )

                        item = LibraryItem(
                            id: newId,
                            title: item.title,
                            coverUrl: item.coverUrl,
                            pluginId: newPluginId,
                            isAnime: item.isAnime,
                            pluginType: item.pluginType,
                            rawPayload: item.rawPayload,
                            anilistId: item.anilistId
                        )
                        try item.insert(db)
                    }
                }
                await MainActor.run {
                    _ = withAnimation { resolvedSources.insert(foreignId) }
                }
                // Refresh plugin cache so library picks up the remapped IDs
                await PluginManager.shared.reloadInstalledPlugins()
            } catch {
                print("Remap failed for \(foreignId): \(error)")
            }
        }
    }
}

// MARK: - Remap Picker

/// HIG: This is a selection sheet (sub-modal). It uses .searchable for filtering,
/// a Cancel button in .cancellationAction placement, and clear row layout
/// distinguishing installed vs. available plugins.
struct RemapPickerView: View {
    let foreignId: String
    let onSelect: (String) -> Void
    let onCancel: () -> Void

    @StateObject private var pluginManager = PluginManager.shared
    @StateObject private var repoManager = RepoManager.shared
    @State private var searchText = ""

    private var allOptions: [(id: String, name: String, isInstalled: Bool)] {
        var options: [(id: String, name: String, isInstalled: Bool)] = []

        for (id, plugin) in pluginManager.installedPlugins {
            options.append((id: id, name: plugin.info.name, isInstalled: true))
        }

        for repo in repoManager.repositories {
            guard let packages = repo.index?.packages else { continue }
            for pkg in packages {
                if !options.contains(where: { $0.id == pkg.id }) {
                    options.append((id: pkg.id, name: pkg.name, isInstalled: false))
                }
            }
        }

        return options.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var filteredOptions: [(id: String, name: String, isInstalled: Bool)] {
        if searchText.isEmpty { return allOptions }
        return allOptions.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.id.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationView {
            List {
                // HIG: Section footer provides guidance without cluttering the header.
                Section {
                    ForEach(filteredOptions, id: \.id) { option in
                        Button {
                            onSelect(option.id)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.name)
                                        .font(.body)
                                        .foregroundColor(.primary)
                                    Text(option.id)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }

                                Spacer()

                                if option.isInstalled {
                                    Text("Installed")
                                        .font(.caption2)
                                        .fontWeight(.medium)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.green.opacity(0.12))
                                        .foregroundStyle(.green)
                                        .clipShape(Capsule())
                                }
                            }
                        }
                    }
                } header: {
                    Text("Available Plugins")
                } footer: {
                    Text("Choose the Ito plugin that matches \"\(foreignId)\". This mapping will be remembered for future imports.")
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $searchText, prompt: "Search plugins…")
            .navigationTitle("Remap Source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // HIG: Cancel in .cancellationAction placement
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }
}

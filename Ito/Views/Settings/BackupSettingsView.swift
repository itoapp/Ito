import SwiftUI
import UniformTypeIdentifiers

struct BackupSettingsView: View {
    @StateObject private var backupManager = BackupManager.shared

    @State private var isExporting = false
    @State private var isImporting = false
    @State private var generatedBackup: BackupDocument?

    @State private var showImportOptions = false
    @State private var pendingImportURL: URL?

    @State private var showConflictResolver = false
    @State private var activeConflicts: [MergeConflict] = []

    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var showAlert = false

    @State private var showMigrationReport = false
    @State private var activeMigrationReport: MigrationReport?

    var body: some View {
        List {
            Section(header: Text("Export")) {
                Button(action: exportBackup) {
                    HStack {
                        Label("Create Backup", systemImage: "square.and.arrow.up")
                        Spacer()
                        if backupManager.isExporting {
                            ProgressView()
                        }
                    }
                }
                .disabled(backupManager.isExporting || isExporting)
            }

            Section(header: Text("Import"), footer: Text("Restoring from a backup allows you to completely replace your current library, or merge missing items into it.")) {
                Button(action: { isImporting = true }) {
                    HStack {
                        Label("Restore from Backup", systemImage: "square.and.arrow.down")
                        Spacer()
                        if backupManager.isRestoring {
                            ProgressView()
                        }
                    }
                }
                .disabled(backupManager.isRestoring || isImporting)
            }
        }
        .navigationTitle("Backup & Restore")
        // File Exporter
        .fileExporter(
            isPresented: $isExporting,
            document: generatedBackup,
            contentType: .itoBackup,
            defaultFilename: generatedBackup?.fileURL?.lastPathComponent ?? "ItoBackup"
        ) { result in
            switch result {
            case .success(let url):
                print("Exported to \(url)")
            case .failure(let error):
                showError("Export Failed", error.localizedDescription)
            }
        }
        // File Importer
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.itoBackup, .aidokuBackup, .paperbackBackup, .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    pendingImportURL = url
                    showImportOptions = true
                }
            case .failure(let error):
                showError("Import Failed", error.localizedDescription)
            }
        }
        // Import Strategy Action Sheet
        .confirmationDialog("How would you like to restore?", isPresented: $showImportOptions, titleVisibility: .visible) {
            Button("Merge with Current Library") {
                if let url = pendingImportURL {
                    executeMergeAnalysis(url: url)
                }
            }
            Button("Wipe and Replace Library", role: .destructive) {
                if let url = pendingImportURL {
                    executeFinalImport(url: url, mode: .wipe)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingImportURL = nil
            }
        } message: {
            Text("Merging keeps your existing library items and only adds missing ones. Wiping completely deletes your current library and replaces it with the backup.")
        }
        .sheet(isPresented: $showConflictResolver) {
            if let pendingURL = pendingImportURL {
                MergeResolverView(
                    conflicts: $activeConflicts,
                    onResolve: {
                        showConflictResolver = false
                        var resolutions = [String: ConflictResolution]()
                        for conflict in activeConflicts {
                            resolutions[conflict.id] = conflict.resolution
                        }
                        executeFinalImport(url: pendingURL, mode: .merge, resolutions: resolutions)
                    },
                    onCancel: {
                        showConflictResolver = false
                        pendingImportURL = nil
                    }
                )
                .interactiveDismissDisabled()
            }
        }
        // General Alerts
        .alert(isPresented: $showAlert) {
            Alert(title: Text(alertTitle), message: Text(alertMessage), dismissButton: .default(Text("OK")))
        }
        .sheet(isPresented: $showMigrationReport) {
            if let report = activeMigrationReport {
                MigrationReportView(report: report) {
                    showMigrationReport = false
                    activeMigrationReport = nil
                }
                .interactiveDismissDisabled()
            }
        }
    }

    private func exportBackup() {
        Task {
            do {
                let tempURL = try await backupManager.createBackupFile()
                self.generatedBackup = BackupDocument(url: tempURL)
                self.isExporting = true
            } catch {
                showError("Export Failed", error.localizedDescription)
            }
        }
    }

    private func executeMergeAnalysis(url: URL) {
        Task {
            do {
                let conflicts = try await backupManager.analyzeMerge(from: url)
                if conflicts.isEmpty {
                    // Fast track: no structural differences found
                    executeFinalImport(url: url, mode: .merge)
                } else {
                    // Surface UI resolver
                    self.activeConflicts = conflicts
                    self.showConflictResolver = true
                }
            } catch {
                showError("Merge Check Failed", error.localizedDescription)
            }
        }
    }

    private func executeFinalImport(url: URL, mode: BackupRestoreMode, resolutions: [String: ConflictResolution] = [:]) {
        Task {
            do {
                let report = try await backupManager.restoreBackup(from: url, mode: mode, resolvedConflicts: resolutions)

                if let report = report, report.hasIssues {
                    // Surface migration report
                    activeMigrationReport = report
                    showMigrationReport = true
                } else {
                    alertTitle = "Restore Successful"
                    alertMessage = mode == .wipe ? "Your library has been successfully replaced." : "Your backup has been merged into your library."
                    showAlert = true
                }
                pendingImportURL = nil
            } catch {
                alertTitle = "Restore Failed"
                alertMessage = "An error occurred: \(error.localizedDescription)\n\nYour library was safely reverted and no changes were made."
                showAlert = true
                pendingImportURL = nil
            }
        }
    }

    private func showError(_ title: String, _ message: String) {
        alertTitle = title
        alertMessage = message
        showAlert = true
    }
}

struct BackupSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            BackupSettingsView()
        }
    }
}

import OSLog
import SwiftUI
import UniformTypeIdentifiers

struct BackupPresentationOperationGate {
    private(set) var isRunning = false

    mutating func begin() -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        return true
    }

    mutating func end() {
        isRunning = false
    }
}

struct BackupSettingsView: View {
    @EnvironmentObject private var backupManager: BackupManager
    #if DEBUG
    @ObservedObject private var uiTestFixtures = UITestLaunchFixtureCoordinator.shared
    #endif

    @State private var isExporting = false
    @State private var isImporting = false
    @State private var generatedBackup: BackupDocument?

    @State private var showImportOptions = false
    @State private var showWipeConfirmation = false
    @State private var pendingImportURL: URL?
    @State private var operationGate = BackupPresentationOperationGate()

    @State private var showConflictResolver = false
    @State private var activeConflicts: [MergeConflict] = []
    @State private var activeConflictURL: URL?

    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var showAlert = false

    @State private var showRestoreReport = false
    @State private var activeRestoreReport: BackupRestoreReport?
    @State private var showRefreshPending = false

    var body: some View {
        List {
            #if DEBUG
            if UITestLaunchConfiguration.current.backupWipeEnabled {
                Section("UI Test Fixture") {
                    Text(uiTestFixtures.backupFixtureState.rawValue)
                        .accessibilityIdentifier("backup-fixture-state")
                }
            }
            #endif

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
                Button(action: {
                    guard !operationGate.isRunning else { return }
                    #if DEBUG
                    if UITestLaunchConfiguration.current.backupWipeEnabled {
                        guard let backupURL = uiTestFixtures.backupURL else { return }
                        pendingImportURL = backupURL
                        showImportOptions = true
                        return
                    }
                    #endif
                    isImporting = true
                }) {
                    HStack {
                        Label("Restore from Backup", systemImage: "square.and.arrow.down")
                        Spacer()
                        if backupManager.isRestoring {
                            ProgressView()
                        }
                    }
                }
                .disabled(backupManager.isRestoring || isImporting || operationGate.isRunning)
                .disabled(uiTestRestoreUnavailable)
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
                AppLogger.ui.debug("Exported to \(url)")
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
                guard !operationGate.isRunning else { return }
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
                showWipeConfirmation = true
            }
            Button("Cancel", role: .cancel) {
                pendingImportURL = nil
            }
        } message: {
            Text("Merging keeps your existing library items and only adds missing ones. Wiping completely deletes your current library and replaces it with the backup.")
        }
        .alert("Wipe and Replace Library?", isPresented: $showWipeConfirmation) {
            Button("Wipe and Replace", role: .destructive) {
                if let url = pendingImportURL {
                    executeFinalImport(url: url, mode: .wipe)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingImportURL = nil
            }
        } message: {
            Text("This permanently deletes your current library before restoring the backup. This action cannot be undone.")
        }
        .sheet(isPresented: $showConflictResolver) {
            if let conflictURL = activeConflictURL {
                MergeResolverView(
                    conflicts: $activeConflicts,
                    onResolve: {
                        showConflictResolver = false
                        var resolutions = [String: ConflictResolution]()
                        for conflict in activeConflicts {
                            resolutions[conflict.id] = conflict.resolution
                        }
                        activeConflictURL = nil
                        executeFinalImport(url: conflictURL, mode: .merge, resolutions: resolutions)
                    },
                    onCancel: {
                        showConflictResolver = false
                        activeConflictURL = nil
                        pendingImportURL = nil
                    }
                )
                .interactiveDismissDisabled()
            }
        }
        .alert(isPresented: $showAlert) {
            Alert(title: Text(alertTitle), message: Text(alertMessage), dismissButton: .default(Text("OK")))
        }
        .sheet(isPresented: $showRestoreReport) {
            if let report = activeRestoreReport {
                BackupRestoreReportView(report: report) {
                    guard operationGate.begin() else { return }
                    Task {
                        defer { operationGate.end() }
                        do {
                            _ = try await backupManager.acknowledgeRestoreReport()
                            activeRestoreReport = backupManager.lastRestoreReport
                            showRestoreReport = activeRestoreReport != nil
                        } catch {
                            showError("Acknowledgment Failed", error.localizedDescription)
                        }
                    }
                }
                .interactiveDismissDisabled()
            }
        }
        .alert("Restore committed; refresh pending", isPresented: $showRefreshPending) {
            Button("Retry") {
                guard operationGate.begin() else { return }
                Task {
                    defer { operationGate.end() }
                    do {
                        try await backupManager.retryCommittedRefresh()
                        activeRestoreReport = backupManager.lastRestoreReport
                        showRestoreReport = activeRestoreReport != nil
                    } catch {
                        showRefreshPending = true
                    }
                }
            }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("Your restored data is saved. Refresh must finish before a report can be shown.")
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

    private var uiTestRestoreUnavailable: Bool {
        #if DEBUG
        return UITestLaunchConfiguration.current.backupWipeEnabled
            && uiTestFixtures.backupURL == nil
        #else
        return false
        #endif
    }

    private func executeMergeAnalysis(url: URL) {
        guard operationGate.begin() else { return }
        Task {
            defer { operationGate.end() }
            do {
                let conflicts = try await backupManager.analyzeMerge(from: url)
                if conflicts.isEmpty {
                    await performFinalImport(url: url, mode: .merge)
                } else {
                    self.activeConflicts = conflicts
                    self.activeConflictURL = url
                    self.showConflictResolver = true
                }
            } catch {
                showError("Merge Check Failed", error.localizedDescription)
            }
        }
    }

    private func executeFinalImport(url: URL, mode: BackupRestoreMode, resolutions: [String: ConflictResolution] = [:]) {
        guard operationGate.begin() else { return }
        Task {
            defer { operationGate.end() }
            await performFinalImport(url: url, mode: mode, resolutions: resolutions)
        }
    }

    private func performFinalImport(url: URL, mode: BackupRestoreMode, resolutions: [String: ConflictResolution] = [:]) async {
        do {
            let report = try await backupManager.restoreBackup(
                from: url,
                mode: mode,
                resolvedConflicts: resolutions
            )
            activeRestoreReport = report
            showRestoreReport = true
            activeConflictURL = nil
            pendingImportURL = nil
        } catch BackupRestoreError.restoreCommittedRefreshPending {
            showRefreshPending = true
            activeConflictURL = nil
            pendingImportURL = nil
        } catch {
            alertTitle = "Restore Failed"
            alertMessage = error.localizedDescription
            showAlert = true
            activeConflictURL = nil
            pendingImportURL = nil
        }
        #if DEBUG
        await uiTestFixtures.refreshBackupFixtureState()
        #endif
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

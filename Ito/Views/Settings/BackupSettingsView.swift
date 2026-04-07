import SwiftUI
import UniformTypeIdentifiers

struct BackupSettingsView: View {
    @StateObject private var backupManager = BackupManager.shared

    @State private var isExporting = false
    @State private var isImporting = false
    @State private var generatedBackup: BackupDocument?

    @State private var showImportOptions = false
    @State private var pendingImportURL: URL?

    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var showAlert = false

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
            allowedContentTypes: [.itoBackup, .data],
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
                    executeImport(url: url, mode: .merge)
                }
            }
            Button("Wipe and Replace Library", role: .destructive) {
                if let url = pendingImportURL {
                    executeImport(url: url, mode: .wipe)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingImportURL = nil
            }
        } message: {
            Text("Merging keeps your existing library items and only adds missing ones. Wiping completely deletes your current library and replaces it with the backup.")
        }
        // General Alerts
        .alert(isPresented: $showAlert) {
            Alert(title: Text(alertTitle), message: Text(alertMessage), dismissButton: .default(Text("OK")))
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

    private func executeImport(url: URL, mode: BackupRestoreMode) {
        Task {
            do {
                try await backupManager.restoreBackup(from: url, mode: mode)
                alertTitle = "Restore Successful"
                alertMessage = mode == .wipe ? "Your library has been successfully replaced." : "Your backup has been merged into your library."
                showAlert = true
            } catch {
                alertTitle = "Restore Failed"
                // Explaining HIG revert rules:
                alertMessage = "An error occurred: \(error.localizedDescription)\n\nYour library was safely reverted and no changes were made."
                showAlert = true
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

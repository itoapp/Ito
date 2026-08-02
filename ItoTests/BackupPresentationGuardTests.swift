import Foundation
import Testing
@testable import Ito

struct BackupPresentationGuardTests {
    @MainActor
    @Test func operationGateRejectsRapidDuplicatesUntilReleased() {
        var gate = BackupPresentationOperationGate()

        let first = gate.begin()
        let duplicate = gate.begin()
        #expect(first)
        #expect(!duplicate)
        #expect(gate.isRunning)

        gate.end()
        #expect(!gate.isRunning)

        let afterRelease = gate.begin()
        #expect(afterRelease)
    }

    @Test func productionBindingRequiresTwoWipeConfirmationsAndSynchronousGuards() throws {
        let source = try read("Ito/Views/Settings/BackupSettingsView.swift")

        #expect(source.contains("@State private var showWipeConfirmation = false"))
        #expect(source.contains("showWipeConfirmation = true"))
        #expect(source.contains(".alert(\"Wipe and Replace Library?\", isPresented: $showWipeConfirmation)"))

        let strategyDialog = try #require(
            source.range(of: ".confirmationDialog(\"How would you like to restore?\"")
        )
        let wipeAlert = try #require(
            source.range(
                of: ".alert(\"Wipe and Replace Library?\", isPresented: $showWipeConfirmation)",
                range: strategyDialog.upperBound..<source.endIndex
            )
        )
        let strategyBody = source[strategyDialog.lowerBound..<wipeAlert.lowerBound]
        #expect(strategyBody.contains("Button(\"Wipe and Replace Library\", role: .destructive)"))
        #expect(strategyBody.contains("showWipeConfirmation = true"))
        #expect(!strategyBody.contains("executeFinalImport(url: url, mode: .wipe)"))
        let strategyCancel = try cancelAction(in: strategyBody)
        assertCancellationHasNoRestore(in: strategyCancel)

        let generalAlert = try #require(
            source.range(
                of: ".alert(isPresented: $showAlert)",
                range: wipeAlert.upperBound..<source.endIndex
            )
        )
        let wipeAlertBody = source[wipeAlert.lowerBound..<generalAlert.lowerBound]
        #expect(wipeAlertBody.contains("Button(\"Wipe and Replace\", role: .destructive)"))
        #expect(wipeAlertBody.contains("executeFinalImport(url: url, mode: .wipe)"))
        let wipeCancel = try cancelAction(in: wipeAlertBody)
        assertCancellationHasNoRestore(in: wipeCancel)

        let importerCompletion = try body(
            in: source,
            from: "case .success(let urls):",
            through: "case .failure(let error):"
        )
        let selectionGuard = try #require(
            importerCompletion.range(of: "guard !operationGate.isRunning else { return }")
        )
        let pendingAssignment = try #require(
            importerCompletion.range(of: "pendingImportURL = url")
        )
        #expect(selectionGuard.lowerBound < pendingAssignment.lowerBound)
        let importSelection = try body(
            in: source,
            from: "Section(header: Text(\"Import\")",
            through: ".disabled(backupManager.isRestoring || isImporting || operationGate.isRunning)"
        )
        let buttonGuard = try #require(
            importSelection.range(of: "guard !operationGate.isRunning else { return }")
        )
        let importerPresentation = try #require(
            importSelection.range(of: "isImporting = true")
        )
        #expect(buttonGuard.lowerBound < importerPresentation.lowerBound)

        let reportAcknowledgment = try body(
            in: source,
            from: "BackupRestoreReportView(report: report) {",
            through: ".interactiveDismissDisabled()"
        )
        try assertSynchronousGateBeforeTask(in: reportAcknowledgment)

        let mergeAnalysis = try functionBody(
            named: "private func executeMergeAnalysis(url: URL)",
            next: "private func executeFinalImport",
            in: source
        )
        try assertSynchronousGateBeforeTask(in: mergeAnalysis)

        let finalImport = try functionBody(
            named: "private func executeFinalImport",
            next: "private func performFinalImport",
            in: source
        )
        try assertSynchronousGateBeforeTask(in: finalImport)

        let refreshRetry = try body(
            in: source,
            from: "Button(\"Retry\") {",
            through: "Button(\"Not Now\", role: .cancel)"
        )
        try assertSynchronousGateBeforeTask(in: refreshRetry)

        let noConflictMerge = try body(
            in: String(mergeAnalysis),
            from: "if conflicts.isEmpty {",
            through: "} else {"
        )
        #expect(noConflictMerge.contains("await performFinalImport(url: url, mode: .merge)"))
        #expect(!noConflictMerge.contains("executeFinalImport"))

        #expect(source.contains("@State private var activeConflictURL: URL?"))
        #expect(source.contains("activeConflictURL = url"))
        #expect(source.contains("if let conflictURL = activeConflictURL"))
        #expect(source.contains("executeFinalImport(url: conflictURL, mode: .merge, resolutions: resolutions)"))
    }

    private func assertCancellationHasNoRestore(in source: Substring) {
        #expect(source.contains("pendingImportURL = nil"))
        #expect(!source.contains("restoreBackup"))
        #expect(!source.contains("executeMergeAnalysis"))
        #expect(!source.contains("executeFinalImport"))
        #expect(!source.contains("performFinalImport"))
    }

    private func assertSynchronousGateBeforeTask(in source: Substring) throws {
        let gate = try #require(source.range(of: "guard operationGate.begin() else { return }"))
        let task = try #require(source.range(of: "Task {"))
        #expect(gate.lowerBound < task.lowerBound)
        #expect(source.contains("defer { operationGate.end() }"))
    }

    private func functionBody(
        named name: String,
        next nextName: String,
        in source: String
    ) throws -> Substring {
        let start = try #require(source.range(of: name))
        let end = try #require(
            source.range(of: nextName, range: start.upperBound..<source.endIndex)
        )
        return source[start.lowerBound..<end.lowerBound]
    }

    private func body(
        in source: String,
        from startText: String,
        through endText: String
    ) throws -> Substring {
        let start = try #require(source.range(of: startText))
        let end = try #require(
            source.range(of: endText, range: start.upperBound..<source.endIndex)
        )
        return source[start.lowerBound..<end.upperBound]
    }

    private func cancelAction(in source: Substring) throws -> Substring {
        let start = try #require(source.range(of: "Button(\"Cancel\", role: .cancel) {"))
        let end = try #require(
            source.range(of: "} message:", range: start.upperBound..<source.endIndex)
        )
        return source[start.lowerBound..<end.lowerBound]
    }

    private func read(_ path: String) throws -> String {
        let testsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repositoryURL = testsURL.deletingLastPathComponent()
        return try String(contentsOf: repositoryURL.appendingPathComponent(path), encoding: .utf8)
    }
}

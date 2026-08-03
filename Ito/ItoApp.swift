import BackgroundTasks
import OSLog
import SwiftUI

@main
@MainActor
struct ItoApp: App {
    @StateObject private var bootstrap = DurableStateBootstrap.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "moe.itoapp.ito.refresh", using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else { return }
            Self.handleAppRefresh(task: refreshTask)
        }
    }

    var body: some Scene {
        WindowGroup {
            BootstrapGateView(bootstrap: bootstrap)
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .background else { return }
            Task { await Self.scheduleAppRefresh(bootstrap: bootstrap) }
        }
    }

    private static func scheduleAppRefresh(bootstrap: DurableStateBootstrap) async {
        guard await bootstrap.prepare() else { return }
        do {
            guard let settingsStore = bootstrap.settingsStore,
                  settingsStore.backgroundUpdatesEnabled else { return }

            let request = BGAppRefreshTaskRequest(identifier: "moe.itoapp.ito.refresh")
            request.earliestBeginDate = Date(
                timeIntervalSinceNow: TimeInterval(settingsStore.updateInterval.rawValue * 3_600)
            )
            try BGTaskScheduler.shared.submit(request)
        } catch {
            AppLogger.general.error("Failed to schedule app refresh: \(error)")
        }
    }

    private static func handleAppRefresh(task: BGAppRefreshTask) {
        let taskWrapper = Task { @MainActor in
            let bootstrap = DurableStateBootstrap.shared
            guard await bootstrap.prepare() else {
                task.setTaskCompleted(success: false)
                return
            }

            await scheduleAppRefresh(bootstrap: bootstrap)
            guard let updateManager = bootstrap.updateManager else {
                task.setTaskCompleted(success: false)
                return
            }
            let updatedItems = await updateManager.checkForUpdatesInBackground()
            if !updatedItems.isEmpty, let notificationManager = bootstrap.notificationManager {
                await notificationManager.dispatchUpdateSummary(updatedItems: updatedItems)
            }
            task.setTaskCompleted(success: true)
        }

        task.expirationHandler = {
            taskWrapper.cancel()
        }
    }
}

@MainActor
private struct BootstrapGateView: View {
    @ObservedObject var bootstrap: DurableStateBootstrap

    var body: some View {
        switch bootstrap.state {
        case .idle, .preparing:
            ProgressView("Preparing your library…")
                .task { _ = await bootstrap.prepare() }
        case .awaitingRestoreAcknowledgment(let report):
            BackupRestoreReportView(report: report) {
                Task { _ = await bootstrap.acknowledgeRestoreReport() }
            }
            .interactiveDismissDisabled()
        case .restoreCommittedRefreshPending:
            VStack(spacing: 16) {
                Image(systemName: "arrow.clockwise.circle")
                    .font(.largeTitle)
                Text("Restore committed; refresh pending")
                    .font(.headline)
                Text("Your restored data is saved. Refresh must finish before the app can continue.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") {
                    Task { _ = await bootstrap.retry() }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        case .ready:
            if let settingsStore = bootstrap.settingsStore,
               let progressManager = bootstrap.readProgressManager,
               let trackerManager = bootstrap.trackerManager,
               let updateManager = bootstrap.updateManager,
               let repoManager = bootstrap.repoManager,
               let pluginResolver = bootstrap.pluginResolver,
               let libraryManager = bootstrap.libraryManager,
               let pluginManager = bootstrap.pluginManager,
               let storageManager = bootstrap.storageManager,
               let discordRPCManager = bootstrap.discordRPCManager,
               let historyManager = bootstrap.historyManager,
               let notificationManager = bootstrap.notificationManager,
               let backupManager = bootstrap.backupManager,
               let librarySourceRemapper = bootstrap.librarySourceRemapper,
               let appScope = bootstrap.appScope {
                DurableApplicationView(
                    settingsStore: settingsStore,
                    progressManager: progressManager,
                    trackerManager: trackerManager,
                    updateManager: updateManager,
                    repoManager: repoManager,
                    pluginResolver: pluginResolver,
                    libraryManager: libraryManager,
                    pluginManager: pluginManager,
                    storageManager: storageManager,
                    discordRPCManager: discordRPCManager,
                    historyManager: historyManager,
                    notificationManager: notificationManager,
                    backupManager: backupManager,
                    librarySourceRemapper: librarySourceRemapper,
                    appScope: appScope
                )
            } else {
                BootstrapFailureView(
                    title: "Couldn’t start the app",
                    message: "Required runtime services are unavailable. Retry to prepare them again."
                ) {
                    Task { _ = await bootstrap.retryRuntimeInvariantFailure() }
                }
            }
        case .failed(let message):
            BootstrapFailureView(
                title: "Couldn’t prepare your library",
                message: message
            ) {
                Task { _ = await bootstrap.retry() }
            }
        }
    }
}

private struct BootstrapFailureView: View {
    let title: String
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.clockwise.circle")
                .font(.largeTitle)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

@MainActor
private struct DurableApplicationView: View {
    @ObservedObject var settingsStore: AppSettingsStore
    @ObservedObject var progressManager: ReadProgressManager
    @ObservedObject var trackerManager: TrackerManager
    @ObservedObject var updateManager: UpdateManager
    @ObservedObject var repoManager: RepoManager
    let pluginResolver: PluginResolver
    let libraryManager: LibraryManager
    let pluginManager: PluginManager
    let storageManager: StorageManager
    let discordRPCManager: DiscordRPCManager
    let historyManager: HistoryManager
    let notificationManager: NotificationManager
    let backupManager: BackupManager
    let librarySourceRemapper: LibrarySourceRemapper
    let appScope: AppScope
    private let trackerCredentialLifecycle: TrackerCredentialLifecycle
    @Environment(\.scenePhase) private var scenePhase

    init(
        settingsStore: AppSettingsStore,
        progressManager: ReadProgressManager,
        trackerManager: TrackerManager,
        updateManager: UpdateManager,
        repoManager: RepoManager,
        pluginResolver: PluginResolver,
        libraryManager: LibraryManager,
        pluginManager: PluginManager,
        storageManager: StorageManager,
        discordRPCManager: DiscordRPCManager,
        historyManager: HistoryManager,
        notificationManager: NotificationManager,
        backupManager: BackupManager,
        librarySourceRemapper: LibrarySourceRemapper,
        appScope: AppScope
    ) {
        self.settingsStore = settingsStore
        self.progressManager = progressManager
        self.trackerManager = trackerManager
        self.updateManager = updateManager
        self.repoManager = repoManager
        self.pluginResolver = pluginResolver
        self.libraryManager = libraryManager
        self.pluginManager = pluginManager
        self.storageManager = storageManager
        self.discordRPCManager = discordRPCManager
        self.historyManager = historyManager
        self.notificationManager = notificationManager
        self.backupManager = backupManager
        self.librarySourceRemapper = librarySourceRemapper
        self.appScope = appScope
        trackerCredentialLifecycle = TrackerCredentialLifecycle(manager: trackerManager)
    }

    var body: some View {
        MainTabView(appScope: appScope)
            .environmentObject(progressManager)
            .environmentObject(trackerManager)
            .environmentObject(updateManager)
            .environmentObject(repoManager)
            .environmentObject(pluginResolver)
            .environmentObject(settingsStore)
            .environmentObject(libraryManager)
            .environmentObject(pluginManager)
            .environmentObject(storageManager)
            .environmentObject(discordRPCManager)
            .environmentObject(historyManager)
            .environmentObject(notificationManager)
            .environmentObject(backupManager)
            .environmentObject(librarySourceRemapper)
            .preferredColorScheme(settingsStore.appTheme.colorScheme)
            .onOpenURL { url in
                guard url.scheme == "ito", url.host == "repo", url.path == "/add",
                      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                      let repoURL = components.queryItems?.first(where: { $0.name == "url" })?.value else {
                    return
                }
                Task {
                    do {
                        try await repoManager.addRepository(url: repoURL)
                    } catch {
                        AppLogger.general.error("Failed to add repo via deep link: \(error)")
                    }
                }
            }
            .task {
                await trackerCredentialLifecycle.appDidLaunch()
            }
            .onChange(of: scenePhase) { phase in
                guard phase == .active else { return }
                Task { await trackerCredentialLifecycle.appDidBecomeActive() }
            }
    }
}

//
//  ItoApp.swift
//  Ito
//
//  Created by caocao on 3/3/26.
//

import SwiftUI
import BackgroundTasks

@main
struct ItoApp: App {
    @StateObject private var appearanceManager = AppearanceManager.shared

    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Initialize StorageManager early to set URLCache disk capacity
        _ = StorageManager.shared

        // Register Background Task
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.kunihir0.ito.refresh", using: nil) { task in
            if let refreshTask = task as? BGAppRefreshTask {
                Self.handleAppRefresh(task: refreshTask)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(ReadProgressManager.shared)
                .preferredColorScheme(appearanceManager.selectedTheme.colorScheme)
                .onOpenURL { url in
                    if url.scheme == "ito" && url.host == "repo" && url.path == "/add" {
                        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                           let queryItem = components.queryItems?.first(where: { $0.name == "url" }),
                           let repoUrl = queryItem.value {
                            Task {
                                do {
                                    try await RepoManager.shared.addRepository(url: repoUrl)
                                } catch {
                                    print("Failed to add repo via deep link: \(error)")
                                }
                            }
                        }
                    }
                }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                ItoApp.scheduleAppRefresh()
            }
        }
    }

    // MARK: - Background Tasks

    private static func scheduleAppRefresh() {
        let isEnabled = UserDefaults.standard.bool(forKey: UserDefaultsKeys.bgUpdatesEnabled)
        guard isEnabled else { return }

        let request = BGAppRefreshTaskRequest(identifier: "com.kunihir0.ito.refresh")

        // Get update interval in hours from settings (default 4)
        let intervalHours = UserDefaults.standard.object(forKey: UserDefaultsKeys.updateInterval) as? Int ?? 4
        request.earliestBeginDate = Date(timeIntervalSinceNow: TimeInterval(intervalHours * 3600))

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("Failed to schedule app refresh: \(error)")
        }
    }

    private static func handleAppRefresh(task: BGAppRefreshTask) {
        // Schedule the next one immediately
        scheduleAppRefresh()

        // Wrap the update manager call in a generic Task
        let taskWrapper = Task<Void, Never> {
            let updatedItems = await UpdateManager.shared.checkForUpdatesInBackground()
            if !updatedItems.isEmpty {
                await NotificationManager.shared.dispatchUpdateSummary(updatedItems: updatedItems)
            }
            task.setTaskCompleted(success: true)
        }

        // If the system tells us to expire, cancel the task
        task.expirationHandler = {
            taskWrapper.cancel()
        }
    }
}

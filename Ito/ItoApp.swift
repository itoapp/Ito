//
//  ItoApp.swift
//  Ito
//
//  Created by caocao on 3/3/26.
//

import SwiftUI

@main
struct ItoApp: App {
    @StateObject private var appearanceManager = AppearanceManager.shared
    
    init() {
        // Initialize StorageManager early to set URLCache disk capacity
        _ = StorageManager.shared
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
    }
}

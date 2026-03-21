import SwiftUI

struct TrackerSettingsView: View {
    @StateObject private var trackerManager = TrackerManager.shared
    @State private var authenticatingProvider: String?
    @State private var authError: String?

    // Force a view refresh after auth changes
    @State private var refreshTrigger = false

    var body: some View {
        List {
            ForEach(trackerManager.providers, id: \.identifier) { provider in
                Section(header: Text(provider.name), footer: Text("Sync your progress automatically with \(provider.name).")) {
                    if provider.isAuthenticated {
                        HStack {
                            Image(systemName: "person.crop.circle.fill")
                                .foregroundColor(.blue)
                            if let username = provider.username {
                                Text("Logged in as \(username)")
                            } else {
                                Text("Logged in")
                            }
                            Spacer()
                        }

                        Button(action: {
                            provider.logout()
                            refreshTrigger.toggle()
                        }) {
                            Text("Log Out")
                                .foregroundColor(.red)
                        }
                    } else {
                        Button(action: {
                            authenticate(provider: provider)
                        }) {
                            HStack {
                                if authenticatingProvider == provider.identifier {
                                    ProgressView()
                                        .padding(.trailing, 8)
                                }
                                Text("Login with \(provider.name)")
                                    .foregroundColor(.blue)
                            }
                        }
                        .disabled(authenticatingProvider != nil)
                    }

                    if let error = authError, authenticatingProvider == provider.identifier {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
            }

            Section(header: Text("Preferences"), footer: Text("When updating or tracking a series, automatically mark all previous chapters or episodes as read/watched in your local library.")) {
                Toggle("Sync Trackers to Local Library", isOn: Binding(
                    get: { UserDefaults.standard.object(forKey: "Ito.AutoSyncTrackersToLocal") as? Bool ?? true },
                    set: { UserDefaults.standard.set($0, forKey: "Ito.AutoSyncTrackersToLocal") }
                ))
            }
        }
        .navigationTitle("Trackers")
        .navigationBarTitleDisplayMode(.inline)
        .id(refreshTrigger) // forces list to redraw when auth changes
    }

    private func authenticate(provider: any TrackerProvider) {
        authenticatingProvider = provider.identifier
        authError = nil

        Task {
            do {
                try await provider.authenticate(using: OAuthManager.shared)
                await MainActor.run {
                    refreshTrigger.toggle()
                }
            } catch {
                await MainActor.run {
                    authError = "Authentication failed: \(error.localizedDescription)"
                }
            }
            await MainActor.run {
                authenticatingProvider = nil
            }
        }
    }
}

struct TrackerSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        TrackerSettingsView()
    }
}

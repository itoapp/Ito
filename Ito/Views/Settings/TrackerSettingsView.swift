import SwiftUI

struct TrackerSettingsView: View {
    @StateObject private var trackerManager = TrackerManager.shared
    @State private var isAuthenticating = false
    @State private var authError: String?

    var body: some View {
        List {
            Section(header: Text("AniList"), footer: Text("Sync your progress automatically with AniList.")) {
                if trackerManager.isAnilistAuthenticated {
                    HStack {
                        Image(systemName: "person.crop.circle.fill")
                            .foregroundColor(.blue)
                        if let username = trackerManager.anilistUsername {
                            Text("Logged in as \(username)")
                        } else {
                            Text("Logged in")
                        }
                        Spacer()
                    }

                    Button(action: {
                        trackerManager.logoutAnilist()
                    }) {
                        Text("Log Out")
                            .foregroundColor(.red)
                    }
                } else {
                    Button(action: {
                        authenticate()
                    }) {
                        HStack {
                            if isAuthenticating {
                                ProgressView()
                                    .padding(.trailing, 8)
                            }
                            Text("Login with AniList")
                                .foregroundColor(.blue)
                        }
                    }
                    .disabled(isAuthenticating)
                }

                if let error = authError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            Section(header: Text("Preferences"), footer: Text("When updating or tracking a series on AniList, automatically mark all previous chapters or episodes as read/watched in your local library.")) {
                Toggle("Sync AniList to Local Library", isOn: Binding(
                    get: { UserDefaults.standard.object(forKey: "Ito.AutoSyncAnilistToLocal") as? Bool ?? true },
                    set: { UserDefaults.standard.set($0, forKey: "Ito.AutoSyncAnilistToLocal") }
                ))
            }
        }
        .navigationTitle("Trackers")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func authenticate() {
        isAuthenticating = true
        authError = nil

        Task {
            do {
                try await trackerManager.authenticateWithAnilist()
            } catch {
                authError = "Authentication failed: \(error.localizedDescription)"
            }
            isAuthenticating = false
        }
    }
}

#Preview {
    TrackerSettingsView()
}

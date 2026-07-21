import SwiftUI

enum TrackerSettingsCredentialState: Equatable {
    case loading
    case deferred
    case ready
    case unavailable

    init(_ bootstrapState: TrackerManager.CredentialBootstrapState) {
        switch bootstrapState {
        case .notStarted, .inFlight:
            self = .loading
        case .retryableProtectedDataFailure:
            self = .deferred
        case .ready, .conflict:
            self = .ready
        case .recoverableVerificationFailure, .permanentFailure:
            self = .unavailable
        }
    }
}

struct TrackerSettingsView: View {
    @StateObject private var trackerManager = TrackerManager.shared
    @State private var authenticatingProvider: String?
    @State private var authError: String?
    @State private var errorProvider: String?

    // Force a view refresh after auth changes
    @State private var refreshTrigger = false

    var body: some View {
        List {
            ForEach(trackerManager.providers, id: \.identifier) { provider in
                Section(header: Text(provider.name), footer: Text("Sync your progress automatically with \(provider.name).")) {
                    switch TrackerSettingsCredentialState(trackerManager.credentialBootstrapState) {
                    case .loading:
                        HStack {
                            ProgressView()
                                .padding(.trailing, 8)
                            Text("Checking saved credentials…")
                        }
                    case .deferred:
                        Label("Saved credentials will be checked when protected data is available.", systemImage: "lock.fill")
                            .foregroundColor(.secondary)
                    case .unavailable:
                        Label("Saved credentials are currently unavailable.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                    case .ready where provider.isAuthenticated:
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
                            logout(provider: provider)
                        }) {
                            Text("Log Out")
                                .foregroundColor(.red)
                        }
                    case .ready:
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

                    if let error = authError, errorProvider == provider.identifier {
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
        errorProvider = nil

        Task {
            defer { authenticatingProvider = nil }
            do {
                try await provider.authenticate(using: OAuthManager.shared)
                refreshTrigger.toggle()
            } catch {
                authError = "Authentication failed: \(error.localizedDescription)"
                errorProvider = provider.identifier
            }
        }
    }

    private func logout(provider: any TrackerProvider) {
        authenticatingProvider = provider.identifier
        authError = nil
        errorProvider = nil

        Task {
            defer { authenticatingProvider = nil }
            do {
                try await provider.logout()
                refreshTrigger.toggle()
            } catch {
                authError = "Logout failed: \(error.localizedDescription)"
                errorProvider = provider.identifier
            }
        }
    }
}

struct TrackerSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        TrackerSettingsView()
    }
}

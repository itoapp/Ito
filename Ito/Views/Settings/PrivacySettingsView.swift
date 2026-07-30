import SwiftUI

struct PrivacySettingsView: View {
    @EnvironmentObject private var settingsStore: AppSettingsStore
    @EnvironmentObject private var discordRPC: DiscordRPCManager

    var body: some View {
        Form {
            Section(
                header: Text("History"),
                footer: Text("When Incognito Mode is enabled, items you read or watch will not be saved to your History. Your library and progress trackers will still be updated.")
            ) {
                Toggle(isOn: Binding(
                    get: { settingsStore.incognitoMode },
                    set: { value in
                        Task { try? await settingsStore.set(value, for: AppPreferenceCatalog.incognitoMode) }
                    }
                )) {
                    Label("Incognito Mode", systemImage: "eyes")
                }
        }

            Section {
                Toggle(isOn: Binding(
                    get: { settingsStore.discordRPCEnabled },
                    set: { value in
                        Task { try? await settingsStore.set(value, for: AppPreferenceCatalog.discordRPCEnabled) }
                    }
                )) {
                    Label("Discord Rich Presence", systemImage: "gamecontroller")
                }

                if discordRPC.isEnabled {
                    TextField("Server URL (e.g. ws://127.0.0.1:3000)", text: Binding(
                        get: { settingsStore.discordRPCURL },
                        set: { value in
                            Task { try? await settingsStore.set(value, for: AppPreferenceCatalog.discordRPCURL) }
                        }
                    ))
                    .autocapitalization(.none)
                    .disableAutocorrection(true)

                    HStack {
                        Text("Status")
                        Spacer()
                        Group {
                            switch discordRPC.state {
                            case .connected:
                                Text("Connected").foregroundColor(.green)
                            case .connecting:
                                Text("Connecting...").foregroundColor(.yellow)
                            case .disconnected:
                                Text("Disconnected").foregroundColor(.gray)
                            case .error(let msg):
                                Text("Error: \(msg)").foregroundColor(.red).lineLimit(1)
                            }
                        }
                    }
                }
            } header: {
                Text("Discord Integration")
            } footer: {
                Text("Broadcasts your reading and watching activity to Discord via a local Rust WebSocket server.")
            }
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct PrivacySettingsView_Previews: PreviewProvider {
    static var previews: some View {
        PrivacySettingsView()
    }
}

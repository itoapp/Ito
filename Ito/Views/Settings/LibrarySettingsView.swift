import SwiftUI

struct LibrarySettingsView: View {
    @AppStorage(UserDefaultsKeys.alwaysShowCategoryPicker) private var alwaysShowCategoryPicker: Bool = false

    // Updates
    @AppStorage(UserDefaultsKeys.bgUpdatesEnabled) private var bgUpdatesEnabled: Bool = true
    @AppStorage(UserDefaultsKeys.updateInterval) private var updateInterval: Int = 4
    @AppStorage(UserDefaultsKeys.skipCompleted) private var skipCompleted: Bool = true
    @AppStorage(UserDefaultsKeys.updateNotifications) private var updateNotifications: Bool = true

    // Network
    @AppStorage(UserDefaultsKeys.wifiOnlyUpdates) private var wifiOnlyUpdates: Bool = false

    @State private var showingNotificationAlert = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $alwaysShowCategoryPicker) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Prompt Category on Save")
                        Text("Show the list picker when saving a new series.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Saving")
            } footer: {
                Text("When enabled, saving a new series will immediately show the category assignment sheet instead of saving to Uncategorized. Only applies when you have at least one custom category.")
            }

            Section {
                Toggle("Check for Updates", isOn: $bgUpdatesEnabled)

                if bgUpdatesEnabled {
                    Toggle("Notify on New Chapters", isOn: $updateNotifications)
                        .onChange(of: updateNotifications) { newValue in
                            if newValue {
                                Task {
                                    let granted = await NotificationManager.shared.requestPermission()
                                    if !granted {
                                        await MainActor.run {
                                            showingNotificationAlert = true
                                            updateNotifications = false
                                        }
                                    }
                                }
                            }
                        }

                    Picker("Update Frequency", selection: $updateInterval) {
                        Text("1 Hour").tag(1)
                        Text("2 Hours").tag(2)
                        Text("4 Hours").tag(4)
                        Text("6 Hours").tag(6)
                        Text("12 Hours").tag(12)
                        Text("24 Hours").tag(24)
                    }

                    Toggle("Skip Completed Series", isOn: $skipCompleted)
                }
            } header: {
                Text("Updates")
            } footer: {
                Text("Background checks run approximately at the chosen interval. Actual timing is managed by iOS.")
            }

            Section {
                Toggle("Wi-Fi Only", isOn: $wifiOnlyUpdates)
            } header: {
                Text("Restrictions")
            } footer: {
                Text("Only check for updates when connected to Wi-Fi.")
            }
        }
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Notifications Disabled", isPresented: $showingNotificationAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        } message: {
            Text("Please enable notifications for Ito in your device Settings to receive update alerts.")
        }
    }
}

struct LibrarySettingsView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            LibrarySettingsView()
        }
    }
}

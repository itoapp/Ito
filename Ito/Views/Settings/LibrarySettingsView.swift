import SwiftUI

struct LibrarySettingsView: View {
    @EnvironmentObject private var notificationManager: NotificationManager
    @EnvironmentObject private var settingsStore: AppSettingsStore
    @State private var showingNotificationAlert = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: binding(
                    settingsStore.alwaysShowCategoryPicker,
                    key: AppPreferenceCatalog.alwaysShowCategoryPicker
                )) {
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
                Toggle("Check for Updates", isOn: binding(
                    settingsStore.backgroundUpdatesEnabled,
                    key: AppPreferenceCatalog.backgroundUpdatesEnabled
                ))

                if settingsStore.backgroundUpdatesEnabled {
                    Toggle("Notify on New Chapters", isOn: binding(
                        settingsStore.updateNotifications,
                        key: AppPreferenceCatalog.updateNotifications
                    ))
                        .onChange(of: settingsStore.updateNotifications) { newValue in
                            if newValue {
                                Task {
                                    let granted = await notificationManager.requestPermission()
                                    if !granted {
                                        showingNotificationAlert = true
                                        try? await settingsStore.set(
                                            false,
                                            for: AppPreferenceCatalog.updateNotifications
                                        )
                                    }
                                }
                            }
                        }

                    Picker("Update Frequency", selection: binding(
                        settingsStore.updateInterval,
                        key: AppPreferenceCatalog.updateInterval
                    )) {
                        Text("1 Hour").tag(UpdateIntervalPreference.hourly)
                        Text("2 Hours").tag(UpdateIntervalPreference.twoHours)
                        Text("4 Hours").tag(UpdateIntervalPreference.fourHours)
                        Text("6 Hours").tag(UpdateIntervalPreference.sixHours)
                        Text("12 Hours").tag(UpdateIntervalPreference.twelveHours)
                        Text("24 Hours").tag(UpdateIntervalPreference.daily)
                    }

                    Toggle("Skip Completed Series", isOn: binding(
                        settingsStore.skipCompleted,
                        key: AppPreferenceCatalog.skipCompleted
                    ))
                }
            } header: {
                Text("Updates")
            } footer: {
                Text("Background checks run approximately at the chosen interval. Actual timing is managed by iOS.")
            }

            Section {
                Toggle("Wi-Fi Only", isOn: binding(
                    settingsStore.wifiOnlyUpdates,
                    key: AppPreferenceCatalog.wifiOnlyUpdates
                ))
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

    private func binding<Value: Codable & Sendable>(
        _ value: Value,
        key: AppPreferenceKey<Value>
    ) -> Binding<Value> {
        Binding(
            get: { value },
            set: { newValue in
                Task { try? await settingsStore.set(newValue, for: key) }
            }
        )
    }
}

struct LibrarySettingsView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            LibrarySettingsView()
        }
    }
}

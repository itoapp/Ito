import SwiftUI

struct AppearanceSettingsView: View {
    @EnvironmentObject private var settingsStore: AppSettingsStore

    var body: some View {
        Form {
            Section(header: Text("Theme"), footer: Text("Choose your preferred appearance.")) {
                Picker("Appearance", selection: Binding(
                    get: { settingsStore.appTheme },
                    set: { value in
                        Task { try? await settingsStore.set(value, for: AppPreferenceCatalog.appTheme) }
                    }
                )) {
                    ForEach(AppThemePreference.allCases) { theme in
                        Text(theme.rawValue).tag(theme)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AppearanceSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        AppearanceSettingsView()
    }
}

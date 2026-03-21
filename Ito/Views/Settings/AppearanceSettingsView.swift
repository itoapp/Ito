import SwiftUI

struct AppearanceSettingsView: View {
    @StateObject private var appearanceManager = AppearanceManager.shared

    var body: some View {
        Form {
            Section(header: Text("Theme"), footer: Text("Choose your preferred appearance.")) {
                Picker("Appearance", selection: $appearanceManager.selectedTheme) {
                    ForEach(AppTheme.allCases) { theme in
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

import SwiftUI

struct PrivacySettingsView: View {
    @AppStorage("Ito.IncognitoMode") private var isIncognitoMode: Bool = false

    var body: some View {
        Form {
            Section(
                header: Text("History"),
                footer: Text("When Incognito Mode is enabled, items you read or watch will not be saved to your History. Your library and progress trackers will still be updated.")
            ) {
                Toggle(isOn: $isIncognitoMode) {
                    Label("Incognito Mode", systemImage: "eyes")
                }
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

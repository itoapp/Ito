import SwiftUI

struct SettingsView: View {
    var body: some View {
        NavigationView {
            List {
                Section(header: Text("General")) {
                    NavigationLink(destination: AppearanceSettingsView()) {
                        Label("Appearance", systemImage: "paintpalette")
                    }
                    NavigationLink(destination: Text("Reader Settings View")) {
                        Label("Reader", systemImage: "book")
                    }
                }

                Section(header: Text("Data")) {
                    NavigationLink(destination: StorageSettingsView()) {
                        Label("Storage", systemImage: "internaldrive")
                    }
                    NavigationLink(destination: Text("Network Settings View")) {
                        Label("Network", systemImage: "wifi")
                    }
                    NavigationLink(destination: TrackerSettingsView()) {
                        Label("Trackers", systemImage: "arrow.triangle.2.circlepath")
                    }
                }

                Section(header: Text("Extensions")) {
                    NavigationLink(destination: Text("Manage Extensions View")) {
                        Label("Browse Installers", systemImage: "puzzlepiece.extension")
                    }
                }

                Section(header: Text("About")) {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
        }
        .navigationViewStyle(.stack)
    }
}

#Preview {
    SettingsView()
}

import SwiftUI

struct StorageSettingsView: View {
    @StateObject private var storageManager = StorageManager.shared

    var body: some View {
        Form {
            Section(
                header: Text("Image & Network Cache"),
                footer: Text("Set the maximum amount of disk space Ito is allowed to use for caching images and network responses.")
            ) {
                Picker("Cache Limit", selection: $storageManager.diskCacheLimitGB) {
                    ForEach(Array(stride(from: 1.0, through: 50.0, by: 1.0)), id: \.self) { value in
                        Text("\(Int(value)) GB").tag(value)
                    }
                }
                .pickerStyle(.wheel)

                HStack {
                    Text("Current Usage")
                    Spacer()
                    Text(storageManager.formatBytes(storageManager.currentCacheSizeBytes))
                        .foregroundColor(.secondary)
                }

                Button(action: {
                    storageManager.clearCache()
                }) {
                    Text("Clear Cache")
                        .foregroundColor(.red)
                }
            }
        }
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            storageManager.refreshCacheSize()
        }
    }
}

struct StorageSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        StorageSettingsView()
    }
}

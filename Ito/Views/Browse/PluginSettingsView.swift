import SwiftUI
import ito_runner

extension Setting: @retroactive Identifiable {
    public var id: String {
        switch self {
        case .toggle(let id, _, _, _): return id
        case .text(let id, _, _, _): return id
        case .picker(let id, _, _, _, _): return id
        }
    }
}

struct PluginSettingsView: View {
    let plugin: InstalledPlugin
    let schema: SettingsSchema

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var pluginManager: PluginManager
    @State private var isPrepared = false
    @State private var preparationError: String?

    var body: some View {
        NavigationView {
            Form {
                if isPrepared {
                    ForEach(schema.settings, id: \.id) { setting in
                        SettingRowView(
                            setting: setting,
                            pluginId: plugin.info.id,
                            store: pluginManager.pluginSettingsStore
                        )
                    }
                } else if preparationError != nil {
                    Section {
                        Label(
                            "Plugin settings could not be loaded. No changes were applied.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundColor(.red)
                    }
                } else {
                    ProgressView("Preparing plugin settings…")
                }
            }
            .navigationTitle("\(plugin.info.name) Settings")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(trailing: Button("Done") {
                dismiss()
            })
            .task {
                do {
                    try pluginManager.pluginSettingsStore.prepare(pluginId: plugin.info.id)
                    isPrepared = true
                } catch {
                    preparationError = String(describing: error)
                }
            }
        }
    }
}

private struct SettingRowView: View {
    let setting: Setting
    let pluginId: String
    @ObservedObject var store: PluginSettingsStore

    var body: some View {
        switch setting {
        case .toggle(let id, let name, let summary, let defaultValue):
            ToggleSettingRow(id: id, name: name, summary: summary, defaultValue: defaultValue, pluginId: pluginId, store: store)
        case .text(let id, let name, let summary, let defaultValue):
            TextSettingRow(id: id, name: name, summary: summary, defaultValue: defaultValue, pluginId: pluginId, store: store)
        case .picker(let id, let name, let summary, let options, let defaultValue):
            PickerSettingRow(id: id, name: name, summary: summary, options: options, defaultValue: defaultValue, pluginId: pluginId, store: store)
        }
    }
}

private struct ToggleSettingRow: View {
    let id: String
    let name: String
    let summary: String?
    let defaultValue: Bool
    let pluginId: String
    @ObservedObject var store: PluginSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(name, isOn: Binding(
                get: { store.get(pluginId: pluginId, key: id).map { $0 == "true" } ?? defaultValue },
                set: {
                    store.set(pluginId: pluginId, key: id, value: $0 ? "true" : "false")
                }
            ))
            if let summary = summary, !summary.isEmpty {
                Text(summary)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
        .onAppear {
            if store.get(pluginId: pluginId, key: id) == nil {
                store.set(
                    pluginId: pluginId,
                    key: id,
                    value: defaultValue ? "true" : "false"
                )
            }
        }
    }
}

private struct TextSettingRow: View {
    let id: String
    let name: String
    let summary: String?
    let defaultValue: String
    let pluginId: String
    @ObservedObject var store: PluginSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name)
            TextField(name, text: Binding(
                get: { store.get(pluginId: pluginId, key: id) ?? defaultValue },
                set: { newValue in
                    store.set(pluginId: pluginId, key: id, value: newValue)
                }
            ))
            .textFieldStyle(RoundedBorderTextFieldStyle())

            if let summary = summary, !summary.isEmpty {
                Text(summary)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
        .onAppear {
            if store.get(pluginId: pluginId, key: id) == nil {
                store.set(pluginId: pluginId, key: id, value: defaultValue)
            }
        }
    }
}

private struct PickerSettingRow: View {
    let id: String
    let name: String
    let summary: String?
    let options: [String]
    let defaultValue: String
    let pluginId: String
    @ObservedObject var store: PluginSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(name, selection: Binding(
                get: { store.get(pluginId: pluginId, key: id) ?? defaultValue },
                set: { newValue in
                    store.set(pluginId: pluginId, key: id, value: newValue)
                }
            )) {
                ForEach(options, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            if let summary = summary, !summary.isEmpty {
                Text(summary)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
        .onAppear {
            if store.get(pluginId: pluginId, key: id) == nil {
                store.set(pluginId: pluginId, key: id, value: defaultValue)
            }
        }
    }
}

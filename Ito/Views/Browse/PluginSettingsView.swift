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

    // We bind directly to the plugin's defaults suite so it maps symmetrically to DefaultDefaultsModule.
    private let defaults: UserDefaults

    init(plugin: InstalledPlugin, schema: SettingsSchema) {
        self.plugin = plugin
        self.schema = schema
        let pluginId = plugin.url.deletingPathExtension().lastPathComponent
        self.defaults = UserDefaults(suiteName: "moe.ito.runners.\(pluginId)") ?? .standard
    }

    var body: some View {
        NavigationView {
            Form {
                ForEach(schema.settings, id: \.id) { setting in
                    SettingRowView(setting: setting, defaults: defaults)
                }
            }
            .navigationTitle("\(plugin.info.name) Settings")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(trailing: Button("Done") {
                dismiss()
            })
        }
    }
}

private struct SettingRowView: View {
    let setting: Setting
    let defaults: UserDefaults

    var body: some View {
        switch setting {
        case .toggle(let id, let name, let summary, let defaultValue):
            ToggleSettingRow(id: id, name: name, summary: summary, defaultValue: defaultValue, defaults: defaults)
        case .text(let id, let name, let summary, let defaultValue):
            TextSettingRow(id: id, name: name, summary: summary, defaultValue: defaultValue, defaults: defaults)
        case .picker(let id, let name, let summary, let options, let defaultValue):
            PickerSettingRow(id: id, name: name, summary: summary, options: options, defaultValue: defaultValue, defaults: defaults)
        }
    }
}

private struct ToggleSettingRow: View {
    let id: String
    let name: String
    let summary: String?
    let defaultValue: Bool
    let defaults: UserDefaults

    @State private var value: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(name, isOn: Binding(
                get: { self.value },
                set: {
                    self.value = $0
                    defaults.set($0 ? "true" : "false", forKey: id)
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
            if let strValues = defaults.string(forKey: id) {
                self.value = (strValues == "true")
            } else {
                self.value = defaultValue
                defaults.set(defaultValue ? "true" : "false", forKey: id)
            }
        }
    }
}

private struct TextSettingRow: View {
    let id: String
    let name: String
    let summary: String?
    let defaultValue: String
    let defaults: UserDefaults

    @State private var value: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name)
            TextField(name, text: Binding(
                get: { self.value },
                set: { newValue in
                    self.value = newValue
                    defaults.set(newValue, forKey: id)
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
            if let current = defaults.string(forKey: id) {
                self.value = current
            } else {
                self.value = defaultValue
                defaults.set(defaultValue, forKey: id)
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
    let defaults: UserDefaults

    @State private var value: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(name, selection: Binding(
                get: { self.value },
                set: { newValue in
                    self.value = newValue
                    defaults.set(newValue, forKey: id)
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
            if let current = defaults.string(forKey: id) {
                self.value = current
            } else {
                self.value = defaultValue
                defaults.set(defaultValue, forKey: id)
            }
        }
    }
}

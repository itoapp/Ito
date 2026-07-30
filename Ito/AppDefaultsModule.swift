import ito_runner

public final class AppDefaultsModule: DefaultsModule, @unchecked Sendable {
    private let pluginId: String
    private let store: PluginSettingsStore

    public init(pluginId: String, store: PluginSettingsStore) {
        self.pluginId = pluginId
        self.store = store
    }

    public func set(key: String, value: String) {
        store.set(pluginId: pluginId, key: key, value: value)
    }

    public func get(key: String) -> String? {
        store.get(pluginId: pluginId, key: key)
    }

    public func remove(key: String) {
        store.remove(pluginId: pluginId, key: key)
    }
}

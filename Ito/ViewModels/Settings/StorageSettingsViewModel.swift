import Combine

@MainActor
final class StorageSettingsViewModel: ObservableObject {
    @Published private(set) var diskCacheLimitGB: Double
    @Published private(set) var formattedCurrentUsage: String
    @Published private(set) var alert: SettingsAlert?

    let cacheLimitChoices = (1...50).map(Double.init)

    private let settingsStore: AppSettingsStore
    private let storageAccess: any SettingsStorageAccessing
    private var cancellables = Set<AnyCancellable>()

    init(
        settingsStore: AppSettingsStore,
        storageAccess: any SettingsStorageAccessing
    ) {
        self.settingsStore = settingsStore
        self.storageAccess = storageAccess
        diskCacheLimitGB = settingsStore.diskCacheLimitGB
        formattedCurrentUsage = storageAccess.formatBytes(storageAccess.currentCacheSizeBytes)

        settingsStore.$diskCacheLimitGB
            .sink { [weak self] limit in
                self?.diskCacheLimitGB = limit
            }
            .store(in: &cancellables)
    }

    func setDiskCacheLimitGB(_ value: Double) async {
        do {
            try await settingsStore.set(value, for: AppPreferenceCatalog.diskCacheLimitGB)
            diskCacheLimitGB = settingsStore.diskCacheLimitGB
            alert = nil
        } catch {
            diskCacheLimitGB = settingsStore.diskCacheLimitGB
            alert = .saveFailed
        }
    }

    func refreshCacheUsage() {
        storageAccess.refreshCacheSize()
        updateFormattedCurrentUsage()
    }

    func clearCache() {
        storageAccess.clearCache()
        updateFormattedCurrentUsage()
    }

    func dismissAlert() {
        alert = nil
    }

    private func updateFormattedCurrentUsage() {
        formattedCurrentUsage = storageAccess.formatBytes(storageAccess.currentCacheSizeBytes)
    }
}

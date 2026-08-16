import Combine

@MainActor
final class PrivacySettingsViewModel: ObservableObject {
    @Published private(set) var incognitoMode: Bool
    @Published private(set) var discordRPCEnabled: Bool
    @Published private(set) var discordRPCURL: String
    @Published private(set) var discordState: DiscordRPCState
    @Published private(set) var alert: SettingsAlert?

    var showsDiscordDetails: Bool {
        discordRPCEnabled
    }

    private let settingsStore: AppSettingsStore
    private let discordRPCManager: DiscordRPCManager
    private var cancellables = Set<AnyCancellable>()

    init(
        settingsStore: AppSettingsStore,
        discordRPCManager: DiscordRPCManager
    ) {
        self.settingsStore = settingsStore
        self.discordRPCManager = discordRPCManager
        incognitoMode = settingsStore.incognitoMode
        discordRPCEnabled = settingsStore.discordRPCEnabled
        discordRPCURL = settingsStore.discordRPCURL
        discordState = discordRPCManager.state

        settingsStore.$discordRPCEnabled
            .sink { [weak self] enabled in
                self?.discordRPCEnabled = enabled
            }
            .store(in: &cancellables)
        settingsStore.$incognitoMode
            .sink { [weak self] enabled in
                self?.incognitoMode = enabled
            }
            .store(in: &cancellables)
        settingsStore.$discordRPCURL
            .sink { [weak self] url in
                self?.discordRPCURL = url
            }
            .store(in: &cancellables)
        discordRPCManager.$state
            .sink { [weak self] state in
                self?.discordState = state
            }
            .store(in: &cancellables)
    }

    func setIncognitoMode(_ value: Bool) async {
        do {
            try await settingsStore.set(value, for: AppPreferenceCatalog.incognitoMode)
            incognitoMode = settingsStore.incognitoMode
            alert = nil
        } catch {
            incognitoMode = settingsStore.incognitoMode
            alert = .saveFailed
        }
    }

    func setDiscordRPCEnabled(_ value: Bool) async {
        do {
            try await settingsStore.set(value, for: AppPreferenceCatalog.discordRPCEnabled)
            discordRPCEnabled = settingsStore.discordRPCEnabled
            alert = nil
        } catch {
            discordRPCEnabled = settingsStore.discordRPCEnabled
            alert = .saveFailed
        }
    }

    func setDiscordRPCURL(_ value: String) async {
        do {
            try await settingsStore.set(value, for: AppPreferenceCatalog.discordRPCURL)
            discordRPCURL = settingsStore.discordRPCURL
            alert = nil
        } catch {
            discordRPCURL = settingsStore.discordRPCURL
            alert = .saveFailed
        }
    }

    func dismissAlert() {
        alert = nil
    }
}

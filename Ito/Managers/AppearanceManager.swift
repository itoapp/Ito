import SwiftUI
import Combine

extension AppThemePreference: Identifiable {
    public var id: String { rawValue }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

class AppearanceManager: ObservableObject {
    private let settingsStore: AppSettingsStore
    private var cancellable: AnyCancellable?

    var selectedTheme: AppThemePreference {
        settingsStore.appTheme
    }

    init(settingsStore: AppSettingsStore) {
        self.settingsStore = settingsStore
        cancellable = settingsStore.$appTheme
            .dropFirst()
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    func reload() {
        objectWillChange.send()
    }
}

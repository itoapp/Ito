import Foundation

@MainActor
final class TrackerCredentialLifecycle {
    private let bootstrapCredentials: () async -> Void

    init(manager: TrackerManager = .shared) {
        self.bootstrapCredentials = { await manager.bootstrapCredentials() }
    }

    init(bootstrapCredentials: @escaping () async -> Void) {
        self.bootstrapCredentials = bootstrapCredentials
    }

    func appDidLaunch() async {
        await bootstrapCredentials()
    }

    func appDidBecomeActive() async {
        await bootstrapCredentials()
    }
}

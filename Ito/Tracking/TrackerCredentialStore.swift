import Foundation
import Security

nonisolated protocol TrackerCredentialStoring: Sendable {
    func token(for providerID: String) async throws -> String?
    func setToken(_ token: String, for providerID: String) async throws
    func removeToken(for providerID: String) async throws
}

nonisolated enum TrackerCredentialOperation: String, Sendable {
    case read
    case update
    case add
    case delete
}

nonisolated enum TrackerCredentialStoreError: Error, Equatable, Sendable, LocalizedError {
    case protectedDataUnavailable(OSStatus)
    case accessDenied(OSStatus)
    case invalidData
    case configuration(OSStatus)
    case unexpected(operation: TrackerCredentialOperation, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .protectedDataUnavailable(let status):
            "Keychain protected data is unavailable (status \(status))."
        case .accessDenied(let status):
            "Keychain access was denied (status \(status))."
        case .invalidData:
            "Keychain credential data is invalid."
        case .configuration(let status):
            "Keychain configuration failed (status \(status))."
        case .unexpected(let operation, let status):
            "Keychain \(operation.rawValue) failed (status \(status))."
        }
    }
}

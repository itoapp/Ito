import Foundation
import Security

nonisolated enum KeychainStatusPolicy {
    static func error(
        for status: OSStatus,
        operation: TrackerCredentialOperation
    ) -> TrackerCredentialStoreError {
        switch status {
        case errSecInteractionNotAllowed, errSecNotAvailable:
            .protectedDataUnavailable(status)
        case errSecAuthFailed, errSecUserCanceled:
            .accessDenied(status)
        case errSecMissingEntitlement, errSecParam:
            .configuration(status)
        default:
            .unexpected(operation: operation, status: status)
        }
    }
}

nonisolated protocol KeychainSecurityClient: Sendable {
    func copyTokenData(service: String, account: String) -> (OSStatus, Data?)
    func updateTokenData(_ data: Data, service: String, account: String) -> OSStatus
    func addTokenData(_ data: Data, service: String, account: String) -> OSStatus
    func deleteTokenData(service: String, account: String) -> OSStatus
}

nonisolated struct SystemKeychainSecurityClient: KeychainSecurityClient {
    static func addQuery(data: Data, service: String, account: String) -> CFDictionary {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: data
        ] as CFDictionary
    }

    func copyTokenData(service: String, account: String) -> (OSStatus, Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ] as CFDictionary, &result)
        return (status, result as? Data)
    }

    func updateTokenData(_ data: Data, service: String, account: String) -> OSStatus {
        SecItemUpdate(
            identityQuery(service: service, account: account),
            [kSecValueData: data] as CFDictionary
        )
    }

    func addTokenData(_ data: Data, service: String, account: String) -> OSStatus {
        SecItemAdd(Self.addQuery(data: data, service: service, account: account), nil)
    }

    func deleteTokenData(service: String, account: String) -> OSStatus {
        SecItemDelete(identityQuery(service: service, account: account))
    }

    private func identityQuery(service: String, account: String) -> CFDictionary {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ] as CFDictionary
    }
}

actor KeychainTrackerCredentialStore: TrackerCredentialStoring {
    static let productionService = "moe.itoapp.ito.tracker.oauth-token"

    private let service: String
    private let client: any KeychainSecurityClient

    init(
        service: String = KeychainTrackerCredentialStore.productionService,
        client: any KeychainSecurityClient = SystemKeychainSecurityClient()
    ) {
        self.service = service
        self.client = client
    }

    func token(for providerID: String) throws -> String? {
        let (status, data) = client.copyTokenData(service: service, account: providerID)
        switch status {
        case errSecSuccess:
            guard
                let data,
                !data.isEmpty,
                let token = String(data: data, encoding: .utf8),
                !token.isEmpty
            else {
                throw TrackerCredentialStoreError.invalidData
            }
            return token
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainStatusPolicy.error(for: status, operation: .read)
        }
    }

    func setToken(_ token: String, for providerID: String) throws {
        guard !token.isEmpty else {
            throw TrackerCredentialStoreError.invalidData
        }

        let data = Data(token.utf8)
        let updateStatus = client.updateTokenData(data, service: service, account: providerID)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            try add(data, token: token, providerID: providerID)
        default:
            throw KeychainStatusPolicy.error(for: updateStatus, operation: .update)
        }
    }

    func removeToken(for providerID: String) throws {
        let status = client.deleteTokenData(service: service, account: providerID)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStatusPolicy.error(for: status, operation: .delete)
        }
    }

    private func add(_ data: Data, token: String, providerID: String) throws {
        let addStatus = client.addTokenData(data, service: service, account: providerID)
        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            try recoverFromDuplicateAdd(data, token: token, providerID: providerID)
        default:
            throw KeychainStatusPolicy.error(for: addStatus, operation: .add)
        }
    }

    private func recoverFromDuplicateAdd(_ data: Data, token: String, providerID: String) throws {
        if try self.token(for: providerID) == token {
            return
        }

        let status = client.updateTokenData(data, service: service, account: providerID)
        guard status == errSecSuccess else {
            throw KeychainStatusPolicy.error(for: status, operation: .update)
        }
    }
}

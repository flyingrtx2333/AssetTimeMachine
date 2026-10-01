import Foundation
import Security
import LocalAuthentication

protocol CloudTokenStore {
    func loadAccessToken() -> String?
    func loadRefreshToken() -> String?
    func save(accessToken: String, refreshToken: String?) throws
    func clear() throws
}

enum KeychainTokenStoreError: LocalizedError {
    case invalidTokenData
    case saveFailed(account: String, status: OSStatus)
    case deleteFailed(account: String, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidTokenData:
            return AppLocalization.string("无法保存登录凭证")
        case let .saveFailed(_, status):
            return AppLocalization.format("保存登录凭证失败（%d）", status)
        case let .deleteFailed(_, status):
            return AppLocalization.format("清理登录凭证失败（%d）", status)
        }
    }
}

final class KeychainTokenStore: CloudTokenStore {
    static let shared = KeychainTokenStore()

    struct Operations {
        var copy: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemCopyMatching
        var update: (CFDictionary, CFDictionary) -> OSStatus = SecItemUpdate
        var add: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemAdd
        var delete: (CFDictionary) -> OSStatus = SecItemDelete
    }

    private let service: String
    private let accessTokenAccount: String
    private let refreshTokenAccount: String
    private let operations: Operations
    private let migrationDefaults: UserDefaults
    private var loadedAccounts: Set<String> = []
    private var cachedValues: [String: String] = [:]

    init(
        service: String = "com.flyingrtx.AssetTimeMachine.cloud",
        accessTokenAccount: String = "accessToken",
        refreshTokenAccount: String = "refreshToken",
        operations: Operations = Operations(),
        migrationDefaults: UserDefaults = .standard
    ) {
        self.service = service
        self.accessTokenAccount = accessTokenAccount
        self.refreshTokenAccount = refreshTokenAccount
        self.operations = operations
        self.migrationDefaults = migrationDefaults
    }

    func loadAccessToken() -> String? {
        load(account: accessTokenAccount)
    }

    func loadRefreshToken() -> String? {
        load(account: refreshTokenAccount)
    }

    func save(accessToken: String, refreshToken: String?) throws {
        try save(value: accessToken, account: accessTokenAccount)
        if let refreshToken, !refreshToken.isEmpty {
            try save(value: refreshToken, account: refreshTokenAccount)
        } else {
            try delete(account: refreshTokenAccount)
        }
    }

    func clear() throws {
        try delete(account: accessTokenAccount)
        try delete(account: refreshTokenAccount)
    }

    private func load(account: String) -> String? {
        if loadedAccounts.contains(account) { return cachedValues[account] }
        loadedAccounts.insert(account)
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = operations.copy(query as CFDictionary, &result)
        #if os(macOS)
        // Preserve old credentials. Migrate only when the existing ACL allows a silent read.
        if status == errSecItemNotFound, !migrationDefaults.bool(forKey: retirementKey(account)) {
            query[kSecUseDataProtectionKeychain as String] = false
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
            if operations.copy(query as CFDictionary, &result) == errSecSuccess,
               let data = result as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty {
                try? save(value: value, account: account)
                loadedAccounts.insert(account)
                cachedValues[account] = value
                return value
            }
        }
        #endif
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            return nil
        }
        cachedValues[account] = value
        return value
    }

    private func save(value: String, account: String) throws {
        guard let data = value.data(using: .utf8) else { throw KeychainTokenStoreError.invalidTokenData }
        var query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = operations.update(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            migrationDefaults.set(true, forKey: retirementKey(account))
            loadedAccounts.remove(account)
            cachedValues.removeValue(forKey: account)
            return
        case errSecItemNotFound:
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = operations.add(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainTokenStoreError.saveFailed(account: account, status: addStatus)
            }
            migrationDefaults.set(true, forKey: retirementKey(account))
            loadedAccounts.remove(account)
            cachedValues.removeValue(forKey: account)
        default:
            throw KeychainTokenStoreError.saveFailed(account: account, status: updateStatus)
        }
    }

    private func delete(account: String) throws {
        let status = operations.delete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainTokenStoreError.deleteFailed(account: account, status: status)
        }
        migrationDefaults.set(true, forKey: retirementKey(account))
        loadedAccounts.insert(account)
        cachedValues.removeValue(forKey: account)
    }

    private func retirementKey(_ account: String) -> String {
        service + ".legacyRetired." + account
    }

    private func baseQuery(account: String) -> [String: Any] {
        let authentication = LAContext()
        authentication.interactionNotAllowed = true
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
            kSecUseAuthenticationContext as String: authentication
        ]
    }
}

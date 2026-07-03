import Foundation
import Security

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
    private let service: String
    private let accessTokenAccount: String
    private let refreshTokenAccount: String

    init(
        service: String = "com.flyingrtx.AssetTimeMachine.cloud",
        accessTokenAccount: String = "accessToken",
        refreshTokenAccount: String = "refreshToken"
    ) {
        self.service = service
        self.accessTokenAccount = accessTokenAccount
        self.refreshTokenAccount = refreshTokenAccount
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
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private func save(value: String, account: String) throws {
        guard let data = value.data(using: .utf8) else { throw KeychainTokenStoreError.invalidTokenData }
        var query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainTokenStoreError.saveFailed(account: account, status: addStatus)
            }
        default:
            throw KeychainTokenStoreError.saveFailed(account: account, status: updateStatus)
        }
    }

    private func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainTokenStoreError.deleteFailed(account: account, status: status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

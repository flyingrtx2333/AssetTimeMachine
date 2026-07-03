import Foundation
import Security

protocol CloudTokenStore {
    func loadAccessToken() -> String?
    func loadRefreshToken() -> String?
    func save(accessToken: String, refreshToken: String?)
    func clear()
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

    func save(accessToken: String, refreshToken: String?) {
        save(value: accessToken, account: accessTokenAccount)
        if let refreshToken, !refreshToken.isEmpty {
            save(value: refreshToken, account: refreshTokenAccount)
        } else {
            delete(account: refreshTokenAccount)
        }
    }

    func clear() {
        delete(account: accessTokenAccount)
        delete(account: refreshTokenAccount)
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

    private func save(value: String, account: String) {
        guard let data = value.data(using: .utf8) else { return }
        var query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    private func delete(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

import Foundation
import Security
import LocalAuthentication

// The adapter's text dependency is isolated; all SecItem operations below are simulated.
enum AppLocalization {
    static func string(_ text: String) -> String { text }
    static func format(_ text: String, _ code: Int32) -> String { String(format: text, code) }
}

private final class SecurityFixture {
    var values: [String: Data] = [:]
    var legacy: [String: Data] = [:]
    var reads = 0
    var legacyReads = 0
    var denied = false
    var deniedWrite = false
    var deletes = 0
    func check(_ query: CFDictionary) -> [String: Any] {
        let q = query as! [String: Any]
        precondition((q[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true)
        return q
    }
    var operations: KeychainTokenStore.Operations {
        KeychainTokenStore.Operations(copy: { query, result in
            let q = self.check(query)
            let account = q[kSecAttrAccount as String] as! String
            self.reads += 1
            let protection = q[kSecUseDataProtectionKeychain as String] as! Bool
            if !protection {
                self.legacyReads += 1
                precondition((q[kSecUseAuthenticationUI as String] as? String) == (kSecUseAuthenticationUIFail as String))
            }
            if self.denied { return errSecInteractionNotAllowed }
            guard let data = (protection ? self.values : self.legacy)[account] else { return errSecItemNotFound }
            result?.pointee = data as CFData
            return errSecSuccess
        }, update: { query, attributes in
            let q = self.check(query)
            precondition(q[kSecUseDataProtectionKeychain as String] as? Bool == true)
            if self.deniedWrite { return errSecAuthFailed }
            let account = q[kSecAttrAccount as String] as! String
            guard self.values[account] != nil else { return errSecItemNotFound }
            self.values[account] = (attributes as! [String: Any])[kSecValueData as String] as? Data
            return errSecSuccess
        }, add: { query, _ in
            let q = self.check(query)
            precondition(q[kSecUseDataProtectionKeychain as String] as? Bool == true)
            if self.deniedWrite { return errSecAuthFailed }
            self.values[q[kSecAttrAccount as String] as! String] = q[kSecValueData as String] as? Data
            return errSecSuccess
        }, delete: { query in
            let q = self.check(query)
            precondition(q[kSecUseDataProtectionKeychain as String] as? Bool == true)
            self.deletes += 1
            self.values.removeValue(forKey: q[kSecAttrAccount as String] as! String)
            return errSecSuccess
        })
    }
}

@main
struct KeychainTokenStoreTests {
    static func main() throws {
        var checks = 0
        func verify(_ value: Bool, _ name: String) {
            precondition(value, name)
            checks += 1
            print("PASS " + name)
        }
        func fixture() -> (SecurityFixture, UserDefaults, String) {
            let name = "KeychainAdapterTests." + UUID().uuidString
            return (SecurityFixture(), UserDefaults(suiteName: name)!, name)
        }
        do {
            let (os, defaults, name) = fixture()
            defer { defaults.removePersistentDomain(forName: name) }
            os.values = ["accessToken": Data("synthetic-access".utf8), "refreshToken": Data("synthetic-refresh".utf8)]
            let store = KeychainTokenStore(operations: os.operations, migrationDefaults: defaults)
            var cachedValuesMatch = true
            for _ in 0..<20 {
                cachedValuesMatch = cachedValuesMatch && store.loadAccessToken() == "synthetic-access" && store.loadRefreshToken() == "synthetic-refresh"
            }
            verify(cachedValuesMatch, "cached credential values")
            verify(os.reads == 2, "one read per credential across repeated startup reads")
            try store.save(accessToken: "synthetic-new", refreshToken: nil)
            verify(store.loadAccessToken() == "synthetic-new" && store.loadRefreshToken() == nil, "save invalidates cache and removes absent refresh token")
            verify(os.reads == 3, "new saved access token re-read once for verification")
            try store.clear()
            verify(store.loadAccessToken() == nil && store.loadRefreshToken() == nil, "logout clears memory cache")
            let restarted = KeychainTokenStore(operations: os.operations, migrationDefaults: defaults)
            verify(restarted.loadAccessToken() == nil && restarted.loadRefreshToken() == nil && os.legacyReads == 0, "logout survives restart without legacy credential resurrection")
        }
        do {
            let (os, defaults, name) = fixture()
            defer { defaults.removePersistentDomain(forName: name) }
            os.denied = true
            let store = KeychainTokenStore(operations: os.operations, migrationDefaults: defaults)
            for _ in 0..<20 { _ = store.loadAccessToken() }
            verify(os.reads == 1 && os.legacyReads == 0, "denied read is cached without retry or legacy prompt")
            os.denied = false
            try store.save(accessToken: "synthetic-relogin", refreshToken: nil)
            verify(store.loadAccessToken() == "synthetic-relogin", "explicit login recovers after denied read")
        }
        do {
            let (os, defaults, name) = fixture()
            defer { defaults.removePersistentDomain(forName: name) }
            os.legacy = ["accessToken": Data("synthetic-legacy".utf8)]
            let store = KeychainTokenStore(operations: os.operations, migrationDefaults: defaults)
            verify(store.loadAccessToken() == "synthetic-legacy" && os.values["accessToken"] != nil, "silent legacy read migrates to data protection")
            verify(os.legacy["accessToken"] != nil && os.deletes == 0, "migration preserves old credentials")
            try store.clear()
            let restarted = KeychainTokenStore(operations: os.operations, migrationDefaults: defaults)
            verify(restarted.loadAccessToken() == nil && os.legacyReads == 1, "preserved legacy credential never restores a signed-out session")
        }
        do {
            let (os, defaults, name) = fixture()
            defer { defaults.removePersistentDomain(forName: name) }
            os.values["accessToken"] = Data("synthetic-original".utf8)
            let store = KeychainTokenStore(operations: os.operations, migrationDefaults: defaults)
            _ = store.loadAccessToken()
            os.deniedWrite = true
            do {
                try store.save(accessToken: "synthetic-unwritten", refreshToken: nil)
                preconditionFailure("denied write must throw")
            } catch {}
            verify(store.loadAccessToken() == "synthetic-original", "failed save preserves previous cached credential")
        }
        print("PASSED \(checks) checks; no real credentials or system keychain accessed")
    }
}

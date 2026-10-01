import Foundation

enum AppLocalization {
    static func string(_ text: String) -> String { text }
    static func format(_ text: String, _ code: Int32) -> String { String(format: text, code) }
}

@main
struct KeychainTokenStoreSystemProbe {
    static func main() throws {
        let namespace = "com.flyingrtx.AssetTimeMachine.keychain-test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: namespace)!
        defer { defaults.removePersistentDomain(forName: namespace) }
        let store = KeychainTokenStore(service: namespace, migrationDefaults: defaults)
        defer { try? store.clear() }
        let access = UUID().uuidString, refresh = UUID().uuidString
        try store.save(accessToken: access, refreshToken: refresh)
        guard store.loadAccessToken() == access, store.loadRefreshToken() == refresh else {
            throw NSError(domain: "KeychainSystemProbe", code: 1)
        }
        let restarted = KeychainTokenStore(service: namespace, migrationDefaults: defaults)
        guard restarted.loadAccessToken() == access, restarted.loadRefreshToken() == refresh else {
            throw NSError(domain: "KeychainSystemProbe", code: 2)
        }
        try restarted.clear()
        let signedOut = KeychainTokenStore(service: namespace, migrationDefaults: defaults)
        guard signedOut.loadAccessToken() == nil, signedOut.loadRefreshToken() == nil else {
            throw NSError(domain: "KeychainSystemProbe", code: 3)
        }
        print("PASS signed macOS Data Protection write/read/restart/clear; unique synthetic service only")
    }
}

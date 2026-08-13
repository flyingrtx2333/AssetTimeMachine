import Combine
import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            return AppLocalization.string("跟随系统")
        case .english:
            return "English"
        case .simplifiedChinese:
            return AppLocalization.string("简体中文")
        case .traditionalChinese:
            return AppLocalization.string("繁體中文")
        }
    }

    var locale: Locale {
        switch self {
        case .system:
            return .autoupdatingCurrent
        case .english, .simplifiedChinese, .traditionalChinese:
            return Locale(identifier: rawValue)
        }
    }
}

@MainActor
final class AppLanguageStore: ObservableObject {
    @Published private(set) var language: AppLanguage

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let rawValue = defaults.string(forKey: AppLocalization.languageDefaultsKey)
            ?? AppLanguage.system.rawValue
        let language = AppLanguage(rawValue: rawValue) ?? .system
        self.language = language
        AppLocalization.activate(language)
    }

    func select(_ language: AppLanguage) {
        guard language != self.language else { return }

        // Publish only after every direct localization lookup has switched to
        // the same language. This keeps one SwiftUI update from observing a
        // mixture of the old AppStorage value and the new bundle.
        AppLocalization.activate(language)
        defaults.set(language.rawValue, forKey: AppLocalization.languageDefaultsKey)
        self.language = language
    }
}

enum AppLocalization {
    static let languageDefaultsKey = "app.language"
    private static let cachePrefix = "AssetTimeMachine.Localization."
    private static let languageState = LocalizationLanguageState()

    static var currentLanguage: AppLanguage {
        languageState.currentLanguage
    }

    static var currentLocale: Locale {
        currentLanguage.locale
    }

    static func string(_ key: String) -> String {
        let language = currentLanguage
        return localizedString(key, language: language)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        let language = currentLanguage
        let localizedFormat = localizedString(key, language: language)
        let resolvedFormat = formatSignature(localizedFormat) == formatSignature(key)
            ? localizedFormat
            : key
        return String(format: resolvedFormat, locale: language.locale, arguments: arguments)
    }

    static func activate(_ language: AppLanguage) {
        languageState.activate(language)
    }

    private static func localizedString(_ key: String, language: AppLanguage) -> String {
        let token = cacheToken(for: language)
        let cacheKey = "\(cachePrefix)string.\(token).\(key)"

        if let cached = Thread.current.threadDictionary[cacheKey] as? String {
            return cached
        }

        let value = localizedBundle(for: language, token: token).localizedString(forKey: key, value: key, table: nil)
        Thread.current.threadDictionary[cacheKey] = value
        return value
    }

    private static func formatSignature(_ value: String) -> [Character] {
        let conversions = Set("@diuoxXfFeEgGaAcCsSp")
        let integerConversions = Set("diuoxXcC")
        let floatingConversions = Set("fFeEgGaA")
        let modifiers = Set("0123456789$-+#0 '.*hlqLztjI")
        var signature: [Character] = []
        var index = value.startIndex

        while index < value.endIndex {
            guard value[index] == "%" else {
                index = value.index(after: index)
                continue
            }

            index = value.index(after: index)
            guard index < value.endIndex else { break }
            if value[index] == "%" {
                index = value.index(after: index)
                continue
            }

            while index < value.endIndex, modifiers.contains(value[index]) {
                index = value.index(after: index)
            }
            guard index < value.endIndex, conversions.contains(value[index]) else { continue }

            let conversion = value[index]
            if conversion == "@" {
                signature.append("@")
            } else if integerConversions.contains(conversion) {
                signature.append("d")
            } else if floatingConversions.contains(conversion) {
                signature.append("f")
            } else {
                signature.append(conversion)
            }
            index = value.index(after: index)
        }

        return signature.sorted()
    }

    private static func localizedBundle(for language: AppLanguage, token: String) -> Bundle {
        let cacheKey = "\(cachePrefix)bundle.\(token)"
        if let cached = Thread.current.threadDictionary[cacheKey] as? Bundle {
            return cached
        }

        for candidate in bundleCandidates(for: language) {
            if let path = Bundle.main.path(forResource: candidate, ofType: "lproj"),
               let bundle = Bundle(path: path) {
                Thread.current.threadDictionary[cacheKey] = bundle
                return bundle
            }
        }
        Thread.current.threadDictionary[cacheKey] = Bundle.main
        return .main
    }

    private static func cacheToken(for language: AppLanguage) -> String {
        switch language {
        case .system:
            return "system.\(Locale.preferredLanguages.first ?? Locale.autoupdatingCurrent.identifier)"
        case .english, .simplifiedChinese, .traditionalChinese:
            return language.rawValue
        }
    }

    private static func bundleCandidates(for language: AppLanguage) -> [String] {
        let identifier: String
        switch language {
        case .system:
            identifier = Locale.preferredLanguages.first ?? Locale.autoupdatingCurrent.identifier
        case .english, .simplifiedChinese, .traditionalChinese:
            identifier = language.rawValue
        }

        let normalized = identifier.replacingOccurrences(of: "_", with: "-")
        var candidates: [String] = [normalized]

        if normalized.hasPrefix("zh-Hans") {
            candidates.append("zh-Hans")
        }
        if normalized.hasPrefix("zh-Hant") {
            candidates.append("zh-Hant")
        }
        if let languageCode = normalized.split(separator: "-").first {
            candidates.append(String(languageCode))
        }

        var deduped: [String] = []
        for candidate in candidates where !candidate.isEmpty {
            if !deduped.contains(candidate) {
                deduped.append(candidate)
            }
        }
        return deduped
    }

    private final class LocalizationLanguageState: @unchecked Sendable {
        private let lock = NSLock()
        private var language: AppLanguage

        init() {
            let rawValue = UserDefaults.standard.string(forKey: languageDefaultsKey)
                ?? AppLanguage.system.rawValue
            language = AppLanguage(rawValue: rawValue) ?? .system
        }

        var currentLanguage: AppLanguage {
            lock.lock()
            defer { lock.unlock() }
            return language
        }

        func activate(_ language: AppLanguage) {
            lock.lock()
            self.language = language
            lock.unlock()
        }
    }
}

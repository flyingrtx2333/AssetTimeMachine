import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
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

enum AppLocalization {
    private static let languageKey = "app.language"

    static var currentLanguage: AppLanguage {
        let rawValue = UserDefaults.standard.string(forKey: languageKey) ?? AppLanguage.system.rawValue
        return AppLanguage(rawValue: rawValue) ?? .system
    }

    static var currentLocale: Locale {
        currentLanguage.locale
    }

    static func string(_ key: String) -> String {
        localizedBundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: currentLocale, arguments: arguments)
    }

    private static var localizedBundle: Bundle {
        for candidate in bundleCandidates(for: currentLanguage) {
            if let path = Bundle.main.path(forResource: candidate, ofType: "lproj"),
               let bundle = Bundle(path: path) {
                return bundle
            }
        }
        return .main
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
}

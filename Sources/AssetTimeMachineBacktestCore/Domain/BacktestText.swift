import Foundation

/// Optional presentation input supplied by an adapter. Calculation rules never depend on it.
public enum BacktestText {
    public struct Context: Sendable {
        public let translations: [String: String]
        public let localeIdentifier: String?
        public init(translations: [String: String] = [:], localeIdentifier: String? = nil) {
            self.translations = translations
            self.localeIdentifier = localeIdentifier
        }
    }
    @TaskLocal public static var context = Context()
    public static func string(_ key: String) -> String { context.translations[key] ?? key }
    public static func format(_ key: String, _ arguments: CVarArg...) -> String {
        let format = string(key)
        if let identifier = context.localeIdentifier {
            return String(format: format, locale: Locale(identifier: identifier), arguments: arguments)
        }
        return String(format: format, arguments: arguments)
    }
}

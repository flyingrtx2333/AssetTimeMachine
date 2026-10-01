import Foundation

/// Deterministic local UI evidence must not update widgets, cloud data or market prices.
enum AppPreviewSession {
    static var didFinishStartup = false
    static var isActive: Bool {
        #if os(macOS)
        ProcessInfo.processInfo.arguments.contains("-macPerfStorePath")
        #elseif DEBUG && targetEnvironment(macCatalyst)
        ProcessInfo.processInfo.arguments.contains("-macPreview")
        #else
        false
        #endif
    }

    static var skipsAccountEntry: Bool {
        isActive && ProcessInfo.processInfo.arguments.contains("-macPerfSkipAccountEntry")
    }
}

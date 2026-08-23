import Foundation

nonisolated enum VIXPanic001Logic {
    static let panicThreshold = 30.0
    static let maxStaleCalendarDays = 7

    static func owner(
        points: [VRPProxyV1Logic.Point],
        signalDate: String
    ) -> String? {
        guard let vix = VRPProxyV1Logic.latestUsableValue(
            points: points,
            signalDate: signalDate,
            maxStaleDays: maxStaleCalendarDays
        ) else { return nil }
        return vix > panicThreshold ? "gold_cny" : "nasdaq"
    }
}

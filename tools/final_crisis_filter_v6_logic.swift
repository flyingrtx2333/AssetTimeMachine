import Foundation

nonisolated enum FinalCrisisFilterV6Logic {
    static func vixTermRiskOn(
        points: [OrthogonalEventFactorV3Logic.Point],
        signalDate: String
    ) -> Bool? {
        guard let index = OrthogonalEventFactorV3Logic.latestUsableIndex(
            points: points,
            signalDate: signalDate
        ) else { return nil }
        let value = points[index].value
        guard value.isFinite, value > 0 else { return nil }
        return value <= 1.0
    }

    static func falling20RiskOn(
        points: [OrthogonalEventFactorV3Logic.Point],
        signalDate: String
    ) -> Bool? {
        guard let index = OrthogonalEventFactorV3Logic.latestUsableIndex(
            points: points,
            signalDate: signalDate
        ), index >= 20 else { return nil }
        let current = points[index].value
        let prior = points[index - 20].value
        guard current.isFinite, prior.isFinite, current > 0, prior > 0 else { return nil }
        return current <= prior
    }

    static func rising20RiskOn(
        points: [OrthogonalEventFactorV3Logic.Point],
        signalDate: String
    ) -> Bool? {
        guard let index = OrthogonalEventFactorV3Logic.latestUsableIndex(
            points: points,
            signalDate: signalDate
        ), index >= 20 else { return nil }
        let current = points[index].value
        let prior = points[index - 20].value
        guard current.isFinite, prior.isFinite, current > 0, prior > 0 else { return nil }
        return current >= prior
    }
}

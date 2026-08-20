import Foundation

@main
struct OrthogonalEventFactorV3LogicTest {
    static func main() {
        func day(_ offset: Int) -> String {
            let base = Date(timeIntervalSince1970: 1_700_000_000)
            let date = Calendar(identifier: .gregorian).date(byAdding: .day, value: offset, to: base)!
            return OrthogonalEventFactorV3Logic.isoDay(date)
        }

        let leftRising = (0...24).map {
            OrthogonalEventFactorV3Logic.Point(date: day($0), value: 100.0 + Double($0) * 2.0)
        }
        let rightSlow = (0...24).map {
            OrthogonalEventFactorV3Logic.Point(date: day($0), value: 100.0 + Double($0) * 0.5)
        }
        precondition(
            OrthogonalEventFactorV3Logic.ratioRiskOn(
                numerator: leftRising,
                denominator: rightSlow,
                signalDate: day(24)
            ) == true
        )
        precondition(
            OrthogonalEventFactorV3Logic.ratioRiskOn(
                numerator: rightSlow,
                denominator: leftRising,
                signalDate: day(24)
            ) == false
        )

        let stale = [OrthogonalEventFactorV3Logic.Point(date: day(0), value: 1.0)]
        precondition(OrthogonalEventFactorV3Logic.risingRiskOn(points: stale, signalDate: day(7), lookbackObservations: 0) == nil)
        precondition(OrthogonalEventFactorV3Logic.latestUsableIndex(points: stale, signalDate: day(7)) == 0)
        precondition(OrthogonalEventFactorV3Logic.latestUsableIndex(points: stale, signalDate: day(8)) == nil)

        let prior = [
            "gold_cny": 0.40,
            "nasdaq": 0.30,
            "sp500": 0.10,
        ]
        let current = [
            "gold_cny": 0.20,
            "nasdaq": 0.30,
            "sp500": 0.10,
        ]
        precondition(OrthogonalEventFactorV3Logic.isDeRiskEvent(priorBase: prior, currentBase: current))
        let retained = OrthogonalEventFactorV3Logic.retainedTarget(
            priorBase: prior,
            currentBase: current,
            retain: true
        )
        precondition(abs((retained["gold_cny"] ?? 0) - 0.30) < 1e-9)
        precondition(abs((retained["nasdaq"] ?? 0) - 0.30) < 1e-9)
        precondition(abs(retained.values.reduce(0, +) - 0.70) < 1e-9)

        let noRetention = OrthogonalEventFactorV3Logic.retainedTarget(
            priorBase: prior,
            currentBase: current,
            retain: false
        )
        precondition(abs((noRetention["gold_cny"] ?? 0) - 0.20) < 1e-9)
        precondition(abs(noRetention.values.reduce(0, +) - 0.60) < 1e-9)

        let priorHigh = ["gold_cny": 0.50, "nasdaq": 0.50]
        let currentHigh = ["gold_cny": 0.40, "nasdaq": 0.55]
        let capped = OrthogonalEventFactorV3Logic.retainedTarget(
            priorBase: priorHigh,
            currentBase: currentHigh,
            retain: true
        )
        precondition(capped.values.reduce(0, +) <= 1.000000001)
        precondition((capped["gold_cny"] ?? 0) >= 0.40)
        precondition((capped["nasdaq"] ?? 0) == 0.55)
        precondition((capped["csi300"] ?? 0) == 0)

        print("ORTHOGONAL_EVENT_FACTOR_V3_LOGIC_TEST_OK")
    }
}

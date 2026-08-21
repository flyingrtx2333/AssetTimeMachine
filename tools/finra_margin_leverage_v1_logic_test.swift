import Foundation

@main
struct FINRAMarginLeverageV1LogicTest {
    static func main() {
        let points = [
            FINRAMarginLeverageV1Logic.Point(referenceMonth: "2026-01", availableDate: "2026-03-01", deltaLeverageRatio: -0.10),
            FINRAMarginLeverageV1Logic.Point(referenceMonth: "2026-02", availableDate: "2026-04-01", deltaLeverageRatio: 0.10),
        ]
        precondition(FINRAMarginLeverageV1Logic.latestRiskOn(points: points, signalDate: "2026-03-31") == false)
        precondition(FINRAMarginLeverageV1Logic.latestRiskOn(points: points, signalDate: "2026-04-01") == true)
        precondition(FINRAMarginLeverageV1Logic.latestRiskOn(points: points, signalDate: "2026-05-07", maxStaleDays: 35) == nil)

        let prior = [
            "gold_cny": 0.20,
            "nasdaq": 0.30,
            "sp500": 0.20,
            "csi300": 0.10,
        ]
        let current = [
            "gold_cny": 0.20,
            "nasdaq": 0.20,
            "sp500": 0.10,
            "csi300": 0.15,
        ]
        precondition(FINRAMarginLeverageV1Logic.isUSDeRiskEvent(priorBase: prior, currentBase: current))
        let retained = FINRAMarginLeverageV1Logic.retainedUSTarget(
            priorBase: prior,
            currentBase: current,
            retain: true,
            retentionFraction: 0.5
        )
        precondition(abs((retained["nasdaq"] ?? 0) - 0.25) < 1e-12)
        precondition(abs((retained["sp500"] ?? 0) - 0.15) < 1e-12)
        precondition(abs((retained["gold_cny"] ?? 0) - 0.20) < 1e-12)
        precondition(abs((retained["csi300"] ?? 0) - 0.15) < 1e-12)
        precondition(retained.values.reduce(0, +) <= 1.000000001)
        precondition(retained.values.allSatisfy { $0 >= 0 })

        let unchanged = FINRAMarginLeverageV1Logic.retainedUSTarget(
            priorBase: prior,
            currentBase: current,
            retain: false,
            retentionFraction: 0.5
        )
        precondition(unchanged == current)
        print("FINRA_MARGIN_LEVERAGE_V1_LOGIC_TEST_OK")
    }
}

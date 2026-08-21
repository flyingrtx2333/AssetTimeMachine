import Foundation

@main
struct SECInsiderBuyBreadthV1LogicTest {
    static func main() {
        let points = [
            SECInsiderBuyBreadthV1Logic.Point(weekStart: "2026-06-08", availableDate: "2026-06-16", deltaBuyIssuerCount: -5),
            SECInsiderBuyBreadthV1Logic.Point(weekStart: "2026-06-15", availableDate: "2026-06-23", deltaBuyIssuerCount: 7),
        ]
        precondition(SECInsiderBuyBreadthV1Logic.latestRiskOn(points: points, signalDate: "2026-06-22") == false)
        precondition(SECInsiderBuyBreadthV1Logic.latestRiskOn(points: points, signalDate: "2026-06-23") == true)
        precondition(SECInsiderBuyBreadthV1Logic.latestRiskOn(points: points, signalDate: "2026-07-04", maxStaleDays: 10) == nil)

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
        precondition(SECInsiderBuyBreadthV1Logic.isUSDeRiskEvent(priorBase: prior, currentBase: current))
        let retained = SECInsiderBuyBreadthV1Logic.retainedUSTarget(
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

        let unchanged = SECInsiderBuyBreadthV1Logic.retainedUSTarget(
            priorBase: prior,
            currentBase: current,
            retain: false,
            retentionFraction: 0.5
        )
        precondition(unchanged == current)
        print("SEC_INSIDER_BUY_BREADTH_V1_LOGIC_TEST_OK")
    }
}

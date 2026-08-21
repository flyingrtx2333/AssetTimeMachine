import Foundation

@main
struct BrokerDealerLeverageV1LogicTest {
    static func main() {
        let points = [
            BrokerDealerLeverageV1Logic.Point(
                quarter: "2025Q3",
                availableDate: "2026-01-10",
                annualLogLeverageGrowth: -0.02
            ),
            BrokerDealerLeverageV1Logic.Point(
                quarter: "2025Q4",
                availableDate: "2026-03-20",
                annualLogLeverageGrowth: 0.03
            ),
        ]
        precondition(BrokerDealerLeverageV1Logic.latestFavorable(points: points, signalDate: "2026-03-19") == true)
        precondition(BrokerDealerLeverageV1Logic.latestFavorable(points: points, signalDate: "2026-03-20") == false)
        precondition(BrokerDealerLeverageV1Logic.latestFavorable(points: points, signalDate: "2026-08-18", maxStaleDays: 150) == nil)

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
        precondition(BrokerDealerLeverageV1Logic.isUSDeRiskEvent(priorBase: prior, currentBase: current))
        let retained = BrokerDealerLeverageV1Logic.retainedUSTarget(
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

        let unchanged = BrokerDealerLeverageV1Logic.retainedUSTarget(
            priorBase: prior,
            currentBase: current,
            retain: false,
            retentionFraction: 0.5
        )
        precondition(unchanged == current)
        print("BROKER_DEALER_LEVERAGE_V1_LOGIC_TEST_OK")
    }
}

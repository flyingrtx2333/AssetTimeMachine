import Foundation

@main
struct TICForeignEquityFlowV1LogicTest {
    static func main() {
        let points = [
            TICForeignEquityFlowV1Logic.Point(
                reportMonth: "2023-01",
                availableDate: "2023-03-16",
                netForeignPurchasesMillions: -27_521,
                regime: "FORM_S_NET_FOREIGN_PURCHASES"
            ),
            TICForeignEquityFlowV1Logic.Point(
                reportMonth: "2023-02",
                availableDate: "2023-04-18",
                netForeignPurchasesMillions: -13_217,
                regime: "FORM_SLT_NET_US_SALES"
            ),
            TICForeignEquityFlowV1Logic.Point(
                reportMonth: "2023-03",
                availableDate: "2023-05-16",
                netForeignPurchasesMillions: 36_088,
                regime: "FORM_SLT_NET_US_SALES"
            ),
        ]
        precondition(TICForeignEquityFlowV1Logic.latestRiskOn(points: points, signalDate: "2023-04-17") == true)
        precondition(TICForeignEquityFlowV1Logic.latestRiskOn(points: points, signalDate: "2023-04-18") == true)
        precondition(TICForeignEquityFlowV1Logic.latestPoint(points: points, signalDate: "2023-04-18")?.reportMonth == "2023-02")
        precondition(TICForeignEquityFlowV1Logic.latestRiskOn(points: points, signalDate: "2023-05-16") == false)
        precondition(TICForeignEquityFlowV1Logic.latestRiskOn(points: points, signalDate: "2023-07-01", maxStaleDays: 45) == nil)

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
        precondition(TICForeignEquityFlowV1Logic.isUSDeRiskEvent(priorBase: prior, currentBase: current))
        let retained = TICForeignEquityFlowV1Logic.retainedUSTarget(
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
        print("TIC_FOREIGN_EQUITY_FLOW_V1_LOGIC_TEST_OK")
    }
}

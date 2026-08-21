import Foundation

@main
struct NetPayoutYieldV1LogicTest {
    static func main() {
        let points = [
            NetPayoutYieldV1Logic.Point(quarter: "2025Q1", availableDate: "2025-06-13", netPayoutYield: 0.02),
            NetPayoutYieldV1Logic.Point(quarter: "2025Q2", availableDate: "2025-09-12", netPayoutYield: 0.04),
            NetPayoutYieldV1Logic.Point(quarter: "2025Q3", availableDate: "2026-01-10", netPayoutYield: 0.03),
            NetPayoutYieldV1Logic.Point(quarter: "2025Q4", availableDate: "2026-03-20", netPayoutYield: 0.01),
        ]
        precondition(NetPayoutYieldV1Logic.latestRiskOn(points: points, signalDate: "2025-09-11") == nil)
        precondition(NetPayoutYieldV1Logic.latestRiskOn(points: points, signalDate: "2025-09-12") == true)
        precondition(abs((NetPayoutYieldV1Logic.priorMedian(points: points, signalDate: "2026-01-10") ?? 0) - 0.03) < 1e-12)
        precondition(NetPayoutYieldV1Logic.latestRiskOn(points: points, signalDate: "2026-01-10") == true)
        precondition(NetPayoutYieldV1Logic.latestRiskOn(points: points, signalDate: "2026-03-20") == false)
        precondition(NetPayoutYieldV1Logic.latestPoint(points: points, signalDate: "2026-03-20")?.quarter == "2025Q4")

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
        precondition(NetPayoutYieldV1Logic.isUSDeRiskEvent(priorBase: prior, currentBase: current))
        let retained = NetPayoutYieldV1Logic.retainedUSTarget(
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

        print("NET_PAYOUT_YIELD_V1_LOGIC_TEST_OK")
    }
}

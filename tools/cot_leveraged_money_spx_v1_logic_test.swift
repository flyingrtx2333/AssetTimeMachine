import Foundation

@main
struct COTLeveragedMoneySPXV1LogicTest {
    static func main() {
        let points = [
            COTLeveragedMoneySPXV1Logic.Point(reportDate: "2026-01-06", availableDate: "2026-01-13", deltaNetLongShare: -0.01),
            COTLeveragedMoneySPXV1Logic.Point(reportDate: "2026-01-13", availableDate: "2026-01-20", deltaNetLongShare: 0.02),
        ]
        precondition(COTLeveragedMoneySPXV1Logic.latestRiskOn(points: points, signalDate: "2026-01-19") == false)
        precondition(COTLeveragedMoneySPXV1Logic.latestRiskOn(points: points, signalDate: "2026-01-20") == true)
        precondition(COTLeveragedMoneySPXV1Logic.latestRiskOn(points: points, signalDate: "2026-02-04", maxStaleDays: 14) == nil)

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
        precondition(COTLeveragedMoneySPXV1Logic.isUSDeRiskEvent(priorBase: prior, currentBase: current))
        let retained = COTLeveragedMoneySPXV1Logic.retainedUSTarget(
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

        let noRetain = COTLeveragedMoneySPXV1Logic.retainedUSTarget(
            priorBase: prior,
            currentBase: current,
            retain: false,
            retentionFraction: 0.5
        )
        precondition(noRetain == current)

        print("COT_LEVERAGED_MONEY_SPX_V1_LOGIC_TEST_OK")
    }
}

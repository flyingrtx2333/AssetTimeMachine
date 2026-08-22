import Foundation

@main
struct SLOOSStandardsV1LogicTest {
    static func main() {
        let points = [
            SLOOSStandardsV1Logic.Point(availableDate: "2010-04-21", observationDate: "2010-04-01", value: -7.1),
            SLOOSStandardsV1Logic.Point(availableDate: "2012-02-01", observationDate: "2012-01-01", value: 5.4),
            SLOOSStandardsV1Logic.Point(availableDate: "2012-05-01", observationDate: "2012-04-01", value: -6.9),
        ]
        precondition(SLOOSStandardsV1Logic.riskOn(points: points, signalDate: "2010-04-20") == nil)
        precondition(SLOOSStandardsV1Logic.riskOn(points: points, signalDate: "2010-04-21") == true)
        precondition(SLOOSStandardsV1Logic.riskOn(points: points, signalDate: "2012-02-01") == false)
        precondition(SLOOSStandardsV1Logic.riskOn(points: points, signalDate: "2012-05-01") == true)

        let prior = ["gold_cny": 0.40, "nasdaq": 0.30, "sp500": 0.20, "csi300": 0.10]
        let current = ["gold_cny": 0.40, "nasdaq": 0.20, "sp500": 0.10, "csi300": 0.10]
        precondition(OrthogonalEventFactorV3Logic.isDeRiskEvent(priorBase: prior, currentBase: current))
        let retained = OrthogonalEventFactorV3Logic.retainedTarget(
            priorBase: prior,
            currentBase: current,
            retain: true,
            retentionFraction: 0.5
        )
        precondition(abs((retained["nasdaq"] ?? 0) - 0.25) < 1e-12)
        precondition(abs((retained["sp500"] ?? 0) - 0.15) < 1e-12)
        precondition(abs(retained.values.reduce(0, +) - 0.90) < 1e-12)
        print("SLOOS_STANDARDS_V1_LOGIC_TEST_OK")
    }
}

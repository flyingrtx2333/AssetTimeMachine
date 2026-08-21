import Foundation

@main
struct VRPProxyV1LogicTest {
    static func main() {
        let prices = (0...40).map { index in 100.0 * pow(1.001, Double(index)) }
        guard let rv = VRPProxyV1Logic.annualizedRealizedVariance(
            prices: prices,
            signalIndex: 40,
            lookbackReturns: 21
        ) else {
            preconditionFailure("realized variance missing")
        }
        let expected = 252.0 * pow(log(1.001), 2)
        precondition(abs(rv - expected) < 1e-12)

        precondition(VRPProxyV1Logic.median([4, 1, 3, 2]) == 2.5)
        precondition(VRPProxyV1Logic.median([3, 1, 2]) == 2.0)

        let points = [
            VRPProxyV1Logic.Point(date: "2026-01-01", value: 18),
            VRPProxyV1Logic.Point(date: "2026-01-02", value: 20),
            VRPProxyV1Logic.Point(date: "2026-01-03", value: 22),
        ]
        precondition(VRPProxyV1Logic.latestUsableValue(points: points, signalDate: "2026-01-03") == 22)
        precondition(VRPProxyV1Logic.latestUsableValue(points: points, signalDate: "2026-01-02") == 20)
        precondition(VRPProxyV1Logic.latestUsableValue(points: points, signalDate: "2026-01-10", maxStaleDays: 7) == 22)
        precondition(VRPProxyV1Logic.latestUsableValue(points: points, signalDate: "2026-01-11", maxStaleDays: 7) == nil)

        guard let vrp = VRPProxyV1Logic.vrpProxy(vixPercent: 20, realizedVariance: 0.03) else {
            preconditionFailure("vrp missing")
        }
        precondition(abs(vrp - 0.01) < 1e-12)

        let base = ["gold_cny": 0.20, "nasdaq": 0.20, "sp500": 0.10]
        let completed = VRPProxyV1Logic.completionTarget(base: base, factorRiskOn: true, fillFraction: 0.5)
        precondition(abs((completed["gold_cny"] ?? 0) - 0.30) < 1e-12)
        precondition(abs((completed["nasdaq"] ?? 0) - 0.30) < 1e-12)
        precondition(abs((completed["sp500"] ?? 0) - 0.15) < 1e-12)
        precondition(abs(completed.values.reduce(0, +) - 0.75) < 1e-12)

        let unchanged = VRPProxyV1Logic.completionTarget(base: base, factorRiskOn: false, fillFraction: 0.5)
        precondition(unchanged == base)

        print("VRP_PROXY_V1_LOGIC_TEST_OK")
    }
}

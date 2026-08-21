import Foundation

@main
struct LiteratureStressFactorV1LogicTest {
    static func main() {
        let points = (0..<30).map { index in
            LiteratureStressFactorV1Logic.Point(
                date: String(format: "2026-01-%02d", index + 1),
                value: Double(100 - index)
            )
        }

        precondition(
            LiteratureStressFactorV1Logic.fallingRiskOn(
                points: points,
                signalDate: "2026-01-30",
                lookbackObservations: 20,
                requireStrictPriorDate: false
            ) == true
        )
        precondition(
            LiteratureStressFactorV1Logic.fallingRiskOn(
                points: points,
                signalDate: "2026-01-30",
                lookbackObservations: 20,
                requireStrictPriorDate: true
            ) == true
        )

        let sameDaySpike = [
            LiteratureStressFactorV1Logic.Point(date: "2026-01-01", value: 100),
            LiteratureStressFactorV1Logic.Point(date: "2026-01-02", value: 90),
            LiteratureStressFactorV1Logic.Point(date: "2026-01-03", value: 200),
        ]
        precondition(
            LiteratureStressFactorV1Logic.latestUsableIndex(
                points: sameDaySpike,
                signalDate: "2026-01-03",
                maxStaleDays: 7,
                requireStrictPriorDate: false
            ) == 2
        )
        precondition(
            LiteratureStressFactorV1Logic.latestUsableIndex(
                points: sameDaySpike,
                signalDate: "2026-01-03",
                maxStaleDays: 7,
                requireStrictPriorDate: true
            ) == 1
        )

        let prior = ["gold_cny": 0.30, "nasdaq": 0.30, "sp500": 0.20]
        let current = ["gold_cny": 0.20, "nasdaq": 0.15, "sp500": 0.15]
        precondition(LiteratureStressFactorV1Logic.isDeRiskEvent(priorBase: prior, currentBase: current))
        let retained = LiteratureStressFactorV1Logic.retainedTarget(
            priorBase: prior,
            currentBase: current,
            retain: true,
            retentionFraction: 0.5
        )
        precondition(abs((retained["gold_cny"] ?? 0) - 0.25) < 1e-12)
        precondition(abs((retained["nasdaq"] ?? 0) - 0.225) < 1e-12)
        precondition(abs((retained["sp500"] ?? 0) - 0.175) < 1e-12)
        precondition(retained.values.reduce(0, +) <= 1.000000001)
        precondition(retained.values.allSatisfy { $0 >= 0 })

        print("LITERATURE_STRESS_FACTOR_V1_LOGIC_TEST_OK")
    }
}

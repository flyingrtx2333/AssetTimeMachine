import Foundation

@main
struct HighReturnArchitectureV1LogicTest {
    static func main() {
        let roles = ["gold_cny", "nasdaq", "sp500", "csi300", "shanghai_composite"]
        let rising = Array(1...300).map(Double.init)
        let falling = Array((1...300).reversed()).map(Double.init)
        let prices = [
            "gold_cny": rising,
            "nasdaq": rising,
            "sp500": rising,
            "csi300": falling,
            "shanghai_composite": falling,
        ]

        let trend = HighReturnArchitectureV1Logic.trendTarget(
            pricesBySymbol: prices,
            signalIndex: 299
        )
        precondition(Set(trend.keys).isSubset(of: Set(roles)))
        precondition(trend.values.reduce(0, +) <= 1.000000001)
        precondition((trend["csi300"] ?? 0) == 0)
        precondition((trend["shanghai_composite"] ?? 0) == 0)
        precondition((trend["gold_cny"] ?? 0) > 0 || (trend["nasdaq"] ?? 0) > 0 || (trend["sp500"] ?? 0) > 0)

        let broadRising = Dictionary(uniqueKeysWithValues: roles.map { ($0, rising) })
        let base = ["gold_cny": 0.20, "nasdaq": 0.20, "sp500": 0.20]
        let budget = HighReturnArchitectureV1Logic.riskBudgetTarget(
            baseTarget: base,
            pricesBySymbol: broadRising,
            signalIndex: 299
        )
        precondition(abs(budget.values.reduce(0, +) - 1.0) < 1e-9)
        precondition((budget["csi300"] ?? 0) == 0)
        precondition((budget["shanghai_composite"] ?? 0) == 0)

        let weakBudget = HighReturnArchitectureV1Logic.riskBudgetTarget(
            baseTarget: base,
            pricesBySymbol: prices,
            signalIndex: 299
        )
        precondition(abs(weakBudget.values.reduce(0, +) - 0.60) < 1e-9)

        let blend = HighReturnArchitectureV1Logic.blendedTarget(
            trend: trend,
            budget: budget
        )
        precondition(blend.values.allSatisfy { $0 >= 0 })
        precondition(blend.values.reduce(0, +) <= 1.000000001)

        let vol = HighReturnArchitectureV1Logic.annualizedVolatility(
            rising,
            signalIndex: 299,
            sessions: 60
        )
        precondition(vol != nil && vol! >= 0)

        print("HIGH_RETURN_LOGIC_TEST_OK")
    }
}

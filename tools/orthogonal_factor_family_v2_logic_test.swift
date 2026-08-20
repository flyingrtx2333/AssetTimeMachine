import Foundation

@main
struct OrthogonalFactorFamilyV2LogicTest {
    static func main() {
        func day(_ offset: Int) -> String {
            let base = Date(timeIntervalSince1970: 1_700_000_000)
            let date = Calendar(identifier: .gregorian).date(byAdding: .day, value: offset, to: base)!
            return OrthogonalFactorFamilyV2Logic.isoDay(date)
        }

        let staleProbe = [
            OrthogonalFactorFamilyV2Logic.Point(date: day(0), value: 1.0)
        ]
        precondition(OrthogonalFactorFamilyV2Logic.latestUsableIndex(points: staleProbe, signalDate: day(7)) == 0)
        precondition(OrthogonalFactorFamilyV2Logic.latestUsableIndex(points: staleProbe, signalDate: day(8)) == nil)

        let cpEasing = (0...24).map {
            OrthogonalFactorFamilyV2Logic.Point(date: day($0), value: 5.0 - Double($0) * 0.02)
        }
        let fedFundsFlat = (0...24).map {
            OrthogonalFactorFamilyV2Logic.Point(date: day($0), value: 4.0)
        }
        precondition(
            OrthogonalFactorFamilyV2Logic.fundingRiskOn(
                commercialPaper: cpEasing,
                fedFunds: fedFundsFlat,
                signalDate: day(24)
            ) == true
        )

        let cpWorsening = (0...24).map {
            OrthogonalFactorFamilyV2Logic.Point(date: day($0), value: 4.0 + Double($0) * 0.02)
        }
        precondition(
            OrthogonalFactorFamilyV2Logic.fundingRiskOn(
                commercialPaper: cpWorsening,
                fedFunds: fedFundsFlat,
                signalDate: day(24)
            ) == false
        )

        let copperStrong = (0...24).map {
            OrthogonalFactorFamilyV2Logic.Point(date: day($0), value: 3.0 + Double($0) * 0.03)
        }
        let goldSlow = (0...24).map {
            OrthogonalFactorFamilyV2Logic.Point(date: day($0), value: 2_000.0 + Double($0))
        }
        precondition(
            OrthogonalFactorFamilyV2Logic.copperGoldRiskOn(
                copper: copperStrong,
                gold: goldSlow,
                signalDate: day(24)
            ) == true
        )
        precondition(
            OrthogonalFactorFamilyV2Logic.copperGoldRiskOn(
                copper: goldSlow,
                gold: copperStrong,
                signalDate: day(24)
            ) == false
        )

        let skewFalling = (0...24).map {
            OrthogonalFactorFamilyV2Logic.Point(date: day($0), value: 150.0 - Double($0))
        }
        precondition(OrthogonalFactorFamilyV2Logic.skewRiskOn(points: skewFalling, signalDate: day(24)) == true)

        let skewRising = (0...24).map {
            OrthogonalFactorFamilyV2Logic.Point(date: day($0), value: 120.0 + Double($0))
        }
        precondition(OrthogonalFactorFamilyV2Logic.skewRiskOn(points: skewRising, signalDate: day(24)) == false)

        let base = [
            "gold_cny": 0.25,
            "nasdaq": 0.20,
            "sp500": 0.15,
            "csi300": 0.0,
            "shanghai_composite": -0.10
        ]
        let filled = OrthogonalFactorFamilyV2Logic.completedRiskBudget(baseTarget: base, riskOn: true)
        precondition(abs(filled.values.reduce(0, +) - 1.0) < 1e-9)
        precondition((filled["csi300"] ?? 0) == 0)
        precondition((filled["shanghai_composite"] ?? 0) == 0)

        let unchanged = OrthogonalFactorFamilyV2Logic.completedRiskBudget(baseTarget: base, riskOn: false)
        precondition(abs(unchanged.values.reduce(0, +) - 0.60) < 1e-9)

        print("ORTHOGONAL_FACTOR_V2_LOGIC_TEST_OK")
    }
}

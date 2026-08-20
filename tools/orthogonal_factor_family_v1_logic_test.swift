import Foundation

@main
struct OrthogonalFactorFamilyV1LogicTest {
    static func main() {
        func day(_ offset: Int) -> String {
            let base = Date(timeIntervalSince1970: 1_700_000_000)
            return OrthogonalFactorFamilyV1Logic.isoDay(
                Calendar(identifier: .gregorian).date(byAdding: .day, value: offset, to: base)!
            )
        }

        let curvePositive = [
            OrthogonalFactorFamilyV1Logic.Point(date: day(0), value: -0.2),
            OrthogonalFactorFamilyV1Logic.Point(date: day(1), value: 0.3),
        ]
        precondition(OrthogonalFactorFamilyV1Logic.curveRiskOn(points: curvePositive, signalDate: day(1)) == true)

        let curveNegative = [
            OrthogonalFactorFamilyV1Logic.Point(date: day(0), value: 0.2),
            OrthogonalFactorFamilyV1Logic.Point(date: day(1), value: -0.1),
        ]
        precondition(OrthogonalFactorFamilyV1Logic.curveRiskOn(points: curveNegative, signalDate: day(1)) == false)
        precondition(OrthogonalFactorFamilyV1Logic.curveRiskOn(points: curvePositive, signalDate: day(10)) == nil)

        let weakeningDollar = (0...24).map {
            OrthogonalFactorFamilyV1Logic.Point(date: day($0), value: 120.0 - Double($0))
        }
        precondition(OrthogonalFactorFamilyV1Logic.dollarRiskOn(points: weakeningDollar, signalDate: day(24)) == true)

        let strengtheningDollar = (0...24).map {
            OrthogonalFactorFamilyV1Logic.Point(date: day($0), value: 100.0 + Double($0))
        }
        precondition(OrthogonalFactorFamilyV1Logic.dollarRiskOn(points: strengtheningDollar, signalDate: day(24)) == false)

        let rut = (0...24).map {
            OrthogonalFactorFamilyV1Logic.Point(date: day($0), value: 100.0 + 2.0 * Double($0))
        }
        let rui = (0...24).map {
            OrthogonalFactorFamilyV1Logic.Point(date: day($0), value: 100.0 + Double($0))
        }
        precondition(OrthogonalFactorFamilyV1Logic.sizeRiskOn(rut: rut, rui: rui, signalDate: day(24)) == true)
        precondition(OrthogonalFactorFamilyV1Logic.sizeRiskOn(rut: rui, rui: rut, signalDate: day(24)) == false)

        let base = [
            "gold_cny": 0.20,
            "nasdaq": 0.30,
            "sp500": 0.10,
            "csi300": 0.0,
            "shanghai_composite": -0.1,
        ]
        let filled = OrthogonalFactorFamilyV1Logic.completedRiskBudget(baseTarget: base, riskOn: true)
        precondition(abs(filled.values.reduce(0, +) - 1.0) < 1e-9)
        precondition((filled["csi300"] ?? 0) == 0)
        precondition((filled["shanghai_composite"] ?? 0) == 0)
        precondition((filled["gold_cny"] ?? 0) > 0)
        precondition((filled["nasdaq"] ?? 0) > 0)
        precondition((filled["sp500"] ?? 0) > 0)

        let unchanged = OrthogonalFactorFamilyV1Logic.completedRiskBudget(baseTarget: base, riskOn: false)
        precondition(abs(unchanged.values.reduce(0, +) - 0.60) < 1e-9)

        print("ORTHOGONAL_FACTOR_LOGIC_TEST_OK")
    }
}

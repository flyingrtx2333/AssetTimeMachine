import Foundation

@main
struct FinalCrisisFilterV6LogicTest {
    static func main() {
        func day(_ offset: Int) -> String {
            let base = Date(timeIntervalSince1970: 1_700_000_000)
            let date = Calendar(identifier: .gregorian).date(byAdding: .day, value: offset, to: base)!
            return OrthogonalEventFactorV3Logic.isoDay(date)
        }

        let nonInverted = (0...24).map {
            OrthogonalEventFactorV3Logic.Point(date: day($0), value: 0.95)
        }
        precondition(FinalCrisisFilterV6Logic.vixTermRiskOn(points: nonInverted, signalDate: day(24)) == true)

        let inverted = (0...24).map {
            OrthogonalEventFactorV3Logic.Point(date: day($0), value: 1.05)
        }
        precondition(FinalCrisisFilterV6Logic.vixTermRiskOn(points: inverted, signalDate: day(24)) == false)

        let vvixFalling = (0...24).map {
            OrthogonalEventFactorV3Logic.Point(date: day($0), value: 120.0 - Double($0))
        }
        precondition(FinalCrisisFilterV6Logic.falling20RiskOn(points: vvixFalling, signalDate: day(24)) == true)

        let vvixRising = (0...24).map {
            OrthogonalEventFactorV3Logic.Point(date: day($0), value: 100.0 + Double($0))
        }
        precondition(FinalCrisisFilterV6Logic.falling20RiskOn(points: vvixRising, signalDate: day(24)) == false)

        let creditRising = (0...24).map {
            OrthogonalEventFactorV3Logic.Point(date: day($0), value: 1.0 + Double($0) * 0.01)
        }
        precondition(FinalCrisisFilterV6Logic.rising20RiskOn(points: creditRising, signalDate: day(24)) == true)

        let stale = [OrthogonalEventFactorV3Logic.Point(date: day(0), value: 0.90)]
        precondition(FinalCrisisFilterV6Logic.vixTermRiskOn(points: stale, signalDate: day(8)) == nil)

        print("FINAL_CRISIS_FILTER_V6_LOGIC_TEST_OK")
    }
}

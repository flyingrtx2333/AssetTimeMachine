import Foundation

@main
struct HouseholdEquityShareV1LogicTest {
    static func main() {
        let points = [
            HouseholdEquityShareV1Logic.Point(quarter: "2016Q2", availableDate: "2016-09-16", householdEquityShare: 0.72),
            HouseholdEquityShareV1Logic.Point(quarter: "2016Q3", availableDate: "2016-12-08", householdEquityShare: 0.70),
            HouseholdEquityShareV1Logic.Point(quarter: "2016Q4", availableDate: "2017-03-10", householdEquityShare: 0.68),
            HouseholdEquityShareV1Logic.Point(quarter: "2017Q1", availableDate: "2017-06-09", householdEquityShare: 0.74),
        ]

        precondition(HouseholdEquityShareV1Logic.latestRiskOn(points: points, signalDate: "2017-03-09") == nil)
        precondition(HouseholdEquityShareV1Logic.latestRiskOn(points: points, signalDate: "2017-03-10") == true)
        precondition(HouseholdEquityShareV1Logic.latestRiskOn(points: points, signalDate: "2017-06-09") == false)

        let base = ["gold_cny": 0.30, "nasdaq": 0.20, "sp500": 0.10, "csi300": 0.05]
        precondition(HouseholdEquityShareV1Logic.isEligibleUnderinvestedEvent(baseTarget: base))
        let completed = HouseholdEquityShareV1Logic.completedUSRiskBudget(baseTarget: base, riskOn: true)
        let gross = completed.values.reduce(0, +)
        precondition(abs(gross - 1.0) < 1e-12)
        precondition(abs((completed["gold_cny"] ?? 0) - 0.30) < 1e-12)
        precondition(abs((completed["csi300"] ?? 0) - 0.05) < 1e-12)
        precondition((completed["nasdaq"] ?? 0) > 0.20)
        precondition((completed["sp500"] ?? 0) > 0.10)

        let unchanged = HouseholdEquityShareV1Logic.completedUSRiskBudget(baseTarget: base, riskOn: false)
        precondition(abs(unchanged.values.reduce(0, +) - 0.65) < 1e-12)
        print("HOUSEHOLD_EQUITY_SHARE_V1_LOGIC_TEST_OK")
    }
}

import Foundation

@main
enum SahmState001LogicTest {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8)); exit(1) }
    }
    static func main() {
        let points = [
            SahmState001Logic.Point(date: "2024-05-01", value: 0.10),
            .init(date: "2024-06-01", value: 0.55),
            .init(date: "2024-07-01", value: 0.80)
        ]
        require(SahmState001Logic.owner(points: points, executionDateKey: "2024-06-17") == "nasdaq", "June review must use May, not June")
        require(SahmState001Logic.owner(points: points, executionDateKey: "2024-07-15") == "gold_cny", "July review must use June 0.55 trigger")
        var futureChanged = points
        futureChanged[2] = .init(date: "2024-07-01", value: -10)
        require(SahmState001Logic.owner(points: futureChanged, executionDateKey: "2024-07-15") == "gold_cny", "same-month future-labelled value must not affect July review")
        require(SahmState001Logic.isReviewDate(currentDateKey: "2024-07-15", priorDateKey: "2024-07-12"), "first session crossing day 15 must review")
        require(!SahmState001Logic.isReviewDate(currentDateKey: "2024-07-16", priorDateKey: "2024-07-15"), "later sessions must not review again")
        print("SAHM_STATE_001_LOGIC_TEST_OK")
    }
}

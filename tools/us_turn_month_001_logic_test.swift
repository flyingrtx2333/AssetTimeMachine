import Foundation

@main
enum USTurnMonth001LogicTest {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }

    static func main() {
        let dates = [
            "2026-01-27", "2026-01-28", "2026-01-29", "2026-01-30",
            "2026-02-02", "2026-02-03", "2026-02-04", "2026-02-05",
            "2026-02-26", "2026-02-27",
            "2026-03-02", "2026-03-03", "2026-03-04", "2026-03-05"
        ]
        let active = USTurnMonth001Logic.activeExecutionDates(tradingDates: dates)
        let januaryTurn = Set(["2026-01-29", "2026-01-30", "2026-02-02", "2026-02-03"])
        require(januaryTurn.isSubset(of: active), "January turn must activate penultimate/last Jan and first two Feb closes")
        require(!active.contains("2026-02-04"), "third next-month trading day must be the exit close, not a new active close")
        let februaryTurn = Set(["2026-02-26", "2026-02-27", "2026-03-02", "2026-03-03"])
        require(februaryTurn.isSubset(of: active), "February turn must follow the same four-close exposure schedule")
        require(USTurnMonth001Logic.activeExecutionDates(tradingDates: ["2026-01-30"]).isEmpty, "insufficient calendar must yield no exposure")
        print("US_TURN_MONTH_001_LOGIC_TEST_OK")
    }
}

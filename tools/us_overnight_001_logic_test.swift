import Foundation

@main
enum USOvernight001LogicTest {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }

    static func main() {
        let adjusted = USOvernight001Logic.fxAdjustedSyntheticOpen(
            previousClose: 100,
            previousCNYMultiplier: 7.0,
            currentCNYMultiplier: 7.2
        )!
        require(abs(adjusted * 7.2 - 700) < 1e-9, "synthetic open must preserve previous-close CNY value")

        let bounds = USOvernight001Logic.syntheticHighLow(open: 98, close: 101)!
        require(bounds.high == 101 && bounds.low == 98, "synthetic bar bounds must contain open and close")

        require(
            USOvernight001Logic.fxAdjustedSyntheticOpen(
                previousClose: .nan,
                previousCNYMultiplier: 7,
                currentCNYMultiplier: 7
            ) == nil,
            "invalid prices must be rejected"
        )
        require(USOvernight001Logic.syntheticHighLow(open: -1, close: 2) == nil, "nonpositive prices must be rejected")
        print("US_OVERNIGHT_001_LOGIC_TEST_OK")
    }
}

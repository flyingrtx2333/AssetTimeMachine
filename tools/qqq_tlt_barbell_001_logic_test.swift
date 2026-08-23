import Foundation

@main
enum QQQTLTBarbell001LogicTest {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }

    static func main() {
        require(QQQTLTBarbell001Logic.shouldAnnualRebalance(currentDateKey: "2026-01-02", previousDateKey: "2025-12-31"), "year boundary must rebalance")
        require(!QQQTLTBarbell001Logic.shouldAnnualRebalance(currentDateKey: "2026-06-01", previousDateKey: "2026-05-29"), "same year must not rebalance")
        require(QQQTLTBarbell001Logic.shouldAnnualRebalance(currentDateKey: "2026-01-02", previousDateKey: nil), "first decision must rebalance")
        require(abs((QQQTLTBarbell001Logic.targetWeights["qqq_tr"] ?? 0) - 0.5) < 1e-12, "QQQ weight frozen at 50%")
        require(abs((QQQTLTBarbell001Logic.targetWeights["tlt_tr"] ?? 0) - 0.5) < 1e-12, "TLT weight frozen at 50%")
        require(abs(QQQTLTBarbell001Logic.targetWeights.values.reduce(0,+) - 1.0) < 1e-12, "gross target must be 100%")
        print("QQQ_TLT_BARBELL_001_LOGIC_TEST_OK")
    }
}

import Foundation

@main
enum ChinaUSRelay001LogicTest {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }

    static func main() {
        let risingCSI = [ChinaUSRelay001Bar(close: 100), .init(close: 101)]
        let risingShanghai = [ChinaUSRelay001Bar(close: 3000), .init(close: 3010)]
        require(
            ChinaUSRelay001Logic.chinaRiskOn(
                csi300: risingCSI,
                csiIndex: 1,
                shanghai: risingShanghai,
                shanghaiIndex: 1
            ) == true,
            "both China indices rising must trigger risk-on"
        )

        let fallingShanghai = [ChinaUSRelay001Bar(close: 3000), .init(close: 2990)]
        require(
            ChinaUSRelay001Logic.chinaRiskOn(
                csi300: risingCSI,
                csiIndex: 1,
                shanghai: fallingShanghai,
                shanghaiIndex: 1
            ) == false,
            "one falling China index must block the breadth signal"
        )

        require(
            ChinaUSRelay001Logic.chinaRiskOn(
                csi300: risingCSI,
                csiIndex: 0,
                shanghai: risingShanghai,
                shanghaiIndex: 1
            ) == nil,
            "signal requires a completed prior real session for each China index"
        )

        let invalid = [ChinaUSRelay001Bar(close: 100), .init(close: .nan)]
        require(
            ChinaUSRelay001Logic.chinaRiskOn(
                csi300: invalid,
                csiIndex: 1,
                shanghai: risingShanghai,
                shanghaiIndex: 1
            ) == nil,
            "non-finite China close must invalidate the signal"
        )

        print("CHINA_US_RELAY_001_LOGIC_TEST_OK")
    }
}

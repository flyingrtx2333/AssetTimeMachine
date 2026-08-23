import Foundation

@main
enum PUTIndexProxy001LogicTest {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }
    static func main() {
        require(abs((PUTIndexProxy001Logic.putWeights["cboe_put_tr"] ?? 0) - 1.0) < 1e-12, "PUT proxy weight frozen at 100%")
        require(abs((PUTIndexProxy001Logic.spyWeights["spy_tr"] ?? 0) - 1.0) < 1e-12, "SPY control weight frozen at 100%")
        require(PUTIndexProxy001Logic.putWeights.values.reduce(0,+) <= 1.0, "PUT gross <=100%")
        print("PUT_INDEX_PROXY_001_LOGIC_TEST_OK")
    }
}

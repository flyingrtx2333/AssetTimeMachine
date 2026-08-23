import Foundation

@main
enum Halloween001LogicTest {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }

    static func main() {
        for month in 1...4 {
            require(Halloween001Logic.equityActive(executionDateKey: String(format: "2026-%02d-03", month)) == true, "Jan-Apr must be equity")
        }
        for month in 5...10 {
            require(Halloween001Logic.equityActive(executionDateKey: String(format: "2026-%02d-03", month)) == false, "May-Oct must be cash")
        }
        for month in 11...12 {
            require(Halloween001Logic.equityActive(executionDateKey: String(format: "2026-%02d-03", month)) == true, "Nov-Dec must be equity")
        }
        require(Halloween001Logic.equityActive(executionDateKey: "bad") == nil, "invalid date must not produce a state")
        print("HALLOWEEN_001_LOGIC_TEST_OK")
    }
}

import Foundation

@main
enum VIXPanic001LogicTest {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8)); exit(1) }
    }

    static func main() {
        let points = [
            VRPProxyV1Logic.Point(date: "2024-01-02", value: 18),
            .init(date: "2024-01-03", value: 31),
            .init(date: "2024-01-04", value: 12)
        ]
        require(VIXPanic001Logic.owner(points: points, signalDate: "2024-01-03") == "gold_cny", "T-1 VIX above 30 must own gold")
        require(VIXPanic001Logic.owner(points: points, signalDate: "2024-01-02") == "nasdaq", "VIX at or below 30 must own Nasdaq")
        require(VIXPanic001Logic.owner(points: points, signalDate: "2024-01-03") == VIXPanic001Logic.owner(points: Array(points.prefix(2)), signalDate: "2024-01-03"), "future VIX observation must not affect prior signal date")
        let stale = [VRPProxyV1Logic.Point(date: "2024-01-01", value: 40)]
        require(VIXPanic001Logic.owner(points: stale, signalDate: "2024-01-10") == nil, "VIX older than seven calendar days must be unavailable")
        print("VIX_PANIC_001_LOGIC_TEST_OK")
    }
}

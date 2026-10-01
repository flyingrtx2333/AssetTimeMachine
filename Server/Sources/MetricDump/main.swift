import Foundation
import AssetTimeMachineResearchSupport
#if os(Linux)
import Glibc
#else
import Darwin
#endif
@main struct Main {
    static func main() {
        do { try StrategyMetricDumpCLI.run() }
        catch { FileHandle.standardError.write(Data("METRIC_DUMP_ERROR: \(error)\n".utf8)); exit(1) }
    }
}

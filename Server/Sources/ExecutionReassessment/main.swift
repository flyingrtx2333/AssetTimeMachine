import AssetTimeMachineResearchSupport
import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif
@main struct Main {
    static func main() {
        do { try ExecutionReassessmentCLI.run() }
        catch {
            FileHandle.standardError.write(Data("Execution replay failed: \(error)\n".utf8))
            exit(1)
        }
    }
}

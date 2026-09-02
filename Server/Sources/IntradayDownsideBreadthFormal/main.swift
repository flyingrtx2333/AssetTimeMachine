import AssetTimeMachineBacktestCore
import Foundation

@main
struct Main {
    static func main() {
        do {
            try IntradayDownsideBreadthFormalCommand.run(
                arguments: Array(CommandLine.arguments.dropFirst())
            )
        } catch {
            FileHandle.standardError.write(
                Data("INTRADAY_DOWNSIDE_BREADTH_FORMAL_ERROR: \(error)\n".utf8)
            )
            exit(1)
        }
    }
}
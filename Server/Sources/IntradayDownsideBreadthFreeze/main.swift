import AssetTimeMachineBacktestCore
import Foundation

do {
    try IntradayDownsideBreadthFreezeCommand.run(arguments: Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("IDB_FREEZE_FAILED \(error)\n".utf8))
    exit(1)
}
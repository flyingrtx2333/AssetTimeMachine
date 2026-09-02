import AssetTimeMachineBacktestCore
import Foundation

do {
    try RSRangeBreadthFreezeCommand.run(arguments: Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("RS_FREEZE_FAILED \(error)\n".utf8))
    exit(1)
}
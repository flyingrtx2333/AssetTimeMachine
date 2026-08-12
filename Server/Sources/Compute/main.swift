import AssetTimeMachineBacktestCore
import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

func fail(_ message: String, code: Int32) -> Never {
    if let data = (message + "\n").data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
    exit(code)
}

guard CommandLine.arguments.count == 3 else {
    fail("usage: AssetTimeMachineBacktestCompute <invocation.json> <result.json>", code: 64)
}

do {
    let invocationURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let resultURL = URL(fileURLWithPath: CommandLine.arguments[2])
    let decoder = PublicBacktestComputeCodec.makeDecoder()
    let invocation = try decoder.decode(
        PublicBacktestComputeInvocation.self,
        from: Data(contentsOf: invocationURL)
    )
    let datasetData = try Data(contentsOf: URL(fileURLWithPath: invocation.datasetPath))
    let dataset = try PublicBacktestCore.loadDataset(
        from: datasetData,
        datasetHash: invocation.datasetHash,
        dataStale: invocation.dataStale
    )
    let result: PublicBacktestResult
    switch invocation.mode {
    case .prewarm:
        guard let strategyID = invocation.strategyID else {
            fail("prewarm invocation is missing strategy_id", code: 65)
        }
        result = try PublicBacktestCore.prewarm(strategyID: strategyID, dataset: dataset)
    case .run:
        guard let request = invocation.request else {
            fail("run invocation is missing request", code: 65)
        }
        result = try PublicBacktestCore.run(request: request, dataset: dataset)
    }
    let encoder = PublicBacktestComputeCodec.makeEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(result).write(to: resultURL, options: .atomic)
} catch {
    fail("computation failed: \(error.localizedDescription)", code: 70)
}

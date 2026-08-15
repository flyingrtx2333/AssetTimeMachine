#if canImport(AssetTimeMachineBacktestCore)
import AssetTimeMachineBacktestCore
#endif
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
    let encoder = PublicBacktestComputeCodec.makeEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    switch invocation.mode {
    case .prewarm:
        guard let strategyID = invocation.strategyID else {
            fail("prewarm invocation is missing strategy_id", code: 65)
        }
        let result = try PublicBacktestCore.prewarm(strategyID: strategyID, dataset: dataset)
        try encoder.encode(result).write(to: resultURL, options: .atomic)
    case .run:
        guard let request = invocation.request else {
            fail("run invocation is missing request", code: 65)
        }
        let result = try PublicBacktestCore.run(request: request, dataset: dataset)
        try encoder.encode(result).write(to: resultURL, options: .atomic)
    case .forward:
        guard let strategyID = invocation.strategyID,
              let macroPath = invocation.macroPath,
              let decisionAt = invocation.decisionAt else {
            fail("forward invocation is missing strategy_id, macro_path, or decision_at", code: 65)
        }
        let macroData = try Data(contentsOf: URL(fileURLWithPath: macroPath))
        let result = try PublicBacktestCore.forwardSnapshot(
            strategyID: strategyID,
            dataset: dataset,
            nfciData: macroData,
            decisionAt: decisionAt
        )
        try encoder.encode(result).write(to: resultURL, options: .atomic)
    }
} catch {
    fail("computation failed: \(error.localizedDescription)", code: 70)
}

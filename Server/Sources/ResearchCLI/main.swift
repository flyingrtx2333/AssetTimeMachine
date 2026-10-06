import Foundation
import AssetTimeMachineBacktestCore
import AssetTimeMachineResearchSupport
#if os(Linux)
import Glibc
#else
import Darwin
#endif

@main
struct ResearchCLI {
    static func main() {
        do { try execute() }
        catch {
            FileHandle.standardError.write(Data("research error: \(error)\n".utf8))
            exit(1)
        }
    }
    static func execute() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        let optionsByCommand: [String: Set<String>] = [
            "catalog": [], "configuration": ["--strategy"],
            "verify-cost-invariance": ["--history", "--strategy", "--macro"],
            "run": ["--config", "--history", "--macro", "--observations", "--output", "--source-commit"],
            "published-rule-screen": ["--history", "--output", "--source-commit"],
            "ibs-open-screen": ["--spy", "--history", "--output", "--source-commit"],
            "fomc-cycle-screen": ["--spy", "--history", "--calendar", "--output", "--source-commit"],
            "paper-register": ["--strategy", "--commission-percent", "--slippage-percent", "--output", "--source-commit"],
            "paper-signal": ["--account", "--history", "--macro", "--output", "--source-commit"],
            "paper-advance": ["--account", "--history", "--output", "--source-commit"]
        ]
        if let command = args.first, let allowed = optionsByCommand[command] {
            var index = 1
            var seen: Set<String> = []
            while index < args.count {
                guard allowed.contains(args[index]), seen.insert(args[index]).inserted,
                      args.indices.contains(index + 1), !args[index + 1].hasPrefix("--") else {
                    throw BacktestConfigurationError.invalidParameter("CLI option: \(args[index])")
                }
                index += 2
            }
        }
        func argument(_ name: String) throws -> String {
            guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else {
                throw BacktestConfigurationError.invalidParameter("required \(name)")
            }
            return args[index + 1]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        switch args.first {
        case "fomc-cycle-screen":
            try FOMCCycleScreen.run(spyPath: argument("--spy"), historyPath: argument("--history"),
                calendarPath: argument("--calendar"), outputPath: argument("--output"),
                sourceCommit: argument("--source-commit"))
        case "ibs-open-screen":
            try IBSOpenScreen.run(spyPath: argument("--spy"), historyPath: argument("--history"),
                outputPath: argument("--output"), sourceCommit: argument("--source-commit"))
        case "published-rule-screen":
            try PublishedRuleScreen.run(historyPath: argument("--history"),
                outputPath: argument("--output"), sourceCommit: argument("--source-commit"))
        case "paper-register", "paper-signal", "paper-advance":
            let source = try argument("--source-commit")
            let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            let binaryHash = ResearchRunEvidence.sha256(try Data(contentsOf: executable))
            let journal: ForwardPaperAccount.Journal
            if args.first == "paper-register" {
                guard let commission = Double(try argument("--commission-percent")),
                      let slippage = Double(try argument("--slippage-percent")) else {
                    throw BacktestConfigurationError.invalidParameter("paper costs must be percent per fill")
                }
                journal = try ForwardPaperAccount.register(strategyID: argument("--strategy"),
                    sourceCommit: source, binarySHA256: binaryHash,
                    commissionPercent: commission, slippagePercent: slippage)
            } else {
                let previous = try ForwardPaperAccount.read(URL(fileURLWithPath: argument("--account")))
                try ForwardPaperAccount.verifyRuntime(previous, sourceCommit: source, binarySHA256: binaryHash)
                let history = try Data(contentsOf: URL(fileURLWithPath: argument("--history")))
                if args.first == "paper-signal" {
                    journal = try ForwardPaperAccount.record(previous, historyData: history,
                        macroData: Data(contentsOf: URL(fileURLWithPath: argument("--macro"))))
                } else {
                    journal = try ForwardPaperAccount.advance(previous, historyData: history)
                }
            }
            try ForwardPaperAccount.write(journal, to: URL(fileURLWithPath: argument("--output")))
            print("paper account \(journal.contract.accountID), revision \(journal.revision); new immutable account.json saved")
        case "catalog":
            struct Entry: Encodable {
                let reference: StrategyReference
                let mode: String
                let requirements: StrategyDataRequirements
                let publicProduct: Bool
                let parameterHash: String
            }
            let rows = try StrategyRegistry.definitions.map { definition in
                Entry(reference: definition.reference, mode: definition.template.mode.rawValue,
                    requirements: definition.dataRequirements,
                    publicProduct: PublicBacktestCore.strategyIDs.contains(definition.reference.id),
                    parameterHash: ResearchRunEvidence.sha256(try definition.frozenParametersJSON))
            }
            print(String(decoding: try encoder.encode(rows), as: UTF8.self))
        case "configuration":
            let definition = try StrategyRegistry.definition(id: argument("--strategy"))
            let configuration = ResearchConfiguration(run: .init(strategy: definition.reference,
                purpose: .research, settings: definition.defaultSettings))
            print(String(decoding: try configuration.encoded(), as: UTF8.self))
        case "verify-cost-invariance":
            try StrategyCostVerification.run(historyPath: argument("--history"),
                strategyID: args.contains("--strategy") ? argument("--strategy") : "risk-contribution-cash-confidence-low-noise",
                macroPath: args.contains("--macro") ? argument("--macro") : nil)
        case "run":
            let output = URL(fileURLWithPath: try argument("--output"))
            guard !FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
            let configuration = try Data(contentsOf: URL(fileURLWithPath: argument("--config")))
            let history = try Data(contentsOf: URL(fileURLWithPath: argument("--history")))
            let macro: Data? = args.contains("--macro") ? try Data(contentsOf: URL(fileURLWithPath: argument("--macro"))) : nil
            let observations: Data? = args.contains("--observations") ? try Data(contentsOf: URL(fileURLWithPath: argument("--observations"))) : nil
            let commit = args.contains("--source-commit") ? try argument("--source-commit") : "unknown"
            let result = try ResearchRunEvidence.run(configurationData: configuration, historyData: history,
                macroData: macro, observationsData: observations, sourceCommit: commit)
            let binaryHash = ResearchRunEvidence.sha256(try Data(contentsOf:
                URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()))
            try ResearchRunEvidence.write(result, to: output, executableSHA256: binaryHash)
            print("RESEARCH_REPLAY_COMPLETE \(output.path)")
        default:
            print("AssetTimeMachineResearch catalog | configuration --strategy ID | run --config FILE --history FILE [--macro FILE] --output NEW_DIRECTORY [--source-commit SHA]")
            if !args.isEmpty { throw BacktestConfigurationError.invalidParameter("command") }
        }
    }
}

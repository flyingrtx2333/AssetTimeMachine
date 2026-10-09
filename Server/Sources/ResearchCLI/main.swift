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
            "qual-product-compare": ["--comparators", "--qual-directory", "--bindings", "--output", "--source-commit"],
            "product-benchmark-scope": ["--mode", "--history", "--macro", "--output", "--prepared", "--source-commit"],
            "verify-cost-invariance": ["--history", "--strategy", "--macro"],
            "run": ["--config", "--history", "--macro", "--observations", "--output", "--source-commit"],
            "published-rule-screen": ["--history", "--output", "--source-commit"],
            "industry-trend-screen": ["--etfs", "--history", "--output", "--source-commit", "--buy-budget-policy"],
            "sector-monthstart-screen": ["--sectors", "--history", "--output", "--source-commit"],
            "sector-residual-screen": ["--prices", "--history", "--output", "--source-commit"],
            "mii-light-screen": ["--spy", "--sectors", "--history", "--output", "--source-commit"],
            "rebalancing-pressure-screen": ["--prices", "--history", "--output", "--source-commit"],
            "credit-lead-screen": ["--prices", "--history", "--output", "--source-commit"],
            "spf-growth-revision-screen": ["--prices", "--history", "--output", "--source-commit"],
            "cross-market-stress-screen": ["--prices", "--history", "--output", "--source-commit"],
            "cross-market-cash-screen": ["--prices", "--history", "--cash", "--output", "--source-commit"],
            "stress-barbell-etf-comparison": ["--prices", "--history", "--cash", "--output", "--source-commit"],
            "recovered-term-structure": ["--mode", "--curve", "--history", "--prepared", "--output", "--source-commit"],
            "olmar-prediction-screen": ["--prices", "--history", "--output", "--source-commit"],
            "olmar-funded-screen": ["--prices", "--history", "--output", "--source-commit"],
            "haa-cash-screen": ["--prices", "--history", "--output", "--source-commit"],
            "saved-account-compare": ["--accounts", "--output", "--source-commit"],
            "saved-catalogue-common-compare": ["--accounts", "--output", "--source-commit"],
            "saved-technical-indicator-compare": ["--accounts", "--output", "--source-commit"],
            "qqq-reversal-screen": ["--prices", "--history", "--control-history", "--macro", "--output", "--source-commit"],
            "qqq-reversal-cash-correction": ["--prices", "--history", "--cash", "--accounts", "--output", "--source-commit"],
            "single-indicator-screen": ["--history", "--macro", "--output", "--source-commit"],
            "single-indicator-policy8": ["--history", "--accounts", "--output", "--source-commit"],
            "fixed-rsi-screen": ["--history", "--accounts", "--output", "--source-commit"],
            "fixed-absolute-momentum": ["--history", "--accounts", "--output", "--source-commit"],
            "fixed-capacity-tightness": ["--history", "--observations", "--accounts", "--output", "--source-commit"],
            "fixed-world-grain-balance": ["--history", "--observations", "--accounts", "--output", "--source-commit"],
            "fixed-housing-revision": ["--history", "--observations", "--accounts", "--output", "--source-commit"],
            "fixed-g17-screen": ["--history", "--observations", "--accounts", "--output", "--source-commit"],
            "fixed-monthly-momentum": ["--history", "--accounts", "--output", "--source-commit"],
            "fixed-sar-screen": ["--history", "--accounts", "--output", "--source-commit"],
            "close-indicator-screen": ["--history", "--accounts", "--output", "--source-commit"],
            "bollinger-parameter-screen": ["--history", "--accounts", "--output", "--source-commit"],
            "dix-demand-screen": ["--prices", "--history", "--output", "--source-commit"],
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
        case "qual-product-compare":
            try SavedQUALProductComparison.run(comparatorsPath: argument("--comparators"),
                qualDirectory: argument("--qual-directory"), bindingsPath: argument("--bindings"),
                outputPath: argument("--output"), sourceCommit: argument("--source-commit"))
        case "product-benchmark-scope":
            try ProductBenchmarkScopeReplay.run(mode: argument("--mode"), historyPath: argument("--history"),
                macroPath: argument("--macro"), outputPath: argument("--output"),
                preparedPath: argument("--prepared"), sourceCommit: argument("--source-commit"))
        case "recovered-term-structure":
            try RecoveredTermStructureScreen.run(mode:argument("--mode"),curvePath:argument("--curve"),
                historyPath:argument("--history"),preparedPath:argument("--prepared"),
                outputPath:argument("--output"),sourceCommit:argument("--source-commit"))
        case "single-indicator-policy8":
            try SingleIndicatorPolicyScreen.run(historyPath: argument("--history"), accountsPath: argument("--accounts"),
                outputPath: argument("--output"), sourceCommit: argument("--source-commit"))
        case "fixed-rsi-screen":
            try FixedRSIScreen.run(historyPath: argument("--history"), accountsPath: argument("--accounts"),
                outputPath: argument("--output"), sourceCommit: argument("--source-commit"))
        case "fixed-absolute-momentum":
            try AbsoluteMomentumScreen.run(historyPath: argument("--history"), accountsPath: argument("--accounts"),
                outputPath: argument("--output"), sourceCommit: argument("--source-commit"))
        case "fixed-capacity-tightness":
            try CapacityTightnessScreen.run(historyPath:argument("--history"),observationsPath:argument("--observations"),
                accountsPath:argument("--accounts"),outputPath:argument("--output"),sourceCommit:argument("--source-commit"))
        case "fixed-world-grain-balance":
            try WorldGrainBalanceScreen.run(historyPath:argument("--history"),observationsPath:argument("--observations"),
                accountsPath:argument("--accounts"),outputPath:argument("--output"),sourceCommit:argument("--source-commit"))
        case "fixed-housing-revision":
            try HousingRevisionScreen.run(historyPath:argument("--history"),observationsPath:argument("--observations"),
                accountsPath:argument("--accounts"),outputPath:argument("--output"),sourceCommit:argument("--source-commit"))
        case "fixed-g17-screen":
            try IndustrialProductionScreen.run(historyPath:argument("--history"),observationsPath:argument("--observations"),
                accountsPath:argument("--accounts"),outputPath:argument("--output"),sourceCommit:argument("--source-commit"))
        case "fixed-monthly-momentum":
            try MonthlyMomentumScreen.run(historyPath: argument("--history"), accountsPath: argument("--accounts"),
                outputPath: argument("--output"), sourceCommit: argument("--source-commit"))
        case "fixed-sar-screen":
            try ParabolicSARScreen.run(historyPath: argument("--history"), accountsPath: argument("--accounts"),
                outputPath: argument("--output"), sourceCommit: argument("--source-commit"))
        case "close-indicator-screen":
            try CloseIndicatorScreen.run(historyPath: argument("--history"), accountsPath: argument("--accounts"),
                outputPath: argument("--output"), sourceCommit: argument("--source-commit"))
        case "bollinger-parameter-screen":
            try BollingerParameterScreen.run(historyPath: argument("--history"), accountsPath: argument("--accounts"),
                outputPath: argument("--output"), sourceCommit: argument("--source-commit"))
        case "qqq-reversal-cash-correction":
            try QQQReversalCashCorrection.run(pricesPath: argument("--prices"), historyPath: argument("--history"),
                cashPath: argument("--cash"), accountsPath: argument("--accounts"),
                outputPath: argument("--output"), sourceCommit: argument("--source-commit"))
        case "saved-technical-indicator-compare":
            try SavedTechnicalIndicatorComparison.run(accountsPath: argument("--accounts"),
                outputPath: argument("--output"), sourceCommit: argument("--source-commit"))
        case "saved-catalogue-common-compare":
            try SavedCatalogueCommonComparison.run(accountsPath: argument("--accounts"),
                outputPath: argument("--output"), sourceCommit: argument("--source-commit"))
        case "saved-account-compare":
            try SavedAccountComparison.run(accountsPath: argument("--accounts"),
                outputPath: argument("--output"), sourceCommit: argument("--source-commit"))
        case "qqq-reversal-screen":
            try QQQReversalScreen.run(pricesPath: argument("--prices"), historyPath: argument("--history"), controlHistoryPath: argument("--control-history"), macroPath: argument("--macro"),
                outputPath: argument("--output"), sourceCommit: argument("--source-commit"))
        case "single-indicator-screen":
            try SingleIndicatorScreen.run(historyPath: argument("--history"), macroPath: argument("--macro"),
                outputPath: argument("--output"), sourceCommit: argument("--source-commit"))
        case "haa-cash-screen":
            try HAACashScreen.run(pricesPath: argument("--prices"), historyPath: argument("--history"),
                outputPath: argument("--output"), sourceCommit: argument("--source-commit"))
        case "olmar-funded-screen":
            try OLMARFundedScreen.run(pricesPath: argument("--prices"), historyPath: argument("--history"),
                outputPath: argument("--output"), sourceCommit: argument("--source-commit"))
        case "olmar-prediction-screen":
            try OLMARPredictionScreen.run(pricesPath: argument("--prices"), historyPath: argument("--history"),
                outputPath: argument("--output"), sourceCommit: argument("--source-commit"))
        case "cross-market-stress-screen":
            try CrossMarketStressScreen.run(pricesPath: argument("--prices"), historyPath: argument("--history"),
                outputPath: argument("--output"), sourceCommit: argument("--source-commit"))
        case "cross-market-cash-screen":
            try CrossMarketCashScreen.run(pricesPath: argument("--prices"), historyPath: argument("--history"),
                cashPath: argument("--cash"), outputPath: argument("--output"), sourceCommit: argument("--source-commit"))
        case "stress-barbell-etf-comparison":
            try StressBarbellETFComparison.run(pricesPath:argument("--prices"),historyPath:argument("--history"),
                cashPath:argument("--cash"),outputPath:argument("--output"),sourceCommit:argument("--source-commit"))
        case "spf-growth-revision-screen":
            try SPFGrowthRevisionScreen.run(pricesPath: argument("--prices"), historyPath: argument("--history"),
                outputPath: argument("--output"), sourceCommit: argument("--source-commit"))
        case "sector-residual-screen":
            try SectorResidualMomentumScreen.run(pricesPath: argument("--prices"), historyPath: argument("--history"),
                outputPath: argument("--output"), sourceCommit: argument("--source-commit"))
        case "dix-demand-screen":
            try DIXDemandScreen.run(pricesPath: argument("--prices"), historyPath: argument("--history"),
                outputPath: argument("--output"), sourceCommit: argument("--source-commit"))
        case "credit-lead-screen":
            try CreditLeadScreen.run(pricesPath: argument("--prices"), historyPath: argument("--history"),
                outputPath: argument("--output"), sourceCommit: argument("--source-commit"))
        case "rebalancing-pressure-screen":
            try RebalancingPressureScreen.run(pricesPath: argument("--prices"), historyPath: argument("--history"),
                outputPath: argument("--output"), sourceCommit: argument("--source-commit"))
        case "mii-light-screen":
            try MarketMindLightScreen.run(spyPath: argument("--spy"), sectorsPath: argument("--sectors"),
                historyPath: argument("--history"), outputPath: argument("--output"),
                sourceCommit: argument("--source-commit"))
        case "sector-monthstart-screen":
            try SectorMonthstartScreen.run(sectorsPath: argument("--sectors"), historyPath: argument("--history"),
                outputPath: argument("--output"), sourceCommit: argument("--source-commit"))
        case "industry-trend-screen":
            let policy: BacktestBuyBudgetPolicy
            if args.contains("--buy-budget-policy") {
                guard let value = BacktestBuyBudgetPolicy(rawValue: try argument("--buy-budget-policy")) else {
                    throw BacktestConfigurationError.invalidParameter("buy budget policy")
                }
                policy = value
            } else { policy = .symbolOrder }
            try IndustryTrendScreen.run(etfPath: argument("--etfs"), historyPath: argument("--history"),
                outputPath: argument("--output"), sourceCommit: argument("--source-commit"),
                buyBudgetPolicy: policy)
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

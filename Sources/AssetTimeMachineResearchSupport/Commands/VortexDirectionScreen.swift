import Foundation
import CoreFoundation
import AssetTimeMachineBacktestCore

/// Frozen Vortex14 OHLC direction state. Related D0 research, not original GTC orders.
public enum VortexDirectionScreen {
    public typealias Bar = ChaikinMoneyFlowScreen.Bar
    public typealias NativePreparation = ChaikinMoneyFlowScreen.NativePreparation
    public static let candidateID = "vortex14-qqq-long-cash"
    public static let buyHoldID = ChaikinMoneyFlowScreen.buyHoldID
    public static let cashID = ChaikinMoneyFlowScreen.cashID
    public static let qualID = ChaikinMoneyFlowScreen.qualID
    public static let period = 14

    public struct WindowEntry: Codable, Equatable {
        public let sourceDate: String
        public var VMplus: Double
        public var VMminus: Double
        public var TR: Double
        public init(sourceDate: String, VMplus: Double, VMminus: Double, TR: Double) {
            self.sourceDate = sourceDate; self.VMplus = VMplus; self.VMminus = VMminus; self.TR = TR
        }
    }
    public struct Signal: Codable, Equatable {
        public let date: Date
        public let sourceDate: String
        public let sourceOrdinal: Int
        public let currentUSDBar: Bar
        public let previousSourceDate: String?
        public let previousHighBeforeSplit: Double?
        public let previousLowBeforeSplit: Double?
        public let previousCloseBeforeSplit: Double?
        public let previousHigh: Double?
        public let previousLow: Double?
        public let previousClose: Double?
        public let appliedSplitDates: [Date]
        public let splitFactor: Double
        public let hasMovement: Bool
        public let VMplus: Double?
        public let VMminus: Double?
        public let TR: Double?
        public let window: [WindowEntry]
        public let windowCount: Int
        public let sumVMplus: Double
        public let sumVMminus: Double
        public let sumTR: Double
        public let VIplus: Double?
        public let VIminus: Double?
        public let available: Bool
        public let fundingEligible: Bool
        public let previousWeight: Double
        public let weight: Double

        enum CodingKeys: String, CodingKey {
            case date, sourceDate, sourceOrdinal, currentUSDBar, previousSourceDate
            case previousHighBeforeSplit, previousLowBeforeSplit, previousCloseBeforeSplit
            case previousHigh, previousLow, previousClose, appliedSplitDates, splitFactor
            case hasMovement, VMplus, VMminus, TR, window, windowCount
            case sumVMplus, sumVMminus, sumTR, VIplus, VIminus, available, fundingEligible
            case previousWeight, weight
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(date, forKey: .date); try c.encode(sourceDate, forKey: .sourceDate)
            try c.encode(sourceOrdinal, forKey: .sourceOrdinal); try c.encode(currentUSDBar, forKey: .currentUSDBar)
            try c.encode(previousSourceDate, forKey: .previousSourceDate)
            try c.encode(previousHighBeforeSplit, forKey: .previousHighBeforeSplit)
            try c.encode(previousLowBeforeSplit, forKey: .previousLowBeforeSplit)
            try c.encode(previousCloseBeforeSplit, forKey: .previousCloseBeforeSplit)
            try c.encode(previousHigh, forKey: .previousHigh); try c.encode(previousLow, forKey: .previousLow)
            try c.encode(previousClose, forKey: .previousClose)
            try c.encode(appliedSplitDates, forKey: .appliedSplitDates); try c.encode(splitFactor, forKey: .splitFactor)
            try c.encode(hasMovement, forKey: .hasMovement)
            try c.encode(VMplus, forKey: .VMplus); try c.encode(VMminus, forKey: .VMminus); try c.encode(TR, forKey: .TR)
            try c.encode(window, forKey: .window); try c.encode(windowCount, forKey: .windowCount)
            try c.encode(sumVMplus, forKey: .sumVMplus); try c.encode(sumVMminus, forKey: .sumVMminus)
            try c.encode(sumTR, forKey: .sumTR); try c.encode(VIplus, forKey: .VIplus); try c.encode(VIminus, forKey: .VIminus)
            try c.encode(available, forKey: .available); try c.encode(fundingEligible, forKey: .fundingEligible)
            try c.encode(previousWeight, forKey: .previousWeight); try c.encode(weight, forKey: .weight)
        }
    }

    // Preserve each specified Binary64 primitive and sum order; finite underflow is not a new failure.
    @inline(never) private static func finite(_ x: Double, _ context: String) throws -> Double {
        guard x.isFinite else { throw BacktestConfigurationError.invalidParameter(context + " nonfinite") }
        return x
    }
    @inline(never) private static func add(_ a: Double, _ b: Double, _ context: String) throws -> Double { try finite(a + b, context) }
    @inline(never) private static func subtract(_ a: Double, _ b: Double, _ context: String) throws -> Double { try finite(a - b, context) }
    @inline(never) private static func multiply(_ a: Double, _ b: Double, _ context: String) throws -> Double { try finite(a * b, context) }
    @inline(never) private static func divide(_ a: Double, _ b: Double, _ context: String) throws -> Double { try finite(a / b, context) }

    /// Source-only sequential model. Zero through thirteen movements are unavailable, not zero VI.
    public static func signals(bars: [Bar], splits: [Date: Double] = [:], stateEligibleFrom: Date) throws -> [Signal] {
        guard !bars.isEmpty, stateEligibleFrom.timeIntervalSinceReferenceDate.isFinite,
              zip(bars, bars.dropFirst()).allSatisfy({ $0.date < $1.date }),
              splits.allSatisfy({ $0.key.timeIntervalSinceReferenceDate.isFinite && $0.value.isFinite && $0.value > 0 }) else {
            throw BacktestConfigurationError.invalidParameter("Vortex14 ordered bars/splits/funding")
        }
        let splitDates = splits.keys.sorted()
        guard splitDates.first.map({ $0 > bars[0].date }) ?? true else {
            throw BacktestConfigurationError.invalidParameter("Vortex14 split without a prior source bar")
        }
        var splitIndex = 0, window: [WindowEntry] = [], result: [Signal] = [], weight = 0.0
        for (ordinal, bar) in bars.enumerated() {
            let day = BacktestSeriesAlignment.historicalSeriesDateString(from: bar.date)
            let context = "Vortex14 sourceOrdinal=\(ordinal) date=\(day)"
            guard bar.date.timeIntervalSinceReferenceDate.isFinite,
                  [bar.open, bar.high, bar.low, bar.close].allSatisfy({ $0.isFinite && $0 > 0 }),
                  bar.high >= max(bar.open, bar.close), bar.low <= min(bar.open, bar.close),
                  bar.volume.isFinite, bar.volume >= 0 else {
                throw BacktestConfigurationError.invalidParameter(context + " original USD OHLCV")
            }
            let priorBar: Bar? = ordinal == 0 ? nil : bars[ordinal - 1]
            let previousWeight = weight
            var previousHigh = priorBar?.high, previousLow = priorBar?.low, previousClose = priorBar?.close
            var applied: [Date] = [], splitFactor = 1.0
            if let priorBar {
                while splitIndex < splitDates.count, splitDates[splitIndex] <= bar.date {
                    let effectiveDate = splitDates[splitIndex], ratio = splits[effectiveDate]!
                    guard effectiveDate > priorBar.date else {
                        throw BacktestConfigurationError.invalidParameter(context + " duplicate or past split application")
                    }
                    previousHigh = try divide(previousHigh!, ratio, context + " split priorHigh")
                    previousLow = try divide(previousLow!, ratio, context + " split priorLow")
                    previousClose = try divide(previousClose!, ratio, context + " split priorClose")
                    for index in window.indices {
                        window[index].VMplus = try divide(window[index].VMplus, ratio, context + " split buffered VMplus")
                        window[index].VMminus = try divide(window[index].VMminus, ratio, context + " split buffered VMminus")
                        window[index].TR = try divide(window[index].TR, ratio, context + " split buffered TR")
                    }
                    splitFactor = try multiply(splitFactor, ratio, context + " metadata splitFactor")
                    applied.append(effectiveDate); splitIndex += 1
                }
            }
            var VMplus: Double? = nil, VMminus: Double? = nil, TR: Double? = nil
            if ordinal > 0 {
                VMplus = try finite(abs(subtract(bar.high, previousLow!, context + " high-priorLow")), context + " VMplus")
                VMminus = try finite(abs(subtract(bar.low, previousHigh!, context + " low-priorHigh")), context + " VMminus")
                let highLow = try subtract(bar.high, bar.low, context + " highLow")
                let highPrior = try finite(abs(subtract(bar.high, previousClose!, context + " high-priorClose")), context + " highPrior")
                let lowPrior = try finite(abs(subtract(bar.low, previousClose!, context + " low-priorClose")), context + " lowPrior")
                TR = try finite(max(highLow, max(highPrior, lowPrior)), context + " TR")
                window.append(.init(sourceDate: day, VMplus: VMplus!, VMminus: VMminus!, TR: TR!))
                if window.count > period { window.removeFirst() }
            }
            var sumVMplus = 0.0, sumVMminus = 0.0, sumTR = 0.0
            for entry in window {
                sumVMplus = try add(sumVMplus, entry.VMplus, context + " oldest-first sumVMplus")
                sumVMminus = try add(sumVMminus, entry.VMminus, context + " oldest-first sumVMminus")
                sumTR = try add(sumTR, entry.TR, context + " oldest-first sumTR")
            }
            let available = window.count == period, eligible = bar.date >= stateEligibleFrom
            var VIplus: Double? = nil, VIminus: Double? = nil
            if available {
                guard sumTR > 0 else { throw BacktestConfigurationError.invalidParameter(context + " formed14 sumTR domain") }
                VIplus = try divide(sumVMplus, sumTR, context + " VIplus")
                VIminus = try divide(sumVMminus, sumTR, context + " VIminus")
            }
            weight = eligible && available && VIplus! > VIminus! ? 1 : 0
            result.append(.init(date: bar.date, sourceDate: day, sourceOrdinal: ordinal, currentUSDBar: bar,
                previousSourceDate: priorBar.map { BacktestSeriesAlignment.historicalSeriesDateString(from: $0.date) },
                previousHighBeforeSplit: priorBar?.high, previousLowBeforeSplit: priorBar?.low, previousCloseBeforeSplit: priorBar?.close,
                previousHigh: previousHigh, previousLow: previousLow, previousClose: previousClose,
                appliedSplitDates: applied, splitFactor: splitFactor, hasMovement: ordinal > 0,
                VMplus: VMplus, VMminus: VMminus, TR: TR, window: window, windowCount: window.count,
                sumVMplus: sumVMplus, sumVMminus: sumVMminus, sumTR: sumTR, VIplus: VIplus, VIminus: VIminus,
                available: available, fundingEligible: eligible, previousWeight: previousWeight, weight: weight))
        }
        return result
    }
    public static func signalData(_ signals: [Signal]) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(signals)
    }

    private static let studyPath = "/Users/xiangjunsheng/FlyingrtxFast/research/asset-time-machine/workspace/studies/fixed-vortex14-source-2026-10-10"
    private static let pricesSHA = "1b0cf5cf1d642c7cec280e11e08e461c23948978ecf31645bc4cd2f18c73313c"
    private static let preSHA = "0c990d950d03c760ba772ab7089ffb17525f36327ebc015b1ac51fa580301b59"
    private static let inputSHA = "71d1e36c22a7b5e6c428d6c4b98b239a74f415c7c9211861d7e3b78743d07ccd"
    private static let interfaceSHA = "7a5c4e1b05a904fad432dd2fea148684b8c71c416502a6033e40140b59969c6c"
    private static let policyContracts: [(String, String)] = [
        ("/Users/xiangjunsheng/FlyingrtxFast/research/asset-time-machine/workspace/studies/source-frontier-vortex-author-2026-10-10/ROOT_POLICY_PROPOSAL.json", "b9afa6de3c8ce74aceb31fe82642960ab13f62d5585e2973d64be6b29a224d3a"),
        ("/Users/xiangjunsheng/FlyingrtxFast/research/asset-time-machine/workspace/studies/source-frontier-vortex-author-2026-10-10/ROOT_OPERATION_CLARIFICATION_V2.json", "5fe79ec658fa5998bb4087de3c27c2c2b3ecc1cea586f42f6a982271765cb069"),
        ("/Users/xiangjunsheng/FlyingrtxFast/research/asset-time-machine/workspace/studies/source-frontier-vortex-author-2026-10-10/ROOT_SOURCE_OPERATIONS_V3.json", "abce0e56e334ca29195cee07e3bc7d1ee61f89b412dd5a7730f60c7f48f86eac")
    ]
    private static func requireContracts(_ study: URL) throws {
        guard study.path == studyPath else { throw BacktestConfigurationError.invalidParameter("Vortex14 literal study path") }
        for (name, expected) in [("PRE_SPECIFICATION.json", preSHA), ("INPUT_FREEZE.json", inputSHA), ("SOURCE_INTERFACE.json", interfaceSHA)] {
            guard ResearchRunEvidence.sha256(try Data(contentsOf: study.appendingPathComponent(name))) == expected else {
                throw BacktestConfigurationError.invalidParameter("Vortex14 frozen contract " + name)
            }
        }
        for (path, expected) in policyContracts {
            guard ResearchRunEvidence.sha256(try Data(contentsOf: URL(fileURLWithPath: path))) == expected else {
                throw BacktestConfigurationError.invalidParameter("Vortex14 frozen operation contract " + path)
            }
        }
    }
    /// Source-only route. No accounts/history/FX/NAV are read.
    public static func exportSource(pricesPath: String, outputPath: String, sourceCommit: String) throws {
        let study = URL(fileURLWithPath: studyPath)
        try requireContracts(study)
        guard !sourceCommit.isEmpty, pricesPath == study.appendingPathComponent("inputs/prices.json").path,
              outputPath == study.appendingPathComponent("source/signals.json").path else {
            throw BacktestConfigurationError.invalidParameter("Vortex14 literal source entry")
        }
        let output = URL(fileURLWithPath: outputPath)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
        let raw = try Data(contentsOf: URL(fileURLWithPath: pricesPath))
        guard ResearchRunEvidence.sha256(raw) == pricesSHA else { throw BacktestConfigurationError.invalidParameter("Vortex14 frozen prices hash") }
        let input = try JSONDecoder().decode(Input.self, from: raw)
        try validateInput(input)
        let bars = try input.bars.map { row -> Bar in
            guard let date = BacktestSeriesAlignment.historicalSeriesDate(from: row.date) else {
                throw BacktestConfigurationError.invalidParameter("Vortex14 source bar date")
            }
            return Bar(date: date, open: row.open, high: row.high, low: row.low, close: row.close, volume: row.volume)
        }
        let splits = try Dictionary(uniqueKeysWithValues: input.splits.map { row -> (Date, Double) in
            guard let date = BacktestSeriesAlignment.historicalSeriesDate(from: row.date) else {
                throw BacktestConfigurationError.invalidParameter("Vortex14 source split date")
            }
            return (date, row.ratio)
        })
        let evidence = try signals(bars: bars, splits: splits,
            stateEligibleFrom: BacktestSeriesAlignment.historicalSeriesDate(from: "2000-01-13")!)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try signalData(evidence).write(to: output, options: .withoutOverwriting)
        print("Fixed Vortex14 source: \(evidence.count) original USD bar signals; no accounts.")
    }
    private static func validateInput(_ input: Input) throws {
        guard input.schema == "fixed-vortex14-v1", input.symbol == "QQQ", input.currency == "USD",
              input.bars.count == 6937, input.bars.first?.date == "1999-03-10", input.bars.last?.date == "2026-10-06",
              input.splits.count == 1, input.splits[0].date == "2000-03-20", input.splits[0].ratio == 2 else {
            throw BacktestConfigurationError.invalidParameter("Vortex14 frozen original USD bars/split")
        }
    }
    private static func jsonObject(_ path: URL) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any] else {
            throw BacktestConfigurationError.invalidParameter("Vortex14 metadata object " + path.lastPathComponent)
        }
        return object
    }
    private static func exactInt(_ value: Any?, equals expected: Int) -> Bool {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return false }
        return n.stringValue == String(expected)
    }
    private static func trueBool(_ value: Any?) -> Bool {
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return false }
        return n.boolValue
    }

    /// Authenticate and consume the saved source tape; no movement, sums or VI are recomputed.
    private static func qualifiedSource(study: URL, bars: [Bar], splits: [BacktestShareSplit],
        rawPrices: Data, sourceCommit: String, sourceSignalsPath: String) throws -> ([Signal], Data) {
        try requireContracts(study)
        let path = study.appendingPathComponent("source/signals.json")
        guard sourceSignalsPath == path.path else { throw BacktestConfigurationError.invalidParameter("Vortex14 literal qualified source path") }
        let data = try Data(contentsOf: path), dumpSHA = ResearchRunEvidence.sha256(data)
        let referencePath = study.appendingPathComponent("SOURCE_REFERENCE_REVIEW.json")
        let referenceData = try Data(contentsOf: referencePath)
        let reference = try jsonObject(referencePath)
        let receipt = try jsonObject(study.appendingPathComponent("SOURCE_REFERENCE_RECEIPT.json"))
        let source = try jsonObject(study.appendingPathComponent("SOURCE_EXPORT_RECEIPT.json"))
        guard source["stage"] as? String == "source", exactInt(source["exit_code"], equals: 0),
              trueBool(source["bindings_unchanged_after"]), let bindings = source["bindings"] as? [String: Any],
              bindings["app_commit"] as? String == sourceCommit,
              let files = bindings["files"] as? [String: String],
              bindings["binary_sha256"] as? String == ResearchRunEvidence.sha256(try Data(contentsOf:
                URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath())),
              receipt["stage"] as? String == "reference", exactInt(receipt["exit_code"], equals: 0),
              trueBool(receipt["bindings_unchanged_after"]),
              receipt["stdout_sha256"] as? String == ResearchRunEvidence.sha256(referenceData),
              reference["status"] as? String == "PASS_FIXED_VORTEX14_INDEPENDENT_SOURCE_REFERENCE",
              reference["source_dump_path"] as? String == path.path,
              reference["source_dump_sha256"] as? String == dumpSHA,
              reference["prices_sha256"] as? String == pricesSHA,
              reference["pre_specification_sha256"] as? String == preSHA,
              reference["input_freeze_sha256"] as? String == inputSHA,
              reference["source_interface_sha256"] as? String == interfaceSHA,
              exactInt(reference["source_signal_count"], equals: 6937),
              exactInt(reference["mismatches"], equals: 0),
              let blockers = reference["blockers"] as? [Any], blockers.isEmpty,
              ResearchRunEvidence.sha256(rawPrices) == pricesSHA else {
            throw BacktestConfigurationError.invalidParameter("Vortex14 mandatory actual source/reference qualification")
        }
        for (name, expected) in [("PRE_SPECIFICATION.json", preSHA), ("INPUT_FREEZE.json", inputSHA),
            ("SOURCE_INTERFACE.json", interfaceSHA), ("inputs/prices.json", pricesSHA)] {
            guard files[study.appendingPathComponent(name).path] == expected else {
                throw BacktestConfigurationError.invalidParameter("Vortex14 required source binding " + name)
            }
        }
        for (file, expected) in files {
            guard file.hasPrefix("/"), ResearchRunEvidence.sha256(try Data(contentsOf: URL(fileURLWithPath: file))) == expected else {
                throw BacktestConfigurationError.invalidParameter("Vortex14 source binding unchanged " + file)
            }
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let tape = try decoder.decode([Signal].self, from: data)
        guard tape.count == 6937, tape.count == bars.count, try signalData(tape) == data else {
            throw BacktestConfigurationError.invalidParameter("Vortex14 literal complete Codable source tape")
        }
        let funded = BacktestSeriesAlignment.historicalSeriesDate(from: "2000-01-13")!
        let splitEvents = splits.sorted { $0.effectiveDate < $1.effectiveDate }
        var splitIndex = 0
        for i in tape.indices {
            let s = tape[i], bar = bars[i], previous: Bar? = i == 0 ? nil : bars[i - 1]
            var applied: [Date] = [], factor = 1.0
            while splitIndex < splitEvents.count, splitEvents[splitIndex].effectiveDate <= bar.date {
                let event = splitEvents[splitIndex]
                guard let previous, event.effectiveDate > previous.date else {
                    throw BacktestConfigurationError.invalidParameter("Vortex14 saved split boundary")
                }
                applied.append(event.effectiveDate)
                factor = try multiply(factor, event.newUnitsPerOldUnit, "Vortex14 saved split metadata")
                splitIndex += 1
            }
            let available = i >= period, eligible = bar.date >= funded
            let expectedWeight: Double = eligible && available && (s.VIplus ?? -1) > (s.VIminus ?? -1) ? 1 : 0
            guard s.date == bar.date, s.sourceDate == BacktestSeriesAlignment.historicalSeriesDateString(from: bar.date),
                  s.sourceOrdinal == i, s.currentUSDBar == bar, s.hasMovement == (i > 0),
                  s.windowCount == min(i, period), s.window.count == s.windowCount,
                  s.available == available, s.fundingEligible == eligible,
                  s.previousSourceDate == previous.map({ BacktestSeriesAlignment.historicalSeriesDateString(from: $0.date) }),
                  s.previousHighBeforeSplit == previous?.high, s.previousLowBeforeSplit == previous?.low,
                  s.previousCloseBeforeSplit == previous?.close,
                  s.appliedSplitDates == applied, s.splitFactor == factor,
                  s.previousWeight == (i == 0 ? 0 : tape[i - 1].weight), s.weight == expectedWeight,
                  [s.sumVMplus, s.sumVMminus, s.sumTR].allSatisfy({ $0.isFinite && $0 >= 0 }) else {
                throw BacktestConfigurationError.invalidParameter("Vortex14 saved source date/clock/target \(i)")
            }
            if i == 0 {
                guard s.previousHigh == nil, s.previousLow == nil, s.previousClose == nil,
                      s.VMplus == nil, s.VMminus == nil, s.TR == nil,
                      s.window.isEmpty, s.sumVMplus == 0, s.sumVMminus == 0, s.sumTR == 0 else {
                    throw BacktestConfigurationError.invalidParameter("Vortex14 saved source0 explicit unavailable values")
                }
            } else {
                guard let high = s.previousHigh, let low = s.previousLow, let close = s.previousClose,
                      [high, low, close].allSatisfy({ $0.isFinite && $0 >= 0 }),
                      let plus = s.VMplus, let minus = s.VMminus, let tr = s.TR,
                      [plus, minus, tr].allSatisfy({ $0.isFinite && $0 >= 0 }),
                      s.window.last?.VMplus == plus, s.window.last?.VMminus == minus, s.window.last?.TR == tr else {
                    throw BacktestConfigurationError.invalidParameter("Vortex14 saved movement metadata/domain \(i)")
                }
                if applied.isEmpty {
                    guard high == previous!.high, low == previous!.low, close == previous!.close else {
                        throw BacktestConfigurationError.invalidParameter("Vortex14 unchanged saved prior OHLC")
                    }
                }
            }
            for (j, entry) in s.window.enumerated() {
                let ordinal = max(1, i - period + 1) + j
                guard entry.sourceDate == tape[ordinal].sourceDate,
                      [entry.VMplus, entry.VMminus, entry.TR].allSatisfy({ $0.isFinite && $0 >= 0 }) else {
                    throw BacktestConfigurationError.invalidParameter("Vortex14 saved window identity/domain \(i)")
                }
            }
            if available {
                guard s.sumTR > 0, let plus = s.VIplus, let minus = s.VIminus,
                      [plus, minus].allSatisfy({ $0.isFinite && $0 >= 0 }) else {
                    throw BacktestConfigurationError.invalidParameter("Vortex14 saved formed denominator/VI domain")
                }
            } else {
                guard s.VIplus == nil, s.VIminus == nil else {
                    throw BacktestConfigurationError.invalidParameter("Vortex14 saved formation explicit null VI")
                }
            }
        }
        return (tape, data)
    }
    public static func latestSignal(_ signals: [Signal], before date: Date) -> Signal? {
        var low = 0, high = signals.count
        while low < high {
            let mid = (low + high) / 2
            if signals[mid].date < date { low = mid + 1 } else { high = mid }
        }
        return low > 0 ? signals[low - 1] : nil
    }

    public typealias Role = ChaikinMoneyFlowScreen.Role
    public typealias Decision = ChaikinMoneyFlowScreen.Decision
    public struct NativeRun {
        public let simulation: BacktestDailySimulationResult
        public let decisions: [Decision]
        public let targetMismatchCount: Int
    }
    /// Shared one-asset target delivery: submit the first post-baseline target,
    /// then submit only changes. A split-day open uses the prior completed signal.
    public static func runAccount(preparation: NativePreparation, signals: [Signal], shareSplits: [BacktestShareSplit], role: Role) throws -> NativeRun {
        let frame = preparation.frame
        let execution = BacktestExecutionConfig(initialCash: 100000, feeRate: 0.00025, slippageRate: 0,
            rebalanceBand: 0, financingAnnualRate: 0, allowsFinancedExposure: false,
            buyReason: role == .candidate ? "fixed Vortex14 research" : "fixed CMF20 research")
        func desired(_ c: StrategyTargetContext) -> Double {
            guard c.index > frame.simulationRange.lowerBound else { return 0 }
            switch role {
            case .cash: return 0
            case .buyHold: return 1
            case .candidate: return latestSignal(signals, before: c.date)?.weight ?? 0
            }
        }
        var submitted: Double?, decisions: [Decision] = []
        guard let run = BacktestDailySimulator.run(frame: frame, execution: execution,
            provider: .init { desired($0) == 1 ? ["QQQ": 1] : [:] },
            rebalanceDecision: { _, _ in .init(shouldRebalance: false, refreshOverlay: false) },
            contextualRebalanceDecision: { c in
                let w = desired(c), previous = submitted
                let changed = c.index > frame.simulationRange.lowerBound && (submitted == nil || submitted != w)
                if changed { submitted = w }
                decisions.append(.init(index: c.index, date: c.date, signalDate: c.signalDate,
                    latestUSDBarDate: latestSignal(signals, before: c.date)?.date, desired: w,
                    previousSubmitted: previous, submitted: submitted, shouldRebalance: changed, accepted: 0))
                return .init(shouldRebalance: changed, refreshOverlay: false)
            }, executionPricesBySymbol: ["QQQ": preparation.opens], shareSplits: shareSplits) else {
            throw BacktestConfigurationError.computationFailed
        }
        guard run.dailyStates.count == decisions.count,
              run.dailyStates.first?.portfolioValue == 100000, run.dailyStates.first?.cash == 100000,
              run.dailyStates.first?.targetWeights.isEmpty == true,
              !run.trades.contains(where: { $0.date == frame.dates[frame.simulationRange.lowerBound] }) else {
            throw BacktestConfigurationError.invalidParameter("Vortex14 unchanged initial cash baseline")
        }
        var mismatches = 0
        for i in decisions.indices {
            decisions[i].accepted = run.dailyStates[i].targetWeights["QQQ"] ?? 0
            if decisions[i].accepted != decisions[i].desired { mismatches += 1 }
        }
        guard mismatches == 0 else { throw BacktestConfigurationError.invalidParameter("Vortex14 prior target delivery") }
        return .init(simulation: run, decisions: decisions, targetMismatchCount: mismatches)
    }

    private struct Input: Decodable {
        let schema: String; let symbol: String; let currency: String; let bars: [InputBar]; let splits: [Split]
        struct InputBar: Decodable {
            let date: String; let open: Double; let high: Double; let low: Double; let close: Double; let volume: Double
        }
        struct Split: Decodable { let date: String; let ratio: Double }
    }
    private struct Sources: Decodable {
        let schema: String; let files: [File]
        struct File: Decodable { let path: String; let sha256: String; let ids: [String] }
    }
    private struct Saved: Decodable { let id: String; let dailyStates: [BacktestDailyState] }
    private struct Account {
        let id: String; let states: [BacktestDailyState]; let trades: [AdvancedBacktestTrade]; let savedObject: [String: Any]?
    }
    private struct CashEvidence: Encodable {
        let startDate: Date?
        let endDate: Date?
        let totalCashInterest: Double
        let averageAnnualRate: Double
        let averageCashRatio: Double
        init(_ summary: CashYieldSummary) {
            startDate = summary.startDate; endDate = summary.endDate; totalCashInterest = summary.totalCashInterest
            averageAnnualRate = summary.averageAnnualRate; averageCashRatio = summary.averageCashRatio
        }
    }
    public static var savedControlIDs: [String] { ChaikinMoneyFlowScreen.savedControlIDs }

    public static func run(pricesPath: String, historyPath: String, accountsPath: String, outputPath: String, sourceCommit: String, sourceSignalsPath: String) throws {
        let output = URL(fileURLWithPath: outputPath)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
        let raw = try Data(contentsOf: URL(fileURLWithPath: pricesPath))
        let history = try Data(contentsOf: URL(fileURLWithPath: historyPath))
        let savedRaw = try Data(contentsOf: URL(fileURLWithPath: accountsPath))
        let input = try JSONDecoder().decode(Input.self, from: raw)
        let sources = try JSONDecoder().decode(Sources.self, from: savedRaw)
        guard input.schema == "fixed-vortex14-v1", input.symbol == "QQQ", input.currency == "USD",
              input.bars.count == 6937, input.bars.first?.date == "1999-03-10", input.bars.last?.date == "2026-10-06",
              input.splits.count == 1, input.splits[0].date == "2000-03-20", input.splits[0].ratio == 2,
              sources.schema == "fixed-vortex14-saved-v1", !sources.files.isEmpty,
              sources.files.flatMap(\.ids) == savedControlIDs, savedControlIDs.count == 31 else {
            throw BacktestConfigurationError.invalidParameter("Vortex14 frozen input and 31 saved-control scope")
        }
        func date(_ day: String) throws -> Date {
            guard let value = BacktestSeriesAlignment.historicalSeriesDate(from: day) else {
                throw BacktestConfigurationError.invalidParameter("Vortex14 session date")
            }
            return value
        }
        let bars = try input.bars.map { b in Bar(date: try date(b.date), open: b.open, high: b.high, low: b.low, close: b.close, volume: b.volume) }
        let splits = try input.splits.map { s in BacktestShareSplit(id: "QQQ:" + s.date, symbol: "QQQ",
            effectiveDate: try date(s.date), newUnitsPerOldUnit: s.ratio) }
        let study = output.deletingLastPathComponent()
        let (signalEvidence, savedSignalBytes) = try qualifiedSource(study: study, bars: bars, splits: splits,
            rawPrices: raw, sourceCommit: sourceCommit, sourceSignalsPath: sourceSignalsPath)
        let dataset = try PublicBacktestCore.loadDataset(from: history, datasetHash: ResearchRunEvidence.sha256(history), dataStale: false)
        guard let fx = dataset.seriesBySymbol["usd_per_cny"], fx.dates.first == "2000-01-13" else {
            throw BacktestConfigurationError.invalidParameter("Vortex14 original App FX start; no early extension")
        }
        let native = try ChaikinMoneyFlowScreen.nativePreparation(bars: bars, fxDates: fx.dates, fxPrices: fx.prices, baseline: date("2000-01-13"))
        guard native.frame.dates.last == (try date("2026-10-06")), native.frame.dates.count == 6722,
              native.frame.dates.count == input.bars.filter({ $0.date >= "2000-01-13" }).count else {
            throw BacktestConfigurationError.invalidParameter("Vortex14 every native QQQ session retained")
        }
        var accounts: [Account] = [], decisions: [String: [Decision]] = [:]
        var splitEvidence: [String: [BacktestSplitAdjustment]] = [:], targetAudits: [String: [String: Int]] = [:]
        var cashEvidence: [String: CashEvidence] = [:]
        for (id, role) in [(candidateID, Role.candidate), (buyHoldID, Role.buyHold), (cashID, Role.cash)] {
            let run = try runAccount(preparation: native, signals: signalEvidence, shareSplits: splits, role: role)
            decisions[id] = run.decisions; splitEvidence[id] = run.simulation.splitAdjustments
            cashEvidence[id] = CashEvidence(run.simulation.cashYieldSummary)
            targetAudits[id] = ["desired_accepted_mismatches": run.targetMismatchCount, "state_count": run.simulation.dailyStates.count]
            accounts.append(.init(id: id, states: run.simulation.dailyStates, trades: run.simulation.trades, savedObject: nil))
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var selectedIDs: [String] = []
        for file in sources.files {
            let data = try Data(contentsOf: URL(fileURLWithPath: file.path))
            guard ResearchRunEvidence.sha256(data) == file.sha256,
                  let objects = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw BacktestConfigurationError.invalidParameter("Vortex14 saved-control file hash/rows")
            }
            let rows = try decoder.decode([Saved].self, from: data)
            for id in file.ids {
                let matches = rows.filter { $0.id == id }, rawMatches = objects.filter { $0["id"] as? String == id }
                guard matches.count == 1, rawMatches.count == 1, !matches[0].dailyStates.isEmpty,
                      zip(matches[0].dailyStates, matches[0].dailyStates.dropFirst()).allSatisfy({ $0.date < $1.date }),
                      selectedIDs.contains(id) == false else {
                    throw BacktestConfigurationError.invalidParameter("Vortex14 saved-control identity/state order")
                }
                selectedIDs.append(id)
                accounts.append(.init(id: id, states: matches[0].dailyStates, trades: [], savedObject: rawMatches[0]))
            }
        }
        guard selectedIDs == savedControlIDs, accounts.count == 34 else { throw BacktestConfigurationError.invalidParameter("Vortex14 3 new / 31 saved account budget") }
        let text = BacktestSeriesAlignment.historicalSeriesDateString(from:)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        func object(_ row: DailyScreenOutput.Row, account: Account) throws -> [String: Any] {
            var result = try JSONSerialization.jsonObject(with: encoder.encode(row)) as! [String: Any]
            if let saved = account.savedObject { result["trades"] = saved["trades"] ?? [] }
            return result
        }
        func comparison(_ selected: [Account]) throws -> ([[String: Any]], [Date]) {
            let common = selected.reduce(Set(selected[0].states.map(\.date))) { $0.intersection(Set($1.states.map(\.date))) }.sorted()
            guard common.count > 252 else { throw BacktestConfigurationError.missingData("Vortex14 mechanical common calendar") }
            let commonSet = Set(common), last = common.last!
            let ten = BacktestSeriesAlignment.historicalSeriesCalendar.date(byAdding: .year, value: -10, to: last)!
            let windows = [("full", text(common.first!), text(last)), ("trailing10Y", text(ten), text(last)),
                ("since2020", "2020-01-01", text(last)), ("since2022", "2022-01-01", text(last)),
                ("crisis2008", "2008-01-01", "2008-12-31"), ("crisis2020", "2020-01-01", "2020-12-31"),
                ("crisis2022", "2022-01-01", "2022-12-31")]
            return (try selected.map { a in try object(DailyScreenOutput.row(a.id,
                states: a.states.filter { commonSet.contains($0.date) }, trades: a.trades, windows: windows), account: a) }, common)
        }
        let (longRows, longDates) = try comparison(accounts.filter { $0.id != qualID })
        let (allRows, allDates) = try comparison(accounts)
        guard longDates.count == 5595, text(longDates.first!) == "2002-09-18", text(longDates.last!) == "2026-09-30",
              allDates.count == 3086, text(allDates.first!) == "2013-07-18", text(allDates.last!) == "2026-09-30" else {
            throw BacktestConfigurationError.invalidParameter("Vortex14 frozen mechanical long/all20 calendars")
        }
        let nativeRows = try accounts.map { a -> [String: Any] in
            if let saved = a.savedObject { return saved }
            return try object(DailyScreenOutput.row(a.id, states: a.states, trades: a.trades,
                windows: [("native_full", text(a.states.first!.date), text(a.states.last!.date))]), account: a)
        }
        let result = try JSONSerialization.data(withJSONObject: longRows, options: [.sortedKeys])
        let nativeBytes = try JSONSerialization.data(withJSONObject: nativeRows, options: [.sortedKeys])
        let allBytes = try JSONSerialization.data(withJSONObject: allRows, options: [.sortedKeys])
        let signalBytes = savedSignalBytes
        let inputObject = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
        var nativeQuotes = try JSONSerialization.jsonObject(with: encoder.encode(native.quotes)) as! [[String: Any]]
        for key in ["fxDate", "usdPerCNY", "cnyPerUSD"] { nativeQuotes[0][key] = NSNull() }
        var decisionObjects = try JSONSerialization.jsonObject(with: encoder.encode(decisions)) as! [String: [[String: Any]]]
        for id in decisionObjects.keys {
            for index in decisionObjects[id]!.indices {
                for key in ["latestUSDBarDate", "previousSubmitted", "submitted"] where decisionObjects[id]![index][key] == nil {
                    decisionObjects[id]![index][key] = NSNull()
                }
            }
        }
        let quotesObject: [String: Any] = ["original_usd_bars": inputObject["bars"]!, "native_quotes": nativeQuotes,
            "split_events": inputObject["splits"]!, "input_price_units": "already-restored historical share units; no second adjustment"]
        let frameObject: [String: Any] = ["dates": native.frame.dates.map(text), "prices": native.frame.pricesBySymbol,
            "auction_prices": ["QQQ": native.opens], "observed": native.frame.observedBySymbol,
            "simulation_first": native.frame.simulationRange.lowerBound, "simulation_last": native.frame.simulationRange.upperBound]
        let evidence: [String: Any] = ["completed_at": ISO8601DateFormatter().string(from: Date()),
            "evidence_class": "USER_AUTHORIZED_RELATED_D0_OHLC_TREND_FULL_HISTORY_EXPOSED", "formal_validation": false,
            "recommendation_eligible": false, "source_commit": sourceCommit,
            "execution_version": BacktestExecutionVersion.defaultEngineVersion,
            "prices_sha256": ResearchRunEvidence.sha256(raw), "history_sha256": ResearchRunEvidence.sha256(history),
            "accounts_sha256": ResearchRunEvidence.sha256(savedRaw), "saved_source_files": sources.files.map { ["path": $0.path, "sha256": $0.sha256, "ids": $0.ids] as [String: Any] },
            "result_sha256": ResearchRunEvidence.sha256(result), "native_full_sha256": ResearchRunEvidence.sha256(nativeBytes),
            "all20_sha256": ResearchRunEvidence.sha256(allBytes), "signals_sha256": ResearchRunEvidence.sha256(signalBytes),
            "binary_sha256": ResearchRunEvidence.sha256(try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath())),
            "candidate_count": 1, "new_funded_account_count": 3, "saved_control_count": 31, "account_count": 34,
            "parameter_search_budget": 0, "tunable_parameter_count": 0, "estimated_parameter_count": 0, "period": period, "first_available_source_ordinal": period,
            "seed_policy": "Source0 no previous OHLC or movement; window empty and sums0; explicit null VI until14 movements; sourceordinal14 first available; full prefix retained with no funding/split reset",
            "recurrence_policy": "Original absolute cross-extreme VMplus/VMminus and max-range TR; separate fresh oldest-first fourteen-term sums and two divisions; finite daily TR0 allowed, formed sumTR<=0 or nonfinite terminal; no epsilon, reassociation, FMA, telescoping or rolling subtraction",
            "forecast_policy": "Root state VIplus>VIminus fullQQQ elseCNYcash including equality; prefunding/formation cash. Original crossing/GTC/short/ATR orders are not reproduced.",
            "position_state_eligible_from": "2000-01-13", "source_bar_count": bars.count, "native_state_count": native.frame.dates.count,
            "native_start": text(native.frame.dates.first!), "native_end": text(native.frame.dates.last!),
            "primary_metric": "App native-full daily NAV Sharpe Rf=0; long-common19 is an additional required comparison gate",
            "common_history_is_primary_user_choice": false,
            "primary": ["metric": "App native complete-funded-history raw-return Sharpe Rf0", "threshold": 1.2,
                "require_native_full": true, "require_long_common19_sharpe_at_least_1_2": true,
                "require_beat_strongest19": true, "all20_supplement_only": true, "all20_short_common_supplement_only": true] as [String: Any],
            "strongest19_control_ids": BacktestProductStrategyCatalog.curatedTemplateIDs + BacktestProductStrategyCatalog.basicTemplateIDs,
            "long_common_dates": longDates.map(text), "all20_common_dates": allDates.map(text),
            "long_comparison_count": longRows.count, "all20_comparison_count": allRows.count,
            "long_excluded_id": qualID, "saved_control_ids": selectedIDs, "target_audits": targetAudits,
            "native_control_inheritance": "QQQ buy-hold and CNY cash retain unchanged CMF native preparation/execution, including original engine buyReason fixed CMF20 research",
            "fee_rate": 0.00025, "slippage_rate": 0, "cash": "CashYieldCNY",
            "fx_policy": "unchanged App FX / strictly prior calendar date / max14 calendar days / same factor OHLC",
            "cash_baseline_policy": "2000-01-13 cash100000; zero unavailable QQQ mark and auction; no target or trade",
            "signal_policy": "Completed originalUSD OHLC source strictly before actual next open; finance loads only actual independently qualified literal source tape without running movements, sums or VI",
            "price_units": "Input already restores historical OHLC; each effective split divides prior internal H/L/C and every buffered VM/TR separately, before current movement; aggregates recomputed, old emitted rows immutable; original engine handles held units",
            "source_authority": "Botes/Siepman original Vortex article worked14 example plus Root prospective state/cash/open adaptation; exact three contract bytes bound to PRE",
            "source_operation_contracts": policyContracts.map { ["path": $0.0, "sha256": $0.1] },
            "pre_specification_sha256": preSHA,
            "input_freeze_sha256": inputSHA, "source_interface_sha256": interfaceSHA,
            "qualified_source_dump_path": study.appendingPathComponent("source/signals.json").path,
            "source_reference_review_sha256": ResearchRunEvidence.sha256(try Data(contentsOf: study.appendingPathComponent("SOURCE_REFERENCE_REVIEW.json"))),
            "source_reference_receipt_sha256": ResearchRunEvidence.sha256(try Data(contentsOf: study.appendingPathComponent("SOURCE_REFERENCE_RECEIPT.json"))),
            "source_export_receipt_sha256": ResearchRunEvidence.sha256(try Data(contentsOf: study.appendingPathComponent("SOURCE_EXPORT_RECEIPT.json"))),
            "limitations": ["Related OHLC trend D0, not independent alpha or original GTC/crossing/short/ATR order replication. In exact arithmetic overlapping range pairs telescope to endpoint midpoint momentum; the literal Binary64 calculation is retained. Global execution census UNKNOWN.",
                "Original vendor price-unit/current-vintage restoration is not publication-vintage or complete point-in-time quote certification. Vortex ignores volume and does not qualify close-volume dollar-volume inputs.",
                "No dividends, tax, FX conversion fees or separate USD-wallet certification; no result-driven period/threshold/latch/ATR/instrument/clock/history rescue.",
                "Full native cash baseline and mechanical same-account comparison calendars;31 saved whole rows and controls unchanged; shorter all20 is supplemental only."]]
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, data) in [("result.json", result), ("native-full.json", nativeBytes), ("all20.json", allBytes),
            ("signals.json", signalBytes), ("decisions.json", try JSONSerialization.data(withJSONObject: decisionObjects, options: [.sortedKeys])),
            ("splits.json", try encoder.encode(splitEvidence)), ("cash-yield.json", try encoder.encode(cashEvidence)),
            ("quotes.json", try JSONSerialization.data(withJSONObject: quotesObject, options: [.sortedKeys])),
            ("native-frame.json", try JSONSerialization.data(withJSONObject: frameObject, options: [.sortedKeys])),
            ("evidence.json", try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys, .prettyPrinted]))] {
            try data.write(to: output.appendingPathComponent(name))
        }
        print("Fixed Vortex14: 1 candidate, 3 new accounts, 31 saved controls; native \(native.frame.dates.count)/long \(longDates.count)/all20 \(allDates.count) dates.")
    }
}

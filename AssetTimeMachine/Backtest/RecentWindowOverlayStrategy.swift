import Foundation

/// Product implementation of three retrospective, recent-window SCREEN candidates.
///
/// These remain exploratory strategies. Every target is frozen before portfolio simulation,
/// uses only the `signalIndex` (strict T-1), is long-only, and has gross exposure capped at 1.
nonisolated enum RecentWindowOverlayStrategy {
    enum Mode: Equatable {
        case volatilityManagedIdleCash
        case pairSpreadZ252Shift25
        case goldEquityRelativeZ252Shift25
    }

    struct VolatilityTarget: Equatable {
        let target: [String: Double]
        let multiplier: Double
        let annualizedVolatility: Double
    }

    static let goldSymbol = "gold_cny"
    static let moneySymbol = "money511990_cny"
    static let spySymbol = "spy_tr"
    static let oneqSymbol = "oneq_tr"
    static let sseETFSymbol = "etf510210_cny"
    static let csiETFSymbol = "etf510300_cny"
    static let legacyRiskSymbols = ["nasdaq", "sp500", "csi300", "shanghai_composite"]
    static let equitySymbols = [spySymbol, oneqSymbol, sseETFSymbol, csiETFSymbol]
    static let riskSymbols = [goldSymbol] + legacyRiskSymbols + equitySymbols
    static let requiredSymbols: Set<String> = Set([goldSymbol] + legacyRiskSymbols)

    static let volatilityLookback = 63
    static let volatilityTarget = 0.10
    static let spreadLookback = 252
    static let zThreshold = 1.0
    static let shiftFraction = 0.25
    static let epsilon = 1e-10

    static func corrVarCompletedTarget(source: [String: Double], dateKey: String) -> [String: Double] {
        let positive = source.mapValues { max($0, 0) }
        let sourceSymbols = [goldSymbol] + legacyRiskSymbols
        let gross = sourceSymbols.reduce(0) { $0 + (positive[$1] ?? 0) }
        guard gross > epsilon, gross < 1 - epsilon else { return positive }
        let fraction = RecentWindowCorrVarSchedule.completionFraction(for: dateKey)
        let targetGross = gross + fraction * (1 - gross)
        let scale = targetGross / gross
        return positive.mapValues { $0 * scale }
    }

    static func volatilityManagedTarget(
        base: [String: Double],
        trailingBasketReturns: [Double]
    ) -> VolatilityTarget? {
        guard trailingBasketReturns.count == volatilityLookback,
              trailingBasketReturns.allSatisfy(\.isFinite) else { return nil }
        let baseGross = riskSymbols.reduce(0) { $0 + max(base[$1] ?? 0, 0) }
        guard baseGross > epsilon, baseGross < 1 - epsilon else { return nil }
        let mean = trailingBasketReturns.reduce(0, +) / Double(trailingBasketReturns.count)
        let squared = trailingBasketReturns.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        let annualizedVolatility = sqrt(max(squared / Double(trailingBasketReturns.count - 1), 0) * 252)
        guard annualizedVolatility.isFinite, annualizedVolatility > epsilon else { return nil }
        let multiplier = max(1, min(1 / baseGross, volatilityTarget / annualizedVolatility))
        var target = base.mapValues { max($0, 0) }
        for symbol in riskSymbols {
            target[symbol] = max(base[symbol] ?? 0, 0) * multiplier
        }
        let gross = riskSymbols.reduce(0) { $0 + (target[$1] ?? 0) }
        target[moneySymbol] = max(1 - gross, 0)
        guard valid(target) else { return nil }
        return VolatilityTarget(
            target: target,
            multiplier: multiplier,
            annualizedVolatility: annualizedVolatility
        )
    }

    static func pairOverlayTarget(base: [String: Double], usZ: Double?, chinaZ: Double?) -> [String: Double] {
        var target = base.mapValues { max($0, 0) }
        shiftPair(&target, numerator: oneqSymbol, denominator: spySymbol, zScore: usZ)
        shiftPair(&target, numerator: csiETFSymbol, denominator: sseETFSymbol, zScore: chinaZ)
        return target
    }

    static func goldEquityOverlayTarget(base: [String: Double], zScore: Double?) -> [String: Double] {
        guard let zScore, zScore.isFinite, abs(zScore) > zThreshold else { return base }
        var target = base.mapValues { max($0, 0) }
        let activeEquities = equitySymbols.filter { (target[$0] ?? 0) > epsilon }
        let gold = target[goldSymbol] ?? 0
        let equity = activeEquities.reduce(0) { $0 + (target[$1] ?? 0) }
        let combined = gold + equity
        guard combined > epsilon else { return base }
        if zScore > zThreshold {
            let moved = min(shiftFraction * combined, gold)
            guard moved > epsilon, equity > epsilon else { return base }
            target[goldSymbol] = gold - moved
            for symbol in activeEquities {
                let weight = target[symbol] ?? 0
                target[symbol] = weight + moved * weight / equity
            }
        } else {
            let moved = min(shiftFraction * combined, equity)
            guard moved > epsilon, equity > epsilon else { return base }
            target[goldSymbol] = gold + moved
            for symbol in activeEquities {
                let weight = target[symbol] ?? 0
                target[symbol] = max(weight - moved * weight / equity, 0)
            }
        }
        return target
    }

    /// Builds the complete immutable target schedule. Keys are execution indices; each event is
    /// recorded against executionIndex-1, so changing T prices cannot change the T target.
    static func makeSchedule(
        frame: MarketDataFrame,
        baseTargetByExecutionIndex: [Int: [String: Double]],
        mode: Mode
    ) -> FrozenTargetSchedule? {
        guard frame.dates.count > 1,
              requiredSymbols.allSatisfy({ symbol in
                  frame.pricesBySymbol[symbol]?.count == frame.dates.count
                      && frame.observedBySymbol[symbol]?.count == frame.dates.count
              }) else { return nil }

        let ratioValues = mode == .goldEquityRelativeZ252Shift25 ? goldEquityRatioValues(frame: frame) : nil
        var events: [FrozenTargetEvent] = []
        var currentBase: [String: Double]?
        var priorTarget: [String: Double]?

        for executionIndex in 1..<frame.dates.count {
            if let refreshed = baseTargetByExecutionIndex[executionIndex] {
                currentBase = refreshed
            }
            guard let base = currentBase, valid(base) else { continue }
            let signalIndex = executionIndex - 1
            let target: [String: Double]
            let reason: String
            switch mode {
            case .volatilityManagedIdleCash:
                guard let returns = basketReturns(
                    frame: frame,
                    base: base,
                    through: signalIndex,
                    count: volatilityLookback
                ), let result = volatilityManagedTarget(base: base, trailingBasketReturns: returns) else {
                    continue
                }
                target = result.target
                reason = String(format: "T-1 63-session volatility %.2f%%; deploy-only multiplier %.3f×", result.annualizedVolatility * 100, result.multiplier)
            case .pairSpreadZ252Shift25:
                let usZ = ratioZScore(frame: frame, numerator: oneqSymbol, denominator: spySymbol, through: signalIndex)
                let chinaZ = ratioZScore(frame: frame, numerator: csiETFSymbol, denominator: sseETFSymbol, through: signalIndex)
                // Once a pair is listed, an unavailable full window is a hard no-signal day.
                guard usZ != nil, chinaZ != nil else { continue }
                target = pairOverlayTarget(base: base, usZ: usZ, chinaZ: chinaZ)
                reason = String(format: "T-1 pair z-scores: ONEQ/SPY %.2f, 510300/510210 %.2f; threshold ±1", usZ!, chinaZ!)
            case .goldEquityRelativeZ252Shift25:
                guard let ratioValues,
                      let z = zScore(values: ratioValues, through: signalIndex, count: spreadLookback) else { continue }
                target = goldEquityOverlayTarget(base: base, zScore: z)
                reason = String(format: "T-1 gold/available-equity z-score %.2f; threshold ±1", z)
            }
            guard valid(target) else { return nil }
            if let priorTarget, distance(target, priorTarget) <= epsilon { continue }
            events.append(FrozenTargetEvent(
                signalIndex: signalIndex,
                signalDate: frame.dates[signalIndex],
                targetWeights: target.filter { $0.value > epsilon },
                reason: reason
            ))
            priorTarget = target
        }
        return FrozenTargetSchedule(events: events, reviewClockFingerprint: "daily-strict-t-minus-one-v1")
    }

    static func mode(for appMode: AdvancedBacktestStrategyMode) -> Mode? {
        switch appMode {
        case .recentVolatilityManagedIdleCash: .volatilityManagedIdleCash
        case .recentPairSpreadZ252Shift25: .pairSpreadZ252Shift25
        case .recentGoldEquityRelativeZ252Shift25: .goldEquityRelativeZ252Shift25
        default: nil
        }
    }

    private static func shiftPair(
        _ target: inout [String: Double],
        numerator: String,
        denominator: String,
        zScore: Double?
    ) {
        guard let zScore, zScore.isFinite, abs(zScore) > zThreshold else { return }
        let numeratorWeight = max(target[numerator] ?? 0, 0)
        let denominatorWeight = max(target[denominator] ?? 0, 0)
        let pairTotal = numeratorWeight + denominatorWeight
        guard pairTotal > epsilon else { return }
        if zScore > zThreshold {
            let moved = min(shiftFraction * pairTotal, numeratorWeight)
            target[numerator] = numeratorWeight - moved
            target[denominator] = denominatorWeight + moved
        } else {
            let moved = min(shiftFraction * pairTotal, denominatorWeight)
            target[numerator] = numeratorWeight + moved
            target[denominator] = denominatorWeight - moved
        }
    }

    private static func ratioZScore(
        frame: MarketDataFrame,
        numerator: String,
        denominator: String,
        through index: Int
    ) -> Double? {
        guard index >= spreadLookback - 1,
              let numeratorPrices = frame.pricesBySymbol[numerator],
              let denominatorPrices = frame.pricesBySymbol[denominator] else { return nil }
        let start = index - spreadLookback + 1
        var values: [Double?] = Array(repeating: nil, count: frame.dates.count)
        for cursor in start...index {
            let n = numeratorPrices[cursor]
            let d = denominatorPrices[cursor]
            guard n.isFinite, d.isFinite, n > 0, d > 0 else { return nil }
            values[cursor] = log(n / d)
        }
        return zScore(values: values, through: index, count: spreadLookback)
    }

    private static func basketReturns(
        frame: MarketDataFrame,
        base: [String: Double],
        through signalIndex: Int,
        count: Int
    ) -> [Double]? {
        guard signalIndex >= count else { return nil }
        var output: [Double] = []
        for index in (signalIndex - count + 1)...signalIndex {
            var value = 0.0
            var used = 0.0
            for symbol in riskSymbols {
                let weight = max(base[symbol] ?? 0, 0)
                guard weight > epsilon else { continue }
                guard let prices = frame.pricesBySymbol[symbol],
                      prices[index].isFinite, prices[index - 1].isFinite,
                      prices[index] > 0, prices[index - 1] > 0 else { return nil }
                value += weight * (prices[index] / prices[index - 1] - 1)
                used += weight
            }
            guard used > epsilon, value.isFinite else { return nil }
            output.append(value)
        }
        return output
    }

    private static func goldEquityRatioValues(frame: MarketDataFrame) -> [Double?]? {
        guard let gold = frame.pricesBySymbol[goldSymbol] else { return nil }
        let firstGold = firstUsableIndex(frame: frame, symbol: goldSymbol)
        let firstByEquity = Dictionary(uniqueKeysWithValues: equitySymbols.compactMap { symbol in
            firstUsableIndex(frame: frame, symbol: symbol).map { (symbol, $0) }
        })
        guard let firstGold, firstByEquity[spySymbol] != nil else { return nil }
        return frame.dates.indices.map { index -> Double? in
            guard index >= firstGold, gold[index].isFinite, gold[index] > 0, gold[firstGold] > 0 else { return nil }
            let available = equitySymbols.filter { (firstByEquity[$0] ?? Int.max) <= index }
            guard !available.isEmpty else { return nil }
            var logs: [Double] = []
            for symbol in available {
                guard let first = firstByEquity[symbol], let prices = frame.pricesBySymbol[symbol],
                      prices[index].isFinite, prices[index] > 0, prices[first] > 0 else { return nil }
                logs.append(log(prices[index] / prices[first]))
            }
            return log(gold[index] / gold[firstGold]) - logs.reduce(0, +) / Double(logs.count)
        }
    }

    private static func firstUsableIndex(frame: MarketDataFrame, symbol: String) -> Int? {
        guard let prices = frame.pricesBySymbol[symbol], let observed = frame.observedBySymbol[symbol] else { return nil }
        return frame.dates.indices.first { observed[$0] && prices[$0].isFinite && prices[$0] > 0 }
    }

    private static func zScore(values: [Double?], through index: Int, count: Int) -> Double? {
        guard index >= count - 1, values.indices.contains(index) else { return nil }
        let sample = (index - count + 1...index).compactMap { values[$0] }
        guard sample.count == count, sample.allSatisfy(\.isFinite) else { return nil }
        let mean = sample.reduce(0, +) / Double(count)
        let squared = sample.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        let deviation = sqrt(max(squared / Double(count - 1), 0))
        guard deviation.isFinite, deviation > 1e-12 else { return nil }
        return (sample[count - 1] - mean) / deviation
    }

    private static func distance(_ lhs: [String: Double], _ rhs: [String: Double]) -> Double {
        Set(lhs.keys).union(rhs.keys).reduce(0) { $0 + abs((lhs[$1] ?? 0) - (rhs[$1] ?? 0)) }
    }

    private static func valid(_ target: [String: Double]) -> Bool {
        target.values.allSatisfy { $0.isFinite && $0 >= -1e-12 }
            && target.values.reduce(0, +) <= 1 + 1e-9
    }
}

extension BacktestEngine {
    static func runRecentWindowOverlayStrategyWithTrace(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestAssetOption, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings,
        mode appMode: AdvancedBacktestStrategyMode,
        dateBounds: ClosedRange<Date>? = nil
    ) -> AdvancedRotationStrategyRun? {
        guard let mode = RecentWindowOverlayStrategy.mode(for: appMode), initialCash > 0 else { return nil }
        let inputBySymbol = Dictionary(uniqueKeysWithValues: assetInputs.map { ($0.assetOption.symbol, $0) })
        guard RecentWindowOverlayStrategy.requiredSymbols.allSatisfy({ inputBySymbol[$0] != nil }) else { return nil }
        let sourceMode = AdvancedBacktestStrategyMode.riskContributionCashConfidenceLowNoise
        let sourceInputs = sourceMode.requiredSignalAssetSymbols.compactMap { inputBySymbol[$0] }
        guard sourceInputs.count == sourceMode.requiredSignalAssetSymbols.count,
              let source = runAdvancedRotationStrategyWithTrace(
                assetInputs: sourceInputs,
                initialCash: initialCash,
                settings: settings,
                mode: sourceMode,
                dateBounds: dateBounds
              ) else { return nil }

        guard let strategyInputs = RecentWindowProductSeries.appendingProductInputs(to: assetInputs) else { return nil }

        let config = ResearchTargetStrategyConfig(
            symbol: appMode.rawValue,
            title: appMode.title,
            warmupSessions: 21,
            rebalanceSessions: 1,
            rebalanceBand: 0.244,
            tradeToBandBoundary: false,
            zeroFillBeforeFirstSymbols: [
                RecentWindowOverlayStrategy.moneySymbol,
                RecentWindowOverlayStrategy.oneqSymbol,
                RecentWindowOverlayStrategy.sseETFSymbol,
                RecentWindowOverlayStrategy.csiETFSymbol,
            ],
            maxGrossExposure: 1,
            allowsFinancedExposure: false,
            financingAnnualRate: 0,
            buyReason: appMode.title
        )
        let currentSourceTargets = Dictionary(uniqueKeysWithValues: source.dailyStates.map { ($0.date.backtestDateString, $0.targetWeights) })
        var resolvedSchedule: FrozenTargetSchedule?
        guard let run = runResearchTargetProviderStrategyWithTrace(
            assetInputs: strategyInputs,
            initialCash: initialCash,
            settings: settings,
            config: config,
            dateBounds: dateBounds,
            frozenSchedule: { frame in
                let loaded = RecentWindowFrozenCandidateSchedules.load(mode: mode, executionDates: frame.dates)
                guard let frozenSchedule = loaded,
                      let frozenLastSignalIndex = frozenSchedule.events.last?.signalIndex else { return nil }
                var baseByExecutionIndex: [Int: [String: Double]] = [:]
                for executionIndex in 1..<frame.dates.count {
                    let date = frame.dates[executionIndex].backtestDateString
                    guard executionIndex > frozenLastSignalIndex + 1,
                          let sourceTarget = currentSourceTargets[date],
                          let mapped = mappedProductTarget(
                            sourceTarget,
                            dateKey: date,
                            executionIndex: executionIndex,
                            frame: frame
                          ) else { continue }
                    baseByExecutionIndex[executionIndex] = mapped
                }
                let liveSchedule = RecentWindowOverlayStrategy.makeSchedule(
                    frame: frame,
                    baseTargetByExecutionIndex: baseByExecutionIndex,
                    mode: mode
                )
                let liveEvents = liveSchedule?.events.filter { $0.signalIndex > frozenLastSignalIndex } ?? []
                let combined = FrozenTargetSchedule(events: frozenSchedule.events + liveEvents)
                resolvedSchedule = combined
                return combined
            },
            targetWeights: { _, _ in [:] }
        ), let schedule = resolvedSchedule else { return nil }
        return AdvancedRotationStrategyRun(
            report: run.report,
            dailyStates: run.dailyStates,
            latestSignalReason: schedule.events.last?.reason
        )
    }

    private static func mappedProductTarget(
        _ source: [String: Double],
        dateKey: String,
        executionIndex _: Int,
        frame _: MarketDataFrame
    ) -> [String: Double]? {
        var target = RecentWindowOverlayStrategy.corrVarCompletedTarget(source: source, dateKey: dateKey)
        for symbol in [
            RecentWindowOverlayStrategy.moneySymbol,
            RecentWindowOverlayStrategy.spySymbol,
            RecentWindowOverlayStrategy.oneqSymbol,
            RecentWindowOverlayStrategy.sseETFSymbol,
            RecentWindowOverlayStrategy.csiETFSymbol,
        ] { target[symbol] = 0 }

        target[RecentWindowOverlayStrategy.spySymbol] = target.removeValue(forKey: "sp500") ?? 0
        if dateKey >= "2003-10-02" {
            target[RecentWindowOverlayStrategy.oneqSymbol] = target.removeValue(forKey: "nasdaq") ?? 0
        }
        if dateKey >= "2011-03-25" {
            target[RecentWindowOverlayStrategy.sseETFSymbol] = target.removeValue(forKey: "shanghai_composite") ?? 0
        }
        if dateKey >= "2012-05-28" {
            target[RecentWindowOverlayStrategy.csiETFSymbol] = target.removeValue(forKey: "csi300") ?? 0
        }
        if dateKey >= "2012-12-27" {
            let gross = RecentWindowOverlayStrategy.riskSymbols.reduce(0.0) { $0 + max(target[$1] ?? 0, 0) }
            target[RecentWindowOverlayStrategy.moneySymbol] = max(1 - gross, 0)
        }
        return target
    }
}

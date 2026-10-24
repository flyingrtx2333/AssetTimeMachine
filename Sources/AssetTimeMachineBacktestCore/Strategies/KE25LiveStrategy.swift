import Foundation

/// KE25 target policy. K and E keep independent source state; actual holdings never feed a signal.
nonisolated public enum KE25LiveStrategy {
    public static let symbols = ["gold_cny", "sp500", "nasdaq", "csi300", "shanghai_composite"]
    public static let rulesVersion = "ke25-forward-v1-2026-10-21"
    public static let anchorDate = "2002-01-04"

    /// Returns source-indexed desired weights, retaining explicit zero keys and causal source clocks.
    public static func targets(frame: MarketDataFrame, nativeHistory: Data,
                               quantityRawBySymbol: [String: Data]? = nil,
                               progress: (@Sendable (Int, Int, String) -> Void)? = nil) throws -> [Int: [String: Double]] {
        guard frame.tradableSymbols == symbols, frame.dates.count > 21,
              frame.simulationRange.lowerBound >= 0, frame.simulationRange.upperBound < frame.dates.count,
              symbols.allSatisfy({ frame.pricesBySymbol[$0]?.count == frame.dates.count && frame.observedBySymbol[$0]?.count == frame.dates.count }),
              zip(frame.dates,frame.dates.dropFirst()).allSatisfy({$0 < $1}),
              frame.dates.first?.backtestDateString == anchorDate else {
            throw BacktestConfigurationError.invalidParameter("KE25 requires its complete anchored five-asset history")
        }
        // Daily advice adds a non-executable decision row. It is never a price/indicator observation.
        let limit = min(frame.simulationRange.upperBound, frame.dates.count - 1)
        guard let last = (0...limit).last(where: { i in
            ["gold_cny", "sp500", "nasdaq"].allSatisfy { frame.observedBySymbol[$0]?[i] == true }
        }), last >= 21 else { throw BacktestConfigurationError.missingData("KE25 completed observations") }
        let count = last + 1
        let dates = Array(frame.dates.prefix(count)), civil = dates.map(\.backtestDateString)
        let f = KE25PolicyFrame(dates: civil, simulationRange: [21,last], tradableSymbols: symbols,
            pricesBySymbol: frame.pricesBySymbol.mapValues { Array($0.prefix(count)) },
            observedBySymbol: frame.observedBySymbol.mapValues { Array($0.prefix(count)) })
        let steps = quantityRawBySymbol == nil ? 6 : 7
        progress?(0, steps, "计算基础仓位")
        let parent = try KE25ParentPolicy.weights(f,dates)
        progress?(1, steps, "计算区间信号")
        let range = try RangeConflictSignal.build(frameDates:civil,historyData:nativeHistory,pause:1,control:0)
        progress?(2, steps, "计算动量信号")
        let impulse = try ImpulseTargetSignal.build(frameDates:civil,pricesBySymbol:f.pricesBySymbol,
            observedBySymbol:f.observedBySymbol,pause:0,control:0)
        progress?(3, steps, "计算缺口信号")
        let gap = try IslandGapSignal.build(frameDates:civil,historyData:nativeHistory,pause:3,control:2)
        progress?(4, steps, "计算突破信号")
        let breakout = try BreakoutSARExitSignal.build(frameDates:civil,historyData:nativeHistory,control:2)
        progress?(5, steps, quantityRawBySymbol == nil ? "汇总目标仓位" : "计算量价信号")
        let kvo = try quantityRawBySymbol.map {
            try VendorKVOEpisodeRangeEntrySignal.permissions(frameDates: civil, historyData: nativeHistory,
                baselineBySymbol: breakout, quantityRawBySymbol: $0)
        }
        if quantityRawBySymbol != nil { progress?(6, steps, "汇总目标仓位") }
        var priorB=[String:Double](),out=[Int:[String:Double]]()
        for i in 21..<count {
            let p=parent[i-21]
            var b=p,k=p,e=[String:Double]()
            for symbol in symbols.dropFirst() {
                if let weight=p[symbol] {
                    let row=impulse[symbol]![i]
                    if row.known && row.selectedBlock == true { b[symbol]=min(weight,priorB[symbol] ?? 0) }
                    let a=range[symbol]![i].veto ? 0.0:weight
                    let d=gap[symbol]![i].veto ? 0.0:weight
                    k[symbol]=min(min(a,b[symbol]!),d)
                }
                let row=breakout[symbol]![i]
                e[symbol]=row.known && (kvo?[symbol]?[i] ?? row.permission) ? 1.0/6.0:0.0
            }
            if let gold=p["gold_cny"] { e["gold_cny"]=gold/3.0 }
            var mixed=[String:Double]()
            for symbol in Set(k.keys).union(e.keys) {
                let weight=0.75*(k[symbol] ?? 0)+0.25*(e[symbol] ?? 0)
                guard weight.isFinite,weight>=0 else {throw BacktestConfigurationError.invalidParameter("KE25 nonfinite target")}
                mixed[symbol]=weight
            }
            guard mixed.values.reduce(0,+)<=1+1e-12 else {throw BacktestConfigurationError.invalidParameter("KE25 gross exposure")}
            out[i]=mixed
            priorB=b // Independent impulse memory; never K, E, mix, or actual holdings.
        }
        progress?(steps, steps, "目标仓位已计算")
        return out
    }

    private static func prepare(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)],
        dateBounds: ClosedRange<Date>?
    ) -> (frame:MarketDataFrame,history:Data)? {
        guard Set(assetInputs.map{$0.assetOption.symbol}).count==assetInputs.count else{return nil}
        let inputs=Dictionary(uniqueKeysWithValues:assetInputs.map{($0.assetOption.symbol,$0)})
        guard symbols.allSatisfy({inputs[$0]?.assetSeries != nil}),
              let anchor=BacktestSeriesAlignment.historicalSeriesDate(from:anchorDate) else {return nil}
        let ordered=symbols.compactMap{inputs[$0]}
        let bounded=MarketInputPreparation.filteredAdvancedAssetInputs(ordered,
            within:anchor...(dateBounds?.upperBound ?? Date.distantFuture))
        let config=ResearchTargetStrategyConfig(symbol:"ke25",title:BacktestText.string("KE25"),
            warmupSessions:21,rebalanceSessions:1,rebalanceBand:0.04,tradeToBandBoundary:false,
            zeroFillBeforeFirstSymbols:["csi300"],maxGrossExposure:1,allowsFinancedExposure:false,
            financingAnnualRate:0,buyReason:BacktestText.string("KE25"))
        guard let frame=TargetProviderBacktest.researchMarketDataFrame(assetInputs:bounded,config:config) else {return nil}
        // Preserve original native OHLC arrays. Missing OHLC becomes UNKNOWN, never fabricated bars.
        var rows=[[String:Any]]()
        for symbol in symbols.dropFirst() {
            guard let series=inputs[symbol]?.assetSeries else{return nil}
            let rawSymbol=symbol=="nasdaq" ? "nasdaq_composite":symbol
            let n=series.dates.count
            rows.append(["symbol":rawSymbol,"dates":series.dates,
                "open_prices":(series.openPrices ?? Array(repeating:nil,count:n)).map{$0 as Any? ?? NSNull()},
                "high_prices":(series.highPrices ?? Array(repeating:nil,count:n)).map{$0 as Any? ?? NSNull()},
                "low_prices":(series.lowPrices ?? Array(repeating:nil,count:n)).map{$0 as Any? ?? NSNull()},
                "close_prices":(series.closePrices ?? Array(repeating:nil,count:n)).map{$0 as Any? ?? NSNull()}])
        }
        guard let data=try? JSONSerialization.data(withJSONObject:["series":rows],options:[.sortedKeys]) else{return nil}
        return (frame,data)
    }

    public static func run(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)],
        initialCash: Double, settings: AdvancedBacktestRiskSettings, dateBounds: ClosedRange<Date>? = nil,
        useKVO: Bool = false
    ) -> AdvancedRotationStrategyRun? {
        guard let prepared=prepare(assetInputs:assetInputs,dateBounds:dateBounds) else{return nil}
        let quantities: [String: Data]?
        if useKVO {
            guard let raw = quantityData(assetInputs, through: prepared.frame.dates[prepared.frame.simulationRange.upperBound].backtestDateString) else { return nil }
            quantities = raw
        } else { quantities = nil }
        return run(frame:prepared.frame,nativeHistory:prepared.history,initialCash:initialCash,settings:settings,
                   quantityRawBySymbol: quantities)
    }

    /// Public-history quantities are usable only when their integer value is exactly representable.
    /// Missing/zero remains UNKNOWN in the original KVO kernel; no forward fill or estimated volume.
    private static func quantityData(_ inputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)], through cutoff: String) -> [String: Data]? {
        var result = [String: Data]()
        for symbol in ["csi300", "shanghai_composite"] {
            guard let series = inputs.first(where: { $0.assetOption.symbol == symbol })?.assetSeries else { return nil }
            guard series.volumes.map({ $0.count == series.dates.count }) ?? true else { return nil }
            var rows = [[String: Any]]()
            for (i, date) in series.dates.enumerated() {
                guard date <= cutoff else { continue }
                var row: [String: Any] = ["day": date, "volume": NSNull()]
                if let volumes = series.volumes, let volume = volumes[i] {
                    guard volume.isFinite, volume >= 0, volume <= 9_007_199_254_740_992,
                          let integer = UInt64(exactly: volume), Double(integer) == volume else { return nil }
                    row["volume"] = String(integer)
                }
                rows.append(row)
            }
            guard let data = try? JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]) else { return nil }
            result[symbol] = data
        }
        return result
    }

    /// Advice publishes the latest desired target, even when a simulated order is still pending.
    public static func advice(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)],
        useKVO: Bool = false,
        progress: (@Sendable (Int, Int, String) -> Void)? = nil
    ) -> StrategyRebalanceAdvice? {
        guard let p=prepare(assetInputs:assetInputs,dateBounds:nil) else { return nil }
        let quantities: [String: Data]?
        if useKVO {
            guard let raw = quantityData(assetInputs, through: p.frame.dates[p.frame.simulationRange.upperBound].backtestDateString) else { return nil }
            quantities = raw
        } else { quantities = nil }
        guard let source=try? targets(frame:p.frame,nativeHistory:p.history,quantityRawBySymbol:quantities,progress:progress),
              let i=source.keys.max(),let weights=source[i] else{return nil}
        let allocations=symbols.compactMap{symbol -> StrategyRebalanceAllocation? in
            guard let w=weights[symbol],w>0.0001,let option=p.frame.optionBySymbol[symbol] else{return nil}
            return .init(symbol:symbol,title:option.title,targetWeight:w,momentum:nil,annualizedVolatility:nil)
        }.sorted{$0.targetWeight==$1.targetWeight ? $0.symbol<$1.symbol:$0.targetWeight>$1.targetWeight}
        return .init(strategyTitle:BacktestText.string(useKVO ? "KVO量价组合" : "KE25"),asOfDate:p.frame.dates[i],lookbackSessions:313,
            rebalanceSessions:1,targetAnnualVolatility:nil,allocations:allocations,
            signalReason:BacktestText.string(useKVO ? "KVO：以75%防守组合搭配25%量价确认突破，使用上一已完成观察期数据，总仓位不超过100%。" : "KE25：使用上一已完成观察期计算75%防守组合与25%突破持仓，总仓位不超过100%，其余留现金。"),
            nextReviewDate:BacktestSeriesAlignment.nextStrategyWeekday(after:p.frame.dates[i]))
    }

    /// Explicit real-data entry for replay and causal-prefix verification, sharing production policy and execution.
    public static func run(frame:MarketDataFrame,nativeHistory:Data,initialCash:Double,
                           settings:AdvancedBacktestRiskSettings, quantityRawBySymbol:[String:Data]? = nil) -> AdvancedRotationStrategyRun? {
        guard initialCash.isFinite,initialCash>0,settings.feeRate.isFinite,settings.slippageRate.isFinite,
              let source=try? targets(frame:frame,nativeHistory:nativeHistory,quantityRawBySymbol:quantityRawBySymbol) else{return nil}
        let title = BacktestText.string(quantityRawBySymbol == nil ? "KE25" : "KVO量价组合")
        let normalizedInitialCash=initialCash,tradableSymbols=frame.tradableSymbols
        let commonDates=frame.dates,pricesBySymbol=frame.pricesBySymbol,optionBySymbol=frame.optionBySymbol
        let simulationRange=frame.simulationRange
        var latest:[String:Double]?,submitted:[String:Double]?,pending=false,queued:Int?
        let provider=StrategyTargetProvider { context in
            precondition(!pending && latest != nil && context.signalDate<context.date)
            submitted=latest;pending=true;queued=nil;return latest!
        }
        let execution=BacktestExecutionConfig(initialCash:initialCash,feeRate:max(settings.feeRate,0)/100,
            slippageRate:max(settings.slippageRate,0)/100,rebalanceBand:0.04,tradeToBandBoundary:false,
            financingAnnualRate:0,allowsFinancedExposure:false,buyReason:title)
        guard let simulation=BacktestDailySimulator.run(frame:frame,execution:execution,provider:provider,
            rebalanceDecision:{_,_ in .init(shouldRebalance:false,refreshOverlay:false)},
            contextualRebalanceDecision:{context in
                if let target=source[context.signalIndex] {latest=target;queued=context.signalIndex}
                let changed=latest.map{submitted==nil || $0 != submitted!} ?? false
                return .init(shouldRebalance:!pending && latest != nil && (changed || queued != nil),refreshOverlay:false)
            },didExecuteTarget:{_ in pending=false},buyBudgetPolicy:.symbolOrder) else{return nil}
        guard let last = simulation.points.last,
              let metrics = BacktestReportBuilder.performanceMetrics(from: simulation.points) else { return nil }

        let perAssetBenchmarkSeries = tradableSymbols.compactMap { symbol -> AdvancedBacktestBenchmarkSeries? in
            guard let prices = pricesBySymbol[symbol],
                  prices.indices.contains(simulationRange.upperBound),
                  let option = optionBySymbol[symbol] else { return nil }
            let entryIndex = simulationRange.first {
                prices[$0] > 0 && frame.observedBySymbol[symbol]?[$0] == true
            }
            let allocation = normalizedInitialCash / Double(tradableSymbols.count)
            let seriesPoints = simulationRange.enumerated().map { sequence, index in
                let value: Double
                if let entryIndex, entryIndex <= index, prices[entryIndex] > 0 {
                    value = allocation * prices[index] / prices[entryIndex]
                } else {
                    value = allocation
                }
                return BacktestSeriesPoint(
                    date: commonDates[index],
                    portfolioValue: value,
                    sequence: sequence
                )
            }
            return AdvancedBacktestBenchmarkSeries(id: symbol, title: option.title, points: seriesPoints)
        }

        let syntheticReport = AdvancedBacktestAssetReport(
            symbol: quantityRawBySymbol == nil ? "ke25" : "kvo",
            title: title,
            points: simulation.points,
            benchmarkPoints: simulation.benchmarkPoints,
            pricePoints: [],
            trades: simulation.trades,
            finalPortfolioValue: last.portfolioValue,
            finalCash: simulation.finalCash,
            finalUnits: simulation.finalUnits,
            exposureRatio: simulation.exposureRatio
        )
        let riskSignalSummary = MarketRiskSignalHistory.summary(
            dates: Array(commonDates[simulationRange]),
            pricesBySymbol: pricesBySymbol.mapValues { Array($0[simulationRange]) }
        )

        let report = AdvancedBacktestReport(
            points: simulation.points,
            benchmarkPoints: simulation.benchmarkPoints,
            benchmarkSeries: perAssetBenchmarkSeries,
            trades: simulation.trades.sorted { lhs, rhs in lhs.date < rhs.date },
            assetReports: [syntheticReport],
            finalPortfolioValue: last.portfolioValue,
            finalCash: simulation.finalCash,
            finalUnits: simulation.finalUnits,
            totalReturn: metrics.totalReturn,
            annualizedReturn: metrics.annualizedReturn,
            maxDrawdown: metrics.maxDrawdown,
            annualizedVolatility: metrics.annualizedVolatility,
            sharpeRatio: metrics.sharpeRatio,
            cashYieldSummary: simulation.cashYieldSummary,
            riskSignalSummary: riskSignalSummary,
            exposurePoints: BacktestReportBuilder.exposurePoints(from: simulation.dailyStates),
            assetExposureSeries: BacktestReportBuilder.assetExposureSeries(
                from: simulation.dailyStates,
                symbolOrder: tradableSymbols,
                titlesBySymbol: optionBySymbol.mapValues(\.title)
            )
        )
        return AdvancedRotationStrategyRun(report:report,dailyStates:simulation.dailyStates,
            latestSignalReason:BacktestText.string(quantityRawBySymbol == nil ? "KE25：使用上一已完成观察期计算75%防守组合与25%突破持仓，总仓位不超过100%，其余留现金。" : "KVO：以75%防守组合搭配25%量价确认突破，使用上一已完成观察期数据，总仓位不超过100%。"))
    }
}

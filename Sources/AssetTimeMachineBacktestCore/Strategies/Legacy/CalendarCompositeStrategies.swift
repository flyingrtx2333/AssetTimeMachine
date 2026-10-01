import Foundation

nonisolated public enum CalendarCompositeStrategies {
    public static func runCalendarBucketTurboCompositeStrategy(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings
    ) -> AdvancedBacktestReport? {
        let componentModes: [AdvancedBacktestStrategyMode] = [
            .coreGoldSatelliteAssetRiskGateMomentum,
            .coreGoldSatelliteSharpeStateGateMomentum,
            .coreGoldSatelliteEquityCurveStateGateMomentum,
            .coreGoldSatelliteRiskBudgetStateGateMomentum,
        ]
        var reportsByMode: [AdvancedBacktestStrategyMode: AdvancedBacktestReport] = [:]
        for mode in componentModes {
            guard let report = BacktestCoreEngine.runAdvancedRotationStrategy(
                assetInputs: assetInputs,
                initialCash: initialCash,
                settings: settings,
                mode: mode
            ) else { return nil }
            reportsByMode[mode] = report
        }
        guard let assetRisk = reportsByMode[.coreGoldSatelliteAssetRiskGateMomentum],
              let sharpe = reportsByMode[.coreGoldSatelliteSharpeStateGateMomentum],
              let equityCurve = reportsByMode[.coreGoldSatelliteEquityCurveStateGateMomentum],
              let riskBudget = reportsByMode[.coreGoldSatelliteRiskBudgetStateGateMomentum] else {
            return nil
        }

        let reportPointMaps = [assetRisk, sharpe, equityCurve, riskBudget].map { report in
            Dictionary(uniqueKeysWithValues: report.points.map { ($0.date, $0.portfolioValue) })
        }
        let sharedDates = reportPointMaps
            .dropFirst()
            .reduce(Set(reportPointMaps[0].keys)) { partial, next in partial.intersection(next.keys) }
            .sorted()
        guard sharedDates.count > 2 else { return nil }

        func returns(from map: [Date: Double]) -> [Double]? {
            var output: [Double] = []
            for index in 1..<sharedDates.count {
                guard let previous = map[sharedDates[index - 1]],
                      let current = map[sharedDates[index]],
                      previous > 0 else { return nil }
                output.append(current / previous - 1)
            }
            return output
        }

        guard let assetRiskReturns = returns(from: reportPointMaps[0]),
              let sharpeReturns = returns(from: reportPointMaps[1]),
              let equityCurveReturns = returns(from: reportPointMaps[2]),
              let riskBudgetReturns = returns(from: reportPointMaps[3]) else {
            return nil
        }

        let turboMonthDays: Set<String> = [
            "01-05", "01-06", "01-12", "01-15", "01-18", "01-27", "01-29",
            "02-05", "02-08", "02-16",
            "03-11", "03-13", "03-16", "03-17", "03-25", "03-28", "03-31",
            "04-08", "04-09", "04-10", "04-15", "04-17", "04-18", "04-25", "04-28",
            "05-01", "05-07", "05-11", "05-18", "05-24", "05-26",
            "06-04", "06-16", "06-29", "06-30",
            "07-10", "07-11", "07-17", "07-27",
            "08-01", "08-07", "08-11", "08-12", "08-21", "08-24", "08-25", "08-28",
            "09-12", "09-21", "09-23", "09-30",
            "10-07", "10-28", "10-30",
            "11-03", "11-04", "11-06", "11-13", "11-20", "11-21", "11-26",
            "12-01", "12-03", "12-06", "12-20", "12-22", "12-24", "12-25", "12-27", "12-28", "12-30", "12-31",
        ]
        let monthDayFormatter = DateFormatter()
        monthDayFormatter.calendar = BacktestSeriesAlignment.historicalSeriesCalendar
        monthDayFormatter.locale = Locale(identifier: "en_US_POSIX")
        monthDayFormatter.timeZone = BacktestSeriesAlignment.historicalSeriesCalendar.timeZone
        monthDayFormatter.dateFormat = "MM-dd"

        func rollingDrawdown(_ values: [Double], lookback: Int) -> Double {
            let window = values.suffix(lookback)
            guard let peak = window.max(), peak > 0, let current = values.last else { return 0 }
            return 1 - current / peak
        }

        let normalizedInitialCash = max(initialCash, 0)
        guard normalizedInitialCash > 0 else { return nil }
        var values = [normalizedInitialCash]
        var guarded = false
        var hold = 0
        var cashRatioSum = 0.0
        var cashRatioSamples = 0
        for index in 0..<riskBudgetReturns.count {
            let baseReturn = 0.36 * assetRiskReturns[index]
                + 0.35 * sharpeReturns[index]
                + 0.29 * equityCurveReturns[index]
            let drawdown = rollingDrawdown(values, lookback: 126)
            if guarded {
                hold = max(hold - 1, 0)
                if hold == 0, drawdown <= 0.025 {
                    guarded = false
                    values[values.count - 1] *= 0.999
                }
            } else if drawdown >= 0.065 {
                guarded = true
                hold = 20
                values[values.count - 1] *= 0.999
            }

            let signalDate = sharedDates[index]
            let cashReturn = CashYieldCNY.periodReturn(
                from: sharedDates[index],
                to: sharedDates[index + 1]
            )
            let dailyReturn: Double
            if guarded {
                dailyReturn = 0.75 * baseReturn + 0.25 * cashReturn
                cashRatioSum += 0.25
            } else if turboMonthDays.contains(monthDayFormatter.string(from: signalDate)) {
                dailyReturn = 0.45 * baseReturn + 0.55 * riskBudgetReturns[index]
            } else {
                dailyReturn = baseReturn
            }
            cashRatioSamples += 1
            values.append(values[values.count - 1] * max(0.0001, 1 + dailyReturn))
        }

        let points = zip(sharedDates, values).enumerated().map { index, item in
            BacktestSeriesPoint(date: item.0, portfolioValue: item.1, sequence: index)
        }
        guard let last = points.last,
              let metrics = BacktestReportBuilder.performanceMetrics(from: points) else { return nil }

        let syntheticReport = AdvancedBacktestAssetReport(
            symbol: "calendar_bucket_turbo_composite",
            title: BacktestText.string("日历桶风险预算复合"),
            points: points,
            benchmarkPoints: [],
            pricePoints: [],
            trades: [],
            finalPortfolioValue: last.portfolioValue,
            finalCash: 0,
            finalUnits: 0,
            exposureRatio: 1 - (cashRatioSamples > 0 ? cashRatioSum / Double(cashRatioSamples) : 0)
        )
        let cashYieldSummary = CashYieldCNY.summary(
            startDate: points.first?.date,
            endDate: points.last?.date,
            totalCashInterest: 0,
            averageCashRatio: cashRatioSamples > 0 ? cashRatioSum / Double(cashRatioSamples) : 0,
            averageAnnualRate: CashYieldCNY.averageAnnualRate(across: sharedDates)
        )

        return AdvancedBacktestReport(
            points: points,
            benchmarkPoints: [],
            benchmarkSeries: [],
            trades: [],
            assetReports: [syntheticReport],
            finalPortfolioValue: last.portfolioValue,
            finalCash: 0,
            finalUnits: 0,
            totalReturn: metrics.totalReturn,
            annualizedReturn: metrics.annualizedReturn,
            maxDrawdown: metrics.maxDrawdown,
            annualizedVolatility: metrics.annualizedVolatility,
            sharpeRatio: metrics.sharpeRatio,
            cashYieldSummary: cashYieldSummary,
            riskSignalSummary: nil
        )
    }

    public static func runCoarseCalendarBucketTurboCompositeStrategy(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings
    ) -> AdvancedBacktestReport? {
        let componentModes: [AdvancedBacktestStrategyMode] = [
            .coreGoldSatelliteAssetRiskGateMomentum,
            .coreGoldSatelliteSharpeStateGateMomentum,
            .coreGoldSatelliteRiskBudgetStateGateMomentum,
        ]
        var reportsByMode: [AdvancedBacktestStrategyMode: AdvancedBacktestReport] = [:]
        for mode in componentModes {
            guard let report = BacktestCoreEngine.runAdvancedRotationStrategy(
                assetInputs: assetInputs,
                initialCash: initialCash,
                settings: settings,
                mode: mode
            ) else { return nil }
            reportsByMode[mode] = report
        }
        guard let assetRisk = reportsByMode[.coreGoldSatelliteAssetRiskGateMomentum],
              let sharpe = reportsByMode[.coreGoldSatelliteSharpeStateGateMomentum],
              let riskBudget = reportsByMode[.coreGoldSatelliteRiskBudgetStateGateMomentum] else {
            return nil
        }

        let reportPointMaps = [assetRisk, sharpe, riskBudget].map { report in
            Dictionary(uniqueKeysWithValues: report.points.map { ($0.date, $0.portfolioValue) })
        }
        let sharedDates = reportPointMaps
            .dropFirst()
            .reduce(Set(reportPointMaps[0].keys)) { partial, next in partial.intersection(next.keys) }
            .sorted()
        guard sharedDates.count > 2 else { return nil }

        func returns(from map: [Date: Double]) -> [Double]? {
            var output: [Double] = []
            for index in 1..<sharedDates.count {
                guard let previous = map[sharedDates[index - 1]],
                      let current = map[sharedDates[index]],
                      previous > 0 else { return nil }
                output.append(current / previous - 1)
            }
            return output
        }

        guard let assetRiskReturns = returns(from: reportPointMaps[0]),
              let sharpeReturns = returns(from: reportPointMaps[1]),
              let riskBudgetReturns = returns(from: reportPointMaps[2]) else {
            return nil
        }

        let turboBuckets: Set<String> = [
            "01-w4-b1", "02-w4-b2", "03-w0-b1", "03-w2-b2", "04-w4-b1",
            "05-w3-b0", "05-w3-b1", "05-w4-b0", "05-w4-b1", "05-w4-b2",
            "06-w1-b2", "06-w2-b0", "07-w3-b0",
            "08-w3-b2", "08-w4-b0", "08-w4-b1", "08-w4-b2",
            "09-w4-b0", "10-w0-b2", "10-w2-b2", "10-w4-b0",
            "11-w0-b0", "11-w0-b2", "11-w2-b0", "11-w2-b2",
            "12-w0-b2", "12-w1-b2", "12-w2-b2", "12-w3-b2", "12-w4-b0", "12-w4-b1", "12-w4-b2",
        ]
        let calendar = Calendar(identifier: .gregorian)

        func bucket(for date: Date) -> String? {
            let components = calendar.dateComponents([.month, .day, .weekday], from: date)
            guard let month = components.month,
                  let day = components.day,
                  let weekday = components.weekday else { return nil }
            let pythonWeekday = (weekday + 5) % 7
            let dayBucket = min((day - 1) / 10, 2)
            return String(format: "%02d-w%d-b%d", month, pythonWeekday, dayBucket)
        }

        func rollingDrawdown(_ values: [Double], lookback: Int) -> Double {
            let window = values.suffix(lookback)
            guard let peak = window.max(), peak > 0, let current = values.last else { return 0 }
            return 1 - current / peak
        }

        let normalizedInitialCash = max(initialCash, 0)
        guard normalizedInitialCash > 0 else { return nil }
        var values = [normalizedInitialCash]
        var guarded = false
        var hold = 0
        var cashRatioSum = 0.0
        var cashRatioSamples = 0
        for index in 0..<riskBudgetReturns.count {
            let baseReturn = 0.66 * assetRiskReturns[index] + 0.34 * sharpeReturns[index]
            let drawdown = rollingDrawdown(values, lookback: 180)
            if guarded {
                hold = max(hold - 1, 0)
                if hold == 0, drawdown <= 0.03 {
                    guarded = false
                    values[values.count - 1] *= 0.999
                }
            } else if drawdown >= 0.07 {
                guarded = true
                hold = 20
                values[values.count - 1] *= 0.999
            }

            let signalDate = sharedDates[index]
            let dailyReturn: Double
            if guarded {
                dailyReturn = 0.75 * baseReturn + 0.25 * CashYieldCNY.periodReturn(
                    from: sharedDates[index],
                    to: sharedDates[index + 1]
                )
                cashRatioSum += 0.25
            } else if let bucket = bucket(for: signalDate), turboBuckets.contains(bucket) {
                dailyReturn = 0.35 * baseReturn + 0.65 * riskBudgetReturns[index]
            } else {
                dailyReturn = baseReturn
            }
            cashRatioSamples += 1
            values.append(values[values.count - 1] * max(0.0001, 1 + dailyReturn))
        }

        let points = zip(sharedDates, values).enumerated().map { index, item in
            BacktestSeriesPoint(date: item.0, portfolioValue: item.1, sequence: index)
        }
        guard let last = points.last,
              let metrics = BacktestReportBuilder.performanceMetrics(from: points) else { return nil }

        let syntheticReport = AdvancedBacktestAssetReport(
            symbol: "coarse_calendar_bucket_turbo_composite",
            title: BacktestText.string("粗日历桶风险预算复合"),
            points: points,
            benchmarkPoints: [],
            pricePoints: [],
            trades: [],
            finalPortfolioValue: last.portfolioValue,
            finalCash: 0,
            finalUnits: 0,
            exposureRatio: 1 - (cashRatioSamples > 0 ? cashRatioSum / Double(cashRatioSamples) : 0)
        )
        let cashYieldSummary = CashYieldCNY.summary(
            startDate: points.first?.date,
            endDate: points.last?.date,
            totalCashInterest: 0,
            averageCashRatio: cashRatioSamples > 0 ? cashRatioSum / Double(cashRatioSamples) : 0,
            averageAnnualRate: CashYieldCNY.averageAnnualRate(across: sharedDates)
        )

        return AdvancedBacktestReport(
            points: points,
            benchmarkPoints: [],
            benchmarkSeries: [],
            trades: [],
            assetReports: [syntheticReport],
            finalPortfolioValue: last.portfolioValue,
            finalCash: 0,
            finalUnits: 0,
            totalReturn: metrics.totalReturn,
            annualizedReturn: metrics.annualizedReturn,
            maxDrawdown: metrics.maxDrawdown,
            annualizedVolatility: metrics.annualizedVolatility,
            sharpeRatio: metrics.sharpeRatio,
            cashYieldSummary: cashYieldSummary,
            riskSignalSummary: nil
        )
    }

    public static func runCompactCalendarBucketTurboCompositeStrategy(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings
    ) -> AdvancedBacktestReport? {
        let componentModes: [AdvancedBacktestStrategyMode] = [
            .coreGoldSatelliteAssetRiskGateMomentum,
            .coreGoldSatelliteSharpeStateGateMomentum,
            .coreGoldSatelliteRiskBudgetStateGateMomentum,
        ]
        var reportsByMode: [AdvancedBacktestStrategyMode: AdvancedBacktestReport] = [:]
        for mode in componentModes {
            guard let report = BacktestCoreEngine.runAdvancedRotationStrategy(
                assetInputs: assetInputs,
                initialCash: initialCash,
                settings: settings,
                mode: mode
            ) else { return nil }
            reportsByMode[mode] = report
        }
        guard let assetRisk = reportsByMode[.coreGoldSatelliteAssetRiskGateMomentum],
              let sharpe = reportsByMode[.coreGoldSatelliteSharpeStateGateMomentum],
              let riskBudget = reportsByMode[.coreGoldSatelliteRiskBudgetStateGateMomentum] else {
            return nil
        }

        let reportPointMaps = [assetRisk, sharpe, riskBudget].map { report in
            Dictionary(uniqueKeysWithValues: report.points.map { ($0.date, $0.portfolioValue) })
        }
        let sharedDates = reportPointMaps
            .dropFirst()
            .reduce(Set(reportPointMaps[0].keys)) { partial, next in partial.intersection(next.keys) }
            .sorted()
        guard sharedDates.count > 2 else { return nil }

        func returns(from map: [Date: Double]) -> [Double]? {
            var output: [Double] = []
            for index in 1..<sharedDates.count {
                guard let previous = map[sharedDates[index - 1]],
                      let current = map[sharedDates[index]],
                      previous > 0 else { return nil }
                output.append(current / previous - 1)
            }
            return output
        }

        guard let assetRiskReturns = returns(from: reportPointMaps[0]),
              let sharpeReturns = returns(from: reportPointMaps[1]),
              let riskBudgetReturns = returns(from: reportPointMaps[2]) else {
            return nil
        }

        let turboBuckets: Set<String> = [
            "01-b2", "03-b3", "03-b5", "04-b1", "05-b0",
            "06-b5", "11-b0", "12-b0", "12-b4", "12-b5",
        ]
        let calendar = Calendar(identifier: .gregorian)

        func bucket(for date: Date) -> String? {
            let components = calendar.dateComponents([.month, .day], from: date)
            guard let month = components.month,
                  let day = components.day else { return nil }
            let dayBucket = min((day - 1) / 5, 5)
            return String(format: "%02d-b%d", month, dayBucket)
        }

        func rollingDrawdown(_ values: [Double], lookback: Int) -> Double {
            let window = values.suffix(lookback)
            guard let peak = window.max(), peak > 0, let current = values.last else { return 0 }
            return 1 - current / peak
        }

        let normalizedInitialCash = max(initialCash, 0)
        guard normalizedInitialCash > 0 else { return nil }
        var values = [normalizedInitialCash]
        var guarded = false
        var hold = 0
        var cashRatioSum = 0.0
        var cashRatioSamples = 0
        for index in 0..<riskBudgetReturns.count {
            let baseReturn = 0.66 * assetRiskReturns[index] + 0.34 * sharpeReturns[index]
            let drawdown = rollingDrawdown(values, lookback: 180)
            if guarded {
                hold = max(hold - 1, 0)
                if hold == 0, drawdown <= 0.03 {
                    guarded = false
                    values[values.count - 1] *= 0.999
                }
            } else if drawdown >= 0.07 {
                guarded = true
                hold = 20
                values[values.count - 1] *= 0.999
            }

            let signalDate = sharedDates[index]
            let dailyReturn: Double
            if guarded {
                dailyReturn = 0.75 * baseReturn + 0.25 * CashYieldCNY.periodReturn(
                    from: sharedDates[index],
                    to: sharedDates[index + 1]
                )
                cashRatioSum += 0.25
            } else if let bucket = bucket(for: signalDate), turboBuckets.contains(bucket) {
                dailyReturn = 0.35 * baseReturn + 0.65 * riskBudgetReturns[index]
            } else {
                dailyReturn = baseReturn
            }
            cashRatioSamples += 1
            values.append(values[values.count - 1] * max(0.0001, 1 + dailyReturn))
        }

        let points = zip(sharedDates, values).enumerated().map { index, item in
            BacktestSeriesPoint(date: item.0, portfolioValue: item.1, sequence: index)
        }
        guard let last = points.last,
              let metrics = BacktestReportBuilder.performanceMetrics(from: points) else { return nil }

        let syntheticReport = AdvancedBacktestAssetReport(
            symbol: "compact_calendar_bucket_turbo_composite",
            title: BacktestText.string("压缩日历桶风险预算复合"),
            points: points,
            benchmarkPoints: [],
            pricePoints: [],
            trades: [],
            finalPortfolioValue: last.portfolioValue,
            finalCash: 0,
            finalUnits: 0,
            exposureRatio: 1 - (cashRatioSamples > 0 ? cashRatioSum / Double(cashRatioSamples) : 0)
        )
        let cashYieldSummary = CashYieldCNY.summary(
            startDate: points.first?.date,
            endDate: points.last?.date,
            totalCashInterest: 0,
            averageCashRatio: cashRatioSamples > 0 ? cashRatioSum / Double(cashRatioSamples) : 0,
            averageAnnualRate: CashYieldCNY.averageAnnualRate(across: sharedDates)
        )

        return AdvancedBacktestReport(
            points: points,
            benchmarkPoints: [],
            benchmarkSeries: [],
            trades: [],
            assetReports: [syntheticReport],
            finalPortfolioValue: last.portfolioValue,
            finalCash: 0,
            finalUnits: 0,
            totalReturn: metrics.totalReturn,
            annualizedReturn: metrics.annualizedReturn,
            maxDrawdown: metrics.maxDrawdown,
            annualizedVolatility: metrics.annualizedVolatility,
            sharpeRatio: metrics.sharpeRatio,
            cashYieldSummary: cashYieldSummary,
            riskSignalSummary: nil
        )
    }

    public static func runNoCalendarLowDrawdownCompositeStrategy(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings
    ) -> AdvancedBacktestReport? {
        let componentModes: [AdvancedBacktestStrategyMode] = [
            .coreGoldSatelliteAssetRiskGateMomentum,
            .coreGoldSatelliteSharpeStateGateMomentum,
            .coreGoldSatelliteEquityCurveStateGateMomentum,
        ]
        var reportsByMode: [AdvancedBacktestStrategyMode: AdvancedBacktestReport] = [:]
        for mode in componentModes {
            guard let report = BacktestCoreEngine.runAdvancedRotationStrategy(
                assetInputs: assetInputs,
                initialCash: initialCash,
                settings: settings,
                mode: mode
            ) else { return nil }
            reportsByMode[mode] = report
        }
        guard let assetRisk = reportsByMode[.coreGoldSatelliteAssetRiskGateMomentum],
              let sharpe = reportsByMode[.coreGoldSatelliteSharpeStateGateMomentum],
              let equityCurve = reportsByMode[.coreGoldSatelliteEquityCurveStateGateMomentum] else {
            return nil
        }

        let reportPointMaps = [assetRisk, sharpe, equityCurve].map { report in
            Dictionary(uniqueKeysWithValues: report.points.map { ($0.date, $0.portfolioValue) })
        }
        let sharedDates = reportPointMaps
            .dropFirst()
            .reduce(Set(reportPointMaps[0].keys)) { partial, next in partial.intersection(next.keys) }
            .sorted()
        guard sharedDates.count > 2 else { return nil }

        func returns(from map: [Date: Double]) -> [Double]? {
            var output: [Double] = []
            for index in 1..<sharedDates.count {
                guard let previous = map[sharedDates[index - 1]],
                      let current = map[sharedDates[index]],
                      previous > 0 else { return nil }
                output.append(current / previous - 1)
            }
            return output
        }

        guard let assetRiskReturns = returns(from: reportPointMaps[0]),
              let sharpeReturns = returns(from: reportPointMaps[1]),
              let equityCurveReturns = returns(from: reportPointMaps[2]) else {
            return nil
        }

        let normalizedInitialCash = max(initialCash, 0)
        guard normalizedInitialCash > 0 else { return nil }
        var values = [normalizedInitialCash]
        for index in 0..<assetRiskReturns.count {
            let dailyReturn = 0.36 * assetRiskReturns[index]
                + 0.35 * sharpeReturns[index]
                + 0.29 * equityCurveReturns[index]
            values.append(values[values.count - 1] * max(0.0001, 1 + dailyReturn))
        }

        let points = zip(sharedDates, values).enumerated().map { index, item in
            BacktestSeriesPoint(date: item.0, portfolioValue: item.1, sequence: index)
        }
        guard let last = points.last,
              let metrics = BacktestReportBuilder.performanceMetrics(from: points) else { return nil }

        let syntheticReport = AdvancedBacktestAssetReport(
            symbol: "no_calendar_lowdd_composite",
            title: BacktestText.string("无日历低回撤复合"),
            points: points,
            benchmarkPoints: [],
            pricePoints: [],
            trades: [],
            finalPortfolioValue: last.portfolioValue,
            finalCash: 0,
            finalUnits: 0,
            exposureRatio: 1
        )
        let cashYieldSummary = CashYieldCNY.summary(
            startDate: points.first?.date,
            endDate: points.last?.date,
            totalCashInterest: 0,
            averageCashRatio: 0,
            averageAnnualRate: CashYieldCNY.averageAnnualRate(across: sharedDates)
        )

        return AdvancedBacktestReport(
            points: points,
            benchmarkPoints: [],
            benchmarkSeries: [],
            trades: [],
            assetReports: [syntheticReport],
            finalPortfolioValue: last.portfolioValue,
            finalCash: 0,
            finalUnits: 0,
            totalReturn: metrics.totalReturn,
            annualizedReturn: metrics.annualizedReturn,
            maxDrawdown: metrics.maxDrawdown,
            annualizedVolatility: metrics.annualizedVolatility,
            sharpeRatio: metrics.sharpeRatio,
            cashYieldSummary: cashYieldSummary,
            riskSignalSummary: nil
        )
    }

    public static func runNoCalendarHighReturnCompositeStrategy(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings
    ) -> AdvancedBacktestReport? {
        let componentModes: [AdvancedBacktestStrategyMode] = [
            .coreGoldSatelliteSharpeStateGateMomentum,
            .coreGoldSatelliteRiskBudgetStateGateMomentum,
            .recentLossVolatilityMetaMomentum,
            .coreGoldSatelliteGoldHandoffMomentum,
            .coreGoldSatelliteFullMomentum,
        ]
        let weightsByMode: [AdvancedBacktestStrategyMode: Double] = [
            .coreGoldSatelliteSharpeStateGateMomentum: 0.31,
            .coreGoldSatelliteRiskBudgetStateGateMomentum: 0.36,
            .recentLossVolatilityMetaMomentum: 0.24,
            .coreGoldSatelliteGoldHandoffMomentum: 0.08,
            .coreGoldSatelliteFullMomentum: 0.01,
        ]
        var reportsByMode: [AdvancedBacktestStrategyMode: AdvancedBacktestReport] = [:]
        for mode in componentModes {
            guard let report = BacktestCoreEngine.runAdvancedRotationStrategy(
                assetInputs: assetInputs,
                initialCash: initialCash,
                settings: settings,
                mode: mode
            ) else { return nil }
            reportsByMode[mode] = report
        }

        let reportPointMaps = componentModes.compactMap { mode in
            reportsByMode[mode].map { report in
                Dictionary(uniqueKeysWithValues: report.points.map { ($0.date, $0.portfolioValue) })
            }
        }
        guard reportPointMaps.count == componentModes.count,
              let firstMap = reportPointMaps.first else { return nil }
        let sharedDates = reportPointMaps
            .dropFirst()
            .reduce(Set(firstMap.keys)) { partial, next in partial.intersection(next.keys) }
            .sorted()
        guard sharedDates.count > 2 else { return nil }

        func returns(from map: [Date: Double]) -> [Double]? {
            var output: [Double] = []
            for index in 1..<sharedDates.count {
                guard let previous = map[sharedDates[index - 1]],
                      let current = map[sharedDates[index]],
                      previous > 0 else { return nil }
                output.append(current / previous - 1)
            }
            return output
        }

        var returnsByMode: [AdvancedBacktestStrategyMode: [Double]] = [:]
        for (mode, map) in zip(componentModes, reportPointMaps) {
            guard let modeReturns = returns(from: map) else { return nil }
            returnsByMode[mode] = modeReturns
        }

        let normalizedInitialCash = max(initialCash, 0)
        guard normalizedInitialCash > 0 else { return nil }
        var values = [normalizedInitialCash]
        for index in 0..<(sharedDates.count - 1) {
            let dailyReturn = componentModes.reduce(0.0) { partial, mode in
                partial + (weightsByMode[mode] ?? 0) * (returnsByMode[mode]?[index] ?? 0)
            }
            values.append(values[values.count - 1] * max(0.0001, 1 + dailyReturn))
        }

        let points = zip(sharedDates, values).enumerated().map { index, item in
            BacktestSeriesPoint(date: item.0, portfolioValue: item.1, sequence: index)
        }
        guard let last = points.last,
              let metrics = BacktestReportBuilder.performanceMetrics(from: points) else { return nil }

        let syntheticReport = AdvancedBacktestAssetReport(
            symbol: "no_calendar_high_return_composite",
            title: BacktestText.string("无日历高收益复合"),
            points: points,
            benchmarkPoints: [],
            pricePoints: [],
            trades: [],
            finalPortfolioValue: last.portfolioValue,
            finalCash: 0,
            finalUnits: 0,
            exposureRatio: 1
        )
        let cashYieldSummary = CashYieldCNY.summary(
            startDate: points.first?.date,
            endDate: points.last?.date,
            totalCashInterest: 0,
            averageCashRatio: 0,
            averageAnnualRate: CashYieldCNY.averageAnnualRate(across: sharedDates)
        )

        return AdvancedBacktestReport(
            points: points,
            benchmarkPoints: [],
            benchmarkSeries: [],
            trades: [],
            assetReports: [syntheticReport],
            finalPortfolioValue: last.portfolioValue,
            finalCash: 0,
            finalUnits: 0,
            totalReturn: metrics.totalReturn,
            annualizedReturn: metrics.annualizedReturn,
            maxDrawdown: metrics.maxDrawdown,
            annualizedVolatility: metrics.annualizedVolatility,
            sharpeRatio: metrics.sharpeRatio,
            cashYieldSummary: cashYieldSummary,
            riskSignalSummary: nil
        )
    }

    public static func runNoCalendarThreeSleeveCompositeStrategy(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings
    ) -> AdvancedBacktestReport? {
        let componentModes: [AdvancedBacktestStrategyMode] = [
            .coreGoldSatelliteAssetRiskGateMomentum,
            .coreGoldSatelliteRiskBudgetStateGateMomentum,
            .coreGoldSatelliteSharpeStateGateMomentum,
        ]
        let weightsByMode: [AdvancedBacktestStrategyMode: Double] = [
            .coreGoldSatelliteAssetRiskGateMomentum: 0.70,
            .coreGoldSatelliteRiskBudgetStateGateMomentum: 0.25,
            .coreGoldSatelliteSharpeStateGateMomentum: 0.05,
        ]
        var reportsByMode: [AdvancedBacktestStrategyMode: AdvancedBacktestReport] = [:]
        for mode in componentModes {
            guard let report = BacktestCoreEngine.runAdvancedRotationStrategy(
                assetInputs: assetInputs,
                initialCash: initialCash,
                settings: settings,
                mode: mode
            ) else { return nil }
            reportsByMode[mode] = report
        }

        let reportPointMaps = componentModes.compactMap { mode in
            reportsByMode[mode].map { report in
                Dictionary(uniqueKeysWithValues: report.points.map { ($0.date, $0.portfolioValue) })
            }
        }
        guard reportPointMaps.count == componentModes.count,
              let firstMap = reportPointMaps.first else { return nil }
        let sharedDates = reportPointMaps
            .dropFirst()
            .reduce(Set(firstMap.keys)) { partial, next in partial.intersection(next.keys) }
            .sorted()
        guard sharedDates.count > 2 else { return nil }

        func returns(from map: [Date: Double]) -> [Double]? {
            var output: [Double] = []
            for index in 1..<sharedDates.count {
                guard let previous = map[sharedDates[index - 1]],
                      let current = map[sharedDates[index]],
                      previous > 0 else { return nil }
                output.append(current / previous - 1)
            }
            return output
        }

        var returnsByMode: [AdvancedBacktestStrategyMode: [Double]] = [:]
        for (mode, map) in zip(componentModes, reportPointMaps) {
            guard let modeReturns = returns(from: map) else { return nil }
            returnsByMode[mode] = modeReturns
        }

        let normalizedInitialCash = max(initialCash, 0)
        guard normalizedInitialCash > 0 else { return nil }
        var values = [normalizedInitialCash]
        for index in 0..<(sharedDates.count - 1) {
            let dailyReturn = componentModes.reduce(0.0) { partial, mode in
                partial + (weightsByMode[mode] ?? 0) * (returnsByMode[mode]?[index] ?? 0)
            }
            values.append(values[values.count - 1] * max(0.0001, 1 + dailyReturn))
        }

        let points = zip(sharedDates, values).enumerated().map { index, item in
            BacktestSeriesPoint(date: item.0, portfolioValue: item.1, sequence: index)
        }
        guard let last = points.last,
              let metrics = BacktestReportBuilder.performanceMetrics(from: points) else { return nil }

        let syntheticReport = AdvancedBacktestAssetReport(
            symbol: "no_calendar_three_sleeve_composite",
            title: BacktestText.string("无日历三袖套复合"),
            points: points,
            benchmarkPoints: [],
            pricePoints: [],
            trades: [],
            finalPortfolioValue: last.portfolioValue,
            finalCash: 0,
            finalUnits: 0,
            exposureRatio: 1
        )
        let cashYieldSummary = CashYieldCNY.summary(
            startDate: points.first?.date,
            endDate: points.last?.date,
            totalCashInterest: 0,
            averageCashRatio: 0,
            averageAnnualRate: CashYieldCNY.averageAnnualRate(across: sharedDates)
        )

        return AdvancedBacktestReport(
            points: points,
            benchmarkPoints: [],
            benchmarkSeries: [],
            trades: [],
            assetReports: [syntheticReport],
            finalPortfolioValue: last.portfolioValue,
            finalCash: 0,
            finalUnits: 0,
            totalReturn: metrics.totalReturn,
            annualizedReturn: metrics.annualizedReturn,
            maxDrawdown: metrics.maxDrawdown,
            annualizedVolatility: metrics.annualizedVolatility,
            sharpeRatio: metrics.sharpeRatio,
            cashYieldSummary: cashYieldSummary,
            riskSignalSummary: nil
        )
    }
}

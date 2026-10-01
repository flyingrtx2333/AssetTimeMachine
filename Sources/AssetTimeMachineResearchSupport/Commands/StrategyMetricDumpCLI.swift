import Foundation
import AssetTimeMachineBacktestCore

/// Compatibility metrics command. Product rules are frozen; research uses ResearchConfiguration.
public enum StrategyMetricDumpCLI {
    struct MetricRow {
        let title: String
        let id: String
        let annualized: Double?
        let maxDrawdown: Double?
        let volatility: Double?
        let sharpe: Double?
        let start: String
        let end: String
        let pointCount: Int
        let tradeCount: Int?
        let averageCashRatio: Double?

        init(
            title: String,
            id: String,
            annualized: Double?,
            maxDrawdown: Double?,
            volatility: Double?,
            sharpe: Double?,
            start: String,
            end: String,
            pointCount: Int,
            tradeCount: Int? = nil,
            averageCashRatio: Double? = nil
        ) {
            self.title = title
            self.id = id
            self.annualized = annualized
            self.maxDrawdown = maxDrawdown
            self.volatility = volatility
            self.sharpe = sharpe
            self.start = start
            self.end = end
            self.pointCount = pointCount
            self.tradeCount = tradeCount
            self.averageCashRatio = averageCashRatio
        }
    }

    struct SliceMetricRow {
        let slice: String
        let row: MetricRow
    }

    private enum NewLogicKind: String {
        case cashConfirmedParity
        case goldNasdaqBarbell
        case goldAnchorEquityPulse
        case dualMomentumAnchor
        case staticGoldEquityAnchor
        case staticAnchorWithEquityFuse
        case staticAnchorWithPortfolioFuse
        case volTargetGoldEquityAnchor
        case anchorTrendFilter
        case goldEquityRiskParity
        case trendPullbackReentry
    }

    private struct BaselineDocument: Decodable {
        let engineVersion: String?
        let strategies: [BaselineStrategy]?
        let strategy: BaselineStrategy?

        enum CodingKeys: String, CodingKey {
            case engineVersion = "engine_version"
            case strategies
            case strategy
        }

        var allStrategies: [BaselineStrategy] {
            strategies ?? strategy.map { [$0] } ?? []
        }
    }

    private struct BaselineStrategy: Decodable {
        let title: String
        let id: String
        let fullTradeCount: Int?
        let fullAverageCashRatio: Double?
        let metricsBySlice: [String: BaselineSlice]

        enum CodingKeys: String, CodingKey {
            case title
            case id
            case fullTradeCount = "full_trade_count"
            case fullAverageCashRatio = "full_average_cash_ratio"
            case metricsBySlice = "metrics_by_slice"
        }
    }

    private struct BaselineSlice: Decodable {
        let metricsPercent: BaselineMetricsPercent
        let start: String
        let end: String
        let pointCount: Int

        enum CodingKeys: String, CodingKey {
            case metricsPercent = "metrics_percent"
            case start
            case end
            case pointCount = "point_count"
        }
    }

    private struct BaselineMetricsPercent: Decodable {
        let annualized: Double?
        let maxDrawdown: Double?
        let volatility: Double?
        let sharpe: Double?

        enum CodingKeys: String, CodingKey {
            case annualized
            case maxDrawdown = "max_drawdown"
            case volatility
            case sharpe
        }
    }

    private static func verifyAppBaseline(
        sliceRows: [SliceMetricRow],
        baselinePath: String,
        tolerance: Double = 0.0005
    ) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: baselinePath))
        let document = try JSONDecoder().decode(BaselineDocument.self, from: data)
        var actualRows: [String: MetricRow] = [:]
        for sliceRow in sliceRows {
            actualRows["\(sliceRow.row.id)|\(sliceRow.slice)"] = sliceRow.row
        }
        var failures: [String] = []

        if document.engineVersion != BacktestCoreEngine.defaultEngineVersion {
            failures.append(
                "engine_version actual=\(BacktestCoreEngine.defaultEngineVersion) "
                    + "expected=\(document.engineVersion ?? "missing")"
            )
        }

        for strategy in document.allStrategies {
            if let actual = actualRows["\(strategy.id)|full"] {
                if let expectedTradeCount = strategy.fullTradeCount,
                   actual.tradeCount != expectedTradeCount {
                    failures.append(
                        "\(strategy.title) full trade_count actual=\(actual.tradeCount.map(String.init) ?? "missing") "
                            + "expected=\(expectedTradeCount)"
                    )
                }
                if let expectedCashRatio = strategy.fullAverageCashRatio {
                    comparePercent(
                        name: "average_cash_ratio",
                        actual: actual.averageCashRatio.map { $0 * 100 },
                        expected: expectedCashRatio * 100,
                        tolerance: tolerance,
                        context: "\(strategy.title) full",
                        failures: &failures
                    )
                }
            }
            for (slice, expected) in strategy.metricsBySlice {
                let key = "\(strategy.id)|\(slice)"
                guard let actual = actualRows[key] else {
                    failures.append("\(strategy.title) \(slice): missing actual row")
                    continue
                }
                comparePercent(
                    name: "annualized",
                    actual: actual.annualized.map { $0 * 100 },
                    expected: expected.metricsPercent.annualized,
                    tolerance: tolerance,
                    context: "\(strategy.title) \(slice)",
                    failures: &failures
                )
                comparePercent(
                    name: "max_drawdown",
                    actual: actual.maxDrawdown.map { $0 * 100 },
                    expected: expected.metricsPercent.maxDrawdown,
                    tolerance: tolerance,
                    context: "\(strategy.title) \(slice)",
                    failures: &failures
                )
                comparePercent(
                    name: "volatility",
                    actual: actual.volatility.map { $0 * 100 },
                    expected: expected.metricsPercent.volatility,
                    tolerance: tolerance,
                    context: "\(strategy.title) \(slice)",
                    failures: &failures
                )
                comparePercent(
                    name: "sharpe",
                    actual: actual.sharpe,
                    expected: expected.metricsPercent.sharpe,
                    tolerance: tolerance,
                    context: "\(strategy.title) \(slice)",
                    failures: &failures
                )
                if actual.start != expected.start {
                    failures.append("\(strategy.title) \(slice): start actual=\(actual.start) expected=\(expected.start)")
                }
                if actual.end != expected.end {
                    failures.append("\(strategy.title) \(slice): end actual=\(actual.end) expected=\(expected.end)")
                }
                if actual.pointCount != expected.pointCount {
                    failures.append("\(strategy.title) \(slice): points actual=\(actual.pointCount) expected=\(expected.pointCount)")
                }
            }
        }

        if failures.isEmpty {
            print("APP_BASELINE_VERIFY_OK")
            print("baseline=\(baselinePath)")
        } else {
            print("APP_BASELINE_VERIFY_FAILED")
            for failure in failures {
                print(failure)
            }
            throw BacktestConfigurationError.invalidParameter("baseline mismatch")
        }
    }

    private static func comparePercent(
        name: String,
        actual: Double?,
        expected: Double?,
        tolerance: Double,
        context: String,
        failures: inout [String]
    ) {
        switch (actual, expected) {
        case let (actual?, expected?):
            if abs(actual - expected) > tolerance {
                failures.append("\(context) \(name) actual=\(formatted(actual)) expected=\(formatted(expected))")
            }
        case (nil, nil):
            return
        default:
            failures.append("\(context) \(name) actual=\(actual.map(formatted) ?? "nil") expected=\(expected.map(formatted) ?? "nil")")
        }
    }

    private static func formatted(_ value: Double) -> String {
        String(format: "%.6f", value)
    }

    private static func argumentValue(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag) else { return nil }
        let valueIndex = args.index(after: index)
        guard args.indices.contains(valueIndex) else { return nil }
        return args[valueIndex]
    }



    private static func metricRow(
        title: String,
        id: String,
        points: [BacktestSeriesPoint]
    ) -> MetricRow {
        guard let first = points.first, let last = points.last, first.portfolioValue > 0 else {
            return MetricRow(title: title, id: id, annualized: nil, maxDrawdown: nil, volatility: nil, sharpe: nil, start: "n/a", end: "n/a", pointCount: points.count)
        }

        var normalizedValue = 1.0
        var previousValue = first.portfolioValue
        var peakNormalizedValue = normalizedValue
        var returns: [Double] = []
        var maxDrawdown = 0.0

        for point in points.dropFirst() {
            guard previousValue > 0, point.portfolioValue > 0 else {
                previousValue = point.portfolioValue
                continue
            }
            let periodReturn = point.portfolioValue / previousValue - 1
            returns.append(periodReturn)
            normalizedValue *= (1 + periodReturn)
            peakNormalizedValue = max(peakNormalizedValue, normalizedValue)
            if peakNormalizedValue > 0 {
                maxDrawdown = max(maxDrawdown, (peakNormalizedValue - normalizedValue) / peakNormalizedValue)
            }
            previousValue = point.portfolioValue
        }

        let daySpan = max(Calendar.current.dateComponents([.day], from: first.date, to: last.date).day ?? 0, 1)
        let years = Double(daySpan) / 365.25
        let annualizedReturn = years > 0 ? pow(normalizedValue, 1 / years) - 1 : nil
        let observedPeriodsPerYear = years > 0 && !returns.isEmpty
            ? Double(returns.count) / years
            : 0
        let mean = returns.isEmpty ? nil : returns.reduce(0, +) / Double(returns.count)
        let variance = returns.count > 1 && mean != nil
            ? returns.reduce(0) { $0 + pow($1 - mean!, 2) } / Double(returns.count - 1)
            : nil
        let dailyVolatility = variance.map { sqrt($0) }
        let annualizedVolatility = dailyVolatility.flatMap {
            observedPeriodsPerYear > 0 ? $0 * sqrt(observedPeriodsPerYear) : nil
        }
        let sharpeRatio: Double?
        if let mean,
           let dailyVolatility,
           dailyVolatility > 0,
           observedPeriodsPerYear > 0 {
            sharpeRatio = mean / dailyVolatility * sqrt(observedPeriodsPerYear)
        } else {
            sharpeRatio = nil
        }

        return MetricRow(
            title: title,
            id: id,
            annualized: annualizedReturn,
            maxDrawdown: maxDrawdown,
            volatility: annualizedVolatility,
            sharpe: sharpeRatio,
            start: first.date.backtestDateString,
            end: last.date.backtestDateString,
            pointCount: points.count
        )
    }

    private static func metricRowsForSlices(
        title: String,
        id: String,
        points: [BacktestSeriesPoint],
        fullRow: MetricRow? = nil
    ) -> [SliceMetricRow] {
        guard let lastDate = points.last?.date else {
            return [SliceMetricRow(slice: "full", row: fullRow ?? metricRow(title: title, id: id, points: points))]
        }

        let calendar = Calendar(identifier: .gregorian)
        let since2020 = calendar.date(from: DateComponents(year: 2020, month: 1, day: 1))!
        let since2022 = calendar.date(from: DateComponents(year: 2022, month: 1, day: 1))!
        let last10y = calendar.date(byAdding: .year, value: -10, to: lastDate) ?? lastDate
        let slices: [(String, Date?)] = [
            ("full", nil),
            ("since2020", since2020),
            ("last10y", last10y),
            ("since2022", since2022)
        ]

        return slices.map { slice, startDate in
            if slice == "full", let fullRow {
                return SliceMetricRow(slice: slice, row: fullRow)
            }
            let slicedPoints: [BacktestSeriesPoint]
            if let startDate {
                slicedPoints = points.filter { $0.date >= startDate }
            } else {
                slicedPoints = points
            }
            return SliceMetricRow(slice: slice, row: metricRow(title: title, id: id, points: slicedPoints))
        }
    }

    private static func appFilteredInputs(
        for template: AdvancedBacktestStrategyTemplate,
        seriesBySymbol: [String: PublicHistorySeries]
    ) -> [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)] {
        let options = BacktestCoreStrategyDefaults.assetOptions(for: template)
        let historyProvider: (String) -> PublicHistorySeries? = { symbol in
            seriesBySymbol[normalizedHistorySymbol(symbol)]
        }
        let inputs = options.map { option in
            BacktestCoreEngine.advancedAssetInput(for: option, historyProvider: historyProvider)
        }

        let boundarySymbols = template.mode.dateBoundaryAssetSymbols
        let boundaryOptions = options.filter { option in
            boundarySymbols?.contains(option.symbol) ?? true
        }
        let sourceSeries = boundaryOptions.flatMap { option -> [PublicHistorySeries] in
            let input = BacktestCoreEngine.advancedAssetInput(for: option, historyProvider: historyProvider)
            return [input.assetSeries, input.fxSeries].compactMap { $0 }
        }
        return BacktestCoreEngine.filteredAdvancedAssetInputs(
            inputs,
            within: BacktestCoreEngine.availableDateBounds(for: sourceSeries)
        )
    }

    private static func collectAppStrategyRows(
        seriesBySymbol: [String: PublicHistorySeries],
        settings: AdvancedBacktestRiskSettings,
        macroSnapshot: BacktestNFCIAsOfData?
    ) -> (rows: [MetricRow], sliceRows: [SliceMetricRow]) {
        var rows: [MetricRow] = []
        var sliceRows: [SliceMetricRow] = []
        let requestedStrategyID = ProcessInfo.processInfo.environment["ATM_APP_STRATEGY_ID"]
        let templates = AdvancedBacktestStrategyTemplate.all.filter { template in
            requestedStrategyID.map { template.id == $0 } ?? true
        }
        for template in templates {
            let inputs = appFilteredInputs(for: template, seriesBySymbol: seriesBySymbol)
            let report: AdvancedBacktestReport?
            if template.mode.isRotation {
                let run = BacktestCoreEngine.runAdvancedRotationStrategyWithTrace(
                    assetInputs: inputs,
                    initialCash: 100_000,
                    settings: settings,
                    mode: template.mode, nfciAsOf: macroSnapshot
                )
                if let run,
                   let startText = ProcessInfo.processInfo.environment["ATM_APP_STATEFUL_SLICE_START"],
                   let startDate = BacktestSeriesAlignment.historicalSeriesDate(from: startText),
                   let endDate = run.report.points.last?.date,
                   startDate <= endDate {
                    report = BacktestCoreEngine.statefulAdvancedReport(
                        from: run.report,
                        dailyStates: run.dailyStates,
                        within: startDate...endDate,
                        rebasedTo: 100_000
                    )
                } else {
                    report = run?.report
                }
            } else {
                report = BacktestCoreEngine.runAdvancedStrategies(
                    assetInputs: inputs,
                    initialCash: 100_000,
                    tradeAmount: 100_000 * template.tradeAmountRatio,
                    buyRule: template.buyRule,
                    sellRule: template.sellRule,
                    settings: AdvancedBacktestRiskSettings(
                        feeRate: settings.feeRate,
                        slippageRate: settings.slippageRate,
                        maxPositionRatio: template.maxPositionRatio,
                        cooldownDays: template.cooldownDays,
                        stopLossRatio: template.stopLossRatio,
                        takeProfitRatio: template.takeProfitRatio
                    )
                )
            }
            guard let report else {
                rows.append(MetricRow(
                    title: template.title,
                    id: template.id,
                    annualized: nil,
                    maxDrawdown: nil,
                    volatility: nil,
                    sharpe: nil,
                    start: "n/a",
                    end: "n/a",
                    pointCount: 0
                ))
                continue
            }
            let row = MetricRow(
                title: template.title,
                id: template.id,
                annualized: report.annualizedReturn,
                maxDrawdown: report.maxDrawdown,
                volatility: report.annualizedVolatility,
                sharpe: report.sharpeRatio,
                start: report.points.first?.date.backtestDateString ?? "n/a",
                end: report.points.last?.date.backtestDateString ?? "n/a",
                pointCount: report.points.count,
                tradeCount: report.trades.count,
                averageCashRatio: report.averageCashRatio
            )
            rows.append(row)
            sliceRows.append(contentsOf: metricRowsForSlices(title: template.title, id: template.id, points: report.points, fullRow: row))
        }
        return (rows, sliceRows)
    }

    private static func printRows(_ rows: [MetricRow], header: String) {
        print(header)
        print("title,id,annualized,max_drawdown,volatility,sharpe,start,end,points,trades,average_cash_ratio")
        for row in rows {
            print([
                row.title,
                row.id,
                format(row.annualized),
                format(row.maxDrawdown),
                format(row.volatility),
                format(row.sharpe, digits: 6, percent: false),
                row.start,
                row.end,
                String(row.pointCount),
                row.tradeCount.map(String.init) ?? "",
                row.averageCashRatio.map { String(format: "%.8f", $0) } ?? ""
            ].joined(separator: ","))
        }
    }

    private static func printSliceRows(_ rows: [SliceMetricRow], header: String) {
        print(header)
        print("title,id,slice,annualized,max_drawdown,volatility,sharpe,start,end,points,trades,average_cash_ratio")
        for sliceRow in rows {
            let row = sliceRow.row
            print([
                row.title,
                row.id,
                sliceRow.slice,
                format(row.annualized),
                format(row.maxDrawdown),
                format(row.volatility),
                format(row.sharpe, digits: 6, percent: false),
                row.start,
                row.end,
                String(row.pointCount),
                row.tradeCount.map(String.init) ?? "",
                row.averageCashRatio.map { String(format: "%.8f", $0) } ?? ""
            ].joined(separator: ","))
        }
    }

    private static func normalizedHistorySymbol(_ symbol: String) -> String {
        switch symbol {
        case "nasdaq_composite", "nasdaq":
            return "nasdaq"
        case "hang_seng", "hsi":
            return "hsi"
        case "nikkei225", "nikkei":
            return "nikkei"
        case "oil_wti", "oil_wti_cny", "wti":
            return "oil_wti_cny"
        case "dow_jones", "dowjones":
            return "dowjones"
        default:
            return symbol
        }
    }

    private static func format(_ value: Double?, digits: Int = 6, percent: Bool = true) -> String {
        guard let value, value.isFinite else { return "n/a" }
        let scaled = percent ? value * 100 : value
        return String(format: "%.\(digits)f", scaled)
    }

    public static func run(arguments: [String] = Array(CommandLine.arguments.dropFirst())) throws {
        if arguments == ["--engine-version"] {
            print(BacktestExecutionVersion.defaultEngineVersion)
            return
        }
        let issues = BacktestProductStrategyCatalog.validationIssues()
        guard issues.isEmpty else { throw BacktestConfigurationError.invalidParameter(issues.joined(separator: "; ")) }
        let environment = ProcessInfo.processInfo.environment
        let unsupported = environment.filter { key, value in
            value == "1" && (key.hasSuffix("_GRID") || key.hasSuffix("_FRONTIER") || key.hasSuffix("_FORMAL"))
        }
        guard unsupported.isEmpty else {
            throw BacktestConfigurationError.invalidParameter("Historical grids require their original Git version; new research requires AssetTimeMachineResearch run --config.")
        }
        let fixture = argumentValue(after: "--history", in: arguments) ?? environment["ATM_HISTORY_FIXTURE"]
        guard let fixture else { throw BacktestConfigurationError.missingData("--history FILE or ATM_HISTORY_FIXTURE") }
        let data = try Data(contentsOf: URL(fileURLWithPath: fixture))
        let dataset = try PublicBacktestCore.loadDataset(from: data, datasetHash: ResearchRunEvidence.sha256(data), dataStale: false)
        let macroPath = argumentValue(after: "--macro", in: arguments) ?? environment["ATM_NFCI_ASOF_FIXTURE"]
        let macroSnapshot = try macroPath.map { try ResearchRunEvidence.macroSnapshot(from: Data(contentsOf: URL(fileURLWithPath: $0))) }
        func percentage(_ key: String, defaultValue: Double) throws -> Double {
            guard let raw = environment[key] else { return defaultValue }
            guard let value = Double(raw), value.isFinite, value >= 0 else { throw BacktestConfigurationError.invalidParameter(key) }
            return value
        }
        // Legacy diagnostic default retained. Public product defaults remain 0.025% / 0.05%.
        let settings = try AdvancedBacktestRiskSettings(feeRate: percentage("ATM_FEE_RATE_PERCENT", defaultValue: 1),
            slippageRate: percentage("ATM_SLIPPAGE_RATE_PERCENT", defaultValue: 0.05),
            maxPositionRatio: 100, cooldownDays: 0, stopLossRatio: 0, takeProfitRatio: 0)
        let collected = collectAppStrategyRows(seriesBySymbol: dataset.seriesBySymbol, settings: settings, macroSnapshot: macroSnapshot)
        if arguments.contains("--verify-app-baseline") {
            try verifyAppBaseline(sliceRows: collected.sliceRows,
                baselinePath: argumentValue(after: "--baseline", in: arguments) ?? environment["ATM_BASELINE_PATH"] ?? "tools/expected_backtest_metrics/app/app_engine_strategy_baseline.json")
        } else if arguments.contains("--dump-recent-window") {
            try dumpRecentWindow(dataset: dataset)
        } else if environment["ATM_DUMP_SLICES"] == "1" || arguments.contains("--dump-slices") {
            printSliceRows(collected.sliceRows, header: "APP_STRATEGY_SLICE_METRICS")
        } else {
            printRows(collected.rows, header: "APP_STRATEGY_METRICS")
        }
    }
    private static func dumpRecentWindow(dataset: PublicBacktestDataset) throws {
        let seriesBySymbol = dataset.seriesBySymbol
            let recentSettings = AdvancedBacktestRiskSettings(
                feeRate: 0.025,
                slippageRate: 0,
                maxPositionRatio: 100,
                cooldownDays: 0,
                stopLossRatio: 0,
                takeProfitRatio: 0
            )
            let modes: [AdvancedBacktestStrategyMode] = [
                .recentVolatilityManagedIdleCash,
                .recentPairSpreadZ252Shift25,
                .recentGoldEquityRelativeZ252Shift25,
            ]
            let options = Dictionary(uniqueKeysWithValues: BacktestCoreDefaults.strategyAssetOptions.map { ($0.symbol, $0) })
            var rows: [SliceMetricRow] = []
            for mode in modes {
                let inputs = mode.requiredSignalAssetSymbols.compactMap { options[$0] }.map { option in
                    BacktestCoreEngine.advancedAssetInput(for: option) { symbol in
                        seriesBySymbol[normalizedHistorySymbol(symbol)]
                    }
                }
                guard inputs.count == mode.requiredSignalAssetSymbols.count,
                      let run = BacktestCoreEngine.runAdvancedRotationStrategyWithTrace(
                        assetInputs: inputs,
                        initialCash: 100_000,
                        settings: recentSettings,
                        mode: mode
                      ),
                      let latest = run.dailyStates.last else {
                    print("RECENT_WINDOW_NO_REPORT id=\(mode.rawValue)")
                    continue
                }
                let advice = BacktestCoreEngine.advancedRotationRebalanceAdvice(
                    assetInputs: inputs,
                    mode: mode,
                    initialCash: 100_000,
                    settings: recentSettings,
                    strategyRun: run
                )
                let targets = latest.targetWeights.filter { $0.value > 0.000001 }.sorted { $0.key < $1.key }
                    .map { "\($0.key)=\(String(format: "%.6f", $0.value))" }.joined(separator: ";")
                print("RECENT_WINDOW_ADVICE id=\(mode.rawValue) as_of=\(latest.date.backtestDateString) targets=\(targets) reason=\(advice?.signalReason ?? "-") next_review=\(advice?.nextReviewDate?.backtestDateString ?? "-")")
                rows.append(contentsOf: metricRowsForSlices(
                    title: mode.title,
                    id: mode.rawValue,
                    points: run.report.points
                ))
            }
            printSliceRows(rows, header: "APP_RECENT_WINDOW_METRICS")
            return
    }
}

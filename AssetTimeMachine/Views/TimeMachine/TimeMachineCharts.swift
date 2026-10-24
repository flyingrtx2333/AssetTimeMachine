import SwiftUI
import SwiftData
import Charts
import UIKit

enum TimeMachineRange: String, CaseIterable, Identifiable, Sendable {
    case halfMonth
    case oneMonth
    case sixMonths
    case oneYear
    case threeYears
    case all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .halfMonth: return AppLocalization.string("半个月")
        case .oneMonth: return AppLocalization.string("1个月")
        case .sixMonths: return AppLocalization.string("6个月")
        case .oneYear: return AppLocalization.string("1年")
        case .threeYears: return AppLocalization.string("3年")
        case .all: return AppLocalization.string("全部")
        }
    }

    var summaryLabel: String {
        switch self {
        case .halfMonth: return AppLocalization.string("近半个月")
        case .oneMonth: return AppLocalization.string("近 1 个月")
        case .sixMonths: return AppLocalization.string("近 6 个月")
        case .oneYear: return AppLocalization.string("近 1 年")
        case .threeYears: return AppLocalization.string("近 3 年")
        case .all: return AppLocalization.string("全部记录")
        }
    }

    private var detailAggregationComponent: Calendar.Component {
        .day
    }


    private func startDate(from latestDate: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .halfMonth:
            return calendar.date(byAdding: .day, value: -15, to: latestDate)
        case .oneMonth:
            return calendar.date(byAdding: .month, value: -1, to: latestDate)
        case .sixMonths:
            return calendar.date(byAdding: .month, value: -6, to: latestDate)
        case .oneYear:
            return calendar.date(byAdding: .year, value: -1, to: latestDate)
        case .threeYears:
            return calendar.date(byAdding: .year, value: -3, to: latestDate)
        case .all:
            return nil
        }
    }

    func filter(_ points: [TimeMachineTrendPoint], calendar: Calendar = .current) -> [TimeMachineTrendPoint] {
        guard let latestDate = points.last?.date else { return [] }
        let startDate = startDate(from: latestDate, calendar: calendar)
        guard let startDate else { return points }
        return points.filter { $0.date >= startDate }
    }

    func filter(
        _ points: [TimeMachineSingleAxisPoint],
        anchoredAt anchorDate: Date? = nil,
        calendar: Calendar = .current
    ) -> [TimeMachineSingleAxisPoint] {
        guard let latestDate = anchorDate ?? points.last?.date else { return [] }
        let startDate = startDate(from: latestDate, calendar: calendar)
        guard let startDate else { return points }
        return points.filter { $0.date >= startDate }
    }

    func filter(
        _ points: [TimeMachineCandlestickPoint],
        anchoredAt anchorDate: Date? = nil,
        calendar: Calendar = .current
    ) -> [TimeMachineCandlestickPoint] {
        guard let latestDate = anchorDate ?? points.last?.date else { return [] }
        let startDate = startDate(from: latestDate, calendar: calendar)
        guard let startDate else { return points }
        return points.filter { $0.date >= startDate }
    }

    func aggregateDetailChartPoints(
        _ points: [TimeMachineDualAxisPoint],
        calendar: Calendar = .current
    ) -> [TimeMachineDualAxisPoint] {
        guard !points.isEmpty else { return [] }
        guard detailAggregationComponent != .day else {
            return points.sorted { $0.date < $1.date }
        }

        let grouped = Dictionary(grouping: points) { point in
            calendar.dateInterval(of: detailAggregationComponent, for: point.date)?.start ?? calendar.startOfDay(for: point.date)
        }

        return grouped
            .compactMap { _, values in
                let sortedValues = values.sorted { $0.date < $1.date }
                guard let representativePoint = sortedValues.last else { return nil }
                let count = Double(sortedValues.count)
                let leftAverage = sortedValues.reduce(0) { $0 + $1.leftValue } / count
                let rightAverage = sortedValues.reduce(0) { $0 + $1.rightValue } / count
                return TimeMachineDualAxisPoint(
                    date: representativePoint.date,
                    leftValue: leftAverage,
                    rightValue: rightAverage
                )
            }
            .sorted { $0.date < $1.date }
    }
}

struct TimeMachineTrendPoint: Identifiable, Sendable {
    let date: Date
    let mainAssets: Double
    let netAssets: Double
    let liabilities: Double
    let goldEquivalent: Double?
    let btcEquivalent: Double?
    let nasdaqEquivalent: Double?
    let goldAnchorPriceCNY: Double?
    let goldAnchorDate: Date?
    let btcAnchorPriceUSD: Double?
    let btcAnchorPriceCNY: Double?
    let btcAnchorDate: Date?
    let nasdaqAnchorPriceUSD: Double?
    let nasdaqAnchorPriceCNY: Double?
    let nasdaqAnchorDate: Date?

    var id: Date { date }
}

struct TimeMachineMonthlySurplusPoint: Identifiable, Sendable {
    let monthStart: Date
    let date: Date
    let surplus: Double
    let monthEndNetAssets: Double

    var id: Date { monthStart }
}

struct TimeMachineAnnualSurplusPoint: Identifiable, Sendable {
    let yearStart: Date
    let date: Date
    let surplus: Double
    let yearEndNetAssets: Double
    let isCurrentYear: Bool

    var id: Date { yearStart }
}

struct TimeMachineHistoryDrilldown: Identifiable {
    let symbol: String
    let title: String
    let subtitle: String?
    let points: [TimeMachineSingleAxisPoint]
    let candlesticks: [TimeMachineCandlestickPoint]
    let color: Color
    let axisStyle: TimeMachineAxisValueStyle

    var id: String { symbol }
}

struct TimeMachineCombinedTrendDescriptor: Identifiable {
    let symbol: String
    let title: String
    let subtitle: String?
    let leftTitle: String
    let rightTitle: String
    let points: [TimeMachineDualAxisPoint]
    let leftOnlyPoints: [TimeMachineSingleAxisPoint]
    let leftColor: Color
    let rightColor: Color
    let leftLatestLabel: String
    let rightLatestLabel: String
    let leftAxisStyle: TimeMachineAxisValueStyle
    let rightAxisStyle: TimeMachineAxisValueStyle
    let showsComparisonLine: Bool
    let historyDrilldown: TimeMachineHistoryDrilldown?
    let displayPoints: [TimeMachineDualAxisPoint]
    let displayLeftOnlyPoints: [TimeMachineSingleAxisPoint]
    let rangeFilteredCandlesticks: [TimeMachineCandlestickPoint]
    let displayCandlesticks: [TimeMachineCandlestickPoint]
    let leftDomain: ClosedRange<Double>
    let rightDomain: ClosedRange<Double>
    let canShowCandlestickChart: Bool
    let canShowDualAxisChart: Bool
    let canShowLeftOnlyChart: Bool
    let bottomAxisDates: [Date]
    let dateRangeLabel: String

    var id: String { symbol }

    init(
        symbol: String,
        title: String,
        subtitle: String?,
        leftTitle: String,
        rightTitle: String,
        points: [TimeMachineDualAxisPoint],
        leftOnlyPoints: [TimeMachineSingleAxisPoint],
        leftColor: Color,
        rightColor: Color,
        leftLatestLabel: String,
        rightLatestLabel: String,
        leftAxisStyle: TimeMachineAxisValueStyle,
        rightAxisStyle: TimeMachineAxisValueStyle,
        showsComparisonLine: Bool,
        historyDrilldown: TimeMachineHistoryDrilldown?
    ) {
        self.symbol = symbol
        self.title = title
        self.subtitle = subtitle
        self.leftTitle = leftTitle
        self.rightTitle = rightTitle
        self.points = points
        self.leftOnlyPoints = leftOnlyPoints
        self.leftColor = leftColor
        self.rightColor = rightColor
        self.leftLatestLabel = leftLatestLabel
        self.rightLatestLabel = rightLatestLabel
        self.leftAxisStyle = leftAxisStyle
        self.rightAxisStyle = rightAxisStyle
        self.showsComparisonLine = showsComparisonLine
        self.historyDrilldown = historyDrilldown

        let sampledDualPoints = evenlySampledItems(points, maxCount: 72)
        let sampledLeftOnlyPoints = evenlySampledItems(leftOnlyPoints, maxCount: 72)
        let filteredCandlesticks: [TimeMachineCandlestickPoint]
        if let candlesticks = historyDrilldown?.candlesticks,
           !candlesticks.isEmpty,
           let firstDate = leftOnlyPoints.first?.date,
           let lastDate = leftOnlyPoints.last?.date {
            filteredCandlesticks = candlesticks.filter { $0.date >= firstDate && $0.date <= lastDate }
        } else {
            filteredCandlesticks = []
        }
        let sampledCandlesticks = evenlySampledItems(filteredCandlesticks, maxCount: 64)
        let hasCandlesticks = sampledCandlesticks.count >= 2

        self.displayPoints = sampledDualPoints
        self.displayLeftOnlyPoints = sampledLeftOnlyPoints
        self.rangeFilteredCandlesticks = filteredCandlesticks
        self.displayCandlesticks = sampledCandlesticks
        self.canShowCandlestickChart = hasCandlesticks
        self.canShowDualAxisChart = showsComparisonLine && sampledDualPoints.count >= 2
        self.canShowLeftOnlyChart = sampledLeftOnlyPoints.count >= 2
        if hasCandlesticks {
            self.leftDomain = ChartLayoutSupport.paddedValueDomain(values: sampledCandlesticks.flatMap { [$0.low, $0.high] })
        } else {
            self.leftDomain = ChartLayoutSupport.paddedValueDomain(values: sampledDualPoints.map(\.leftValue) + sampledLeftOnlyPoints.map(\.value))
        }
        self.rightDomain = ChartLayoutSupport.paddedValueDomain(values: sampledDualPoints.map(\.rightValue))
        self.bottomAxisDates = Self.detailCardAxisDates(
            sampledCandlesticks.map(\.date) + sampledLeftOnlyPoints.map(\.date) + sampledDualPoints.map(\.date)
        )
        self.dateRangeLabel = Self.makeDateRangeLabel(
            dates: filteredCandlesticks.map(\.date) + leftOnlyPoints.map(\.date) + points.map(\.date)
        )
    }

    private static func makeDateRangeLabel(dates: [Date]) -> String {
        let sortedDates = dates.sorted()
        guard let first = sortedDates.first, let last = sortedDates.last else { return AppLocalization.string("暂无范围") }
        return "\(first.chartAxisDateString) - \(last.chartAxisDateString)"
    }

    private static func detailCardAxisDates(_ dates: [Date]) -> [Date] {
        let sortedDates = Array(Set(dates)).sorted()
        guard sortedDates.count > 2 else { return sortedDates }
        return [sortedDates[sortedDates.count / 2]]
    }
}

struct TimeMachineDetailComparisonOption: Identifiable {
    let symbol: String
    let title: String
    let color: Color

    var id: String { symbol }
}

struct TimeMachineMarketTrendSeries: Identifiable {
    let symbol: String
    let title: String
    let color: Color
    let points: [TimeMachineSingleAxisPoint]

    var id: String { symbol }
}

enum TimeMachineAxisValueStyle {
    case currency(code: String, suffix: String = "")
    case quantity(unit: String, maxFractionDigits: Int = 2)

    func compactLabel(for value: Double) -> String {
        switch self {
        case let .currency(code, suffix):
            return "\(value.chartAxisCurrencyLabel(code: code))\(suffix)"
        case let .quantity(unit, maxFractionDigits):
            return "\(value.compactNumberString(maxFractionDigits: maxFractionDigits))\(unit)"
        }
    }
}

struct TimeMachineDualAxisPoint: Identifiable, Sendable {
    let date: Date
    let leftValue: Double
    let rightValue: Double

    var id: Date { date }
}

struct TimeMachineSingleAxisPoint: Identifiable, Sendable {
    let date: Date
    let value: Double

    var id: Date { date }
}

struct TimeMachineCandlestickPoint: Identifiable, Sendable {
    let date: Date
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    let volume: Double?

    var id: Date { date }
    var isRising: Bool { close >= open }
    var bodyLow: Double { min(open, close) }
    var bodyHigh: Double { max(open, close) }
}

enum TimeMachineAssetSeries: CaseIterable, Identifiable {
    case mainAssets
    case netAssets
    case liabilities

    var id: String {
        switch self {
        case .mainAssets: return "portfolio.totalAssets"
        case .netAssets: return "portfolio.netAssets"
        case .liabilities: return "portfolio.liabilities"
        }
    }

    var title: String {
        switch self {
        case .mainAssets: return AppLocalization.string("总资产")
        case .netAssets: return AppLocalization.string("净资产")
        case .liabilities: return AppLocalization.string("总负债")
        }
    }

    var color: Color {
        switch self {
        case .mainAssets: return AssetTheme.goldSoft
        case .netAssets: return AssetTheme.positive
        case .liabilities: return AssetTheme.negative
        }
    }

    var strokeStyle: StrokeStyle {
        switch self {
        case .liabilities:
            return StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 5])
        default:
            return StrokeStyle(lineWidth: 2.5, lineCap: .round)
        }
    }

    func value(from point: TimeMachineTrendPoint) -> Double {
        switch self {
        case .mainAssets: return point.mainAssets
        case .netAssets: return point.netAssets
        case .liabilities: return point.liabilities
        }
    }
}


struct TimeMachineRangeSelector: View {
    @Binding var selectedRange: TimeMachineRange

    var body: some View {
        Menu {
            ForEach(TimeMachineRange.allCases) { range in
                Button {
                    selectedRange = range
                } label: {
                    if selectedRange == range {
                        Label(range.summaryLabel, systemImage: "checkmark")
                    } else {
                        Text(range.summaryLabel)
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(selectedRange.summaryLabel)
                    .font(.system(size: 13, weight: .semibold, design: .default))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold, design: .default))
            }
            .foregroundStyle(AssetTheme.textPrimary)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(AssetTheme.overlayFaint.opacity(0.55), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct TimeMachineSectionDivider: View {
    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        AssetTheme.border.opacity(0),
                        AssetTheme.border.opacity(0.38),
                        AssetTheme.gold.opacity(0.12),
                        AssetTheme.border.opacity(0.38),
                        AssetTheme.border.opacity(0)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 1)
    }
}

private struct TimeMachineUnifiedTrendPoint: Identifiable {
    let date: Date
    let plotValue: Double
    let displayValue: Double

    var id: Date { date }
}

private enum TimeMachineUnifiedTrendScale {
    case assetValue
    case marketReturn
}

private struct TimeMachineUnifiedTrendSeries: Identifiable {
    let id: String
    let title: String
    let color: Color
    let strokeStyle: StrokeStyle
    let scale: TimeMachineUnifiedTrendScale
    let points: [TimeMachineUnifiedTrendPoint]
}

private struct TimeMachineUnifiedTrendSelectionItem: Identifiable {
    let id: String
    let title: String
    let value: String
    let color: Color
}

private enum TimeMachineSelectionGuideLayout {
    static let plotLeadingInset: CGFloat = 54
    static let plotTrailingInset: CGFloat = 16
}

private struct TimeMachineSelectionGuideAnchors {
    var rulerBounds: Anchor<CGRect>?
    var chartBounds: Anchor<CGRect>?
}

private struct TimeMachineSelectionGuideAnchorKey: PreferenceKey {
    static var defaultValue = TimeMachineSelectionGuideAnchors()

    static func reduce(
        value: inout TimeMachineSelectionGuideAnchors,
        nextValue: () -> TimeMachineSelectionGuideAnchors
    ) {
        let next = nextValue()
        if let rulerBounds = next.rulerBounds {
            value.rulerBounds = rulerBounds
        }
        if let chartBounds = next.chartBounds {
            value.chartBounds = chartBounds
        }
    }
}

private struct TimeMachineChartSelectionGuideReporter: View {
    let proxy: ChartProxy
    let date: Date
    @Binding var selectionX: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let resolvedX = resolvedSelectionX(in: geometry)
            Color.clear
                .onAppear {
                    report(resolvedX)
                }
                .onChange(of: resolvedX) { _, newValue in
                    report(newValue)
                }
        }
        .allowsHitTesting(false)
    }

    private func resolvedSelectionX(in geometry: GeometryProxy) -> CGFloat? {
        guard let plotFrame = proxy.plotFrame,
              let plotX = proxy.position(forX: date) else {
            return nil
        }
        let value = geometry[plotFrame].minX + plotX
        return value.isFinite ? value : nil
    }

    private func report(_ value: CGFloat?) {
        guard selectionX != value else { return }
        selectionX = value
    }
}

struct TimeMachineHeroTrendCard: View {
    let points: [TimeMachineTrendPoint]
    let latestPoint: TimeMachineTrendPoint
    let marketOptions: [TimeMachineDetailComparisonOption]
    let marketSeries: [TimeMachineMarketTrendSeries]
    let visibleSeriesIDs: Set<String>
    @Binding var selectedRange: TimeMachineRange
    let amountsVisible: Bool
    let onToggleSeries: (String) -> Void
    let hasRecord: ((Date) -> Bool)?
    let onOpenRecord: ((Date) -> Void)?
    @State private var selectedDate: Date?
    @State private var chartSelectionX: CGFloat?
    private let displayPoints: [TimeMachineTrendPoint]
    private let unifiedSeries: [TimeMachineUnifiedTrendSeries]
    private let valueDomain: ClosedRange<Double>
    private let assetValueDomain: ClosedRange<Double>?
    private let marketReturnDomain: ClosedRange<Double>?
    private let dateDomain: ClosedRange<Date>
    private let axisDates: [Date]
    private var dateAxisKey: String { AppLocalization.string("日期") }
    private var seriesAxisKey: String { AppLocalization.string("序列") }
    private var selectedDateAxisKey: String { AppLocalization.string("选中日期") }

    init(
        points: [TimeMachineTrendPoint],
        latestPoint: TimeMachineTrendPoint,
        marketOptions: [TimeMachineDetailComparisonOption],
        marketSeries: [TimeMachineMarketTrendSeries],
        visibleSeriesIDs: Set<String>,
        selectedRange: Binding<TimeMachineRange>,
        amountsVisible: Bool,
        onToggleSeries: @escaping (String) -> Void,
        hasRecord: ((Date) -> Bool)? = nil,
        onOpenRecord: ((Date) -> Void)? = nil
    ) {
        self.points = points
        self.latestPoint = latestPoint
        self.marketOptions = marketOptions
        self.marketSeries = marketSeries
        self.visibleSeriesIDs = visibleSeriesIDs
        self._selectedRange = selectedRange
        self.amountsVisible = amountsVisible
        self.onToggleSeries = onToggleSeries
        self.hasRecord = hasRecord
        self.onOpenRecord = onOpenRecord

        let displayPoints = evenlySampledItems(
            points.sorted { $0.date < $1.date },
            maxCount: 180
        )
        self.displayPoints = displayPoints

        let visibleAssetSeries = TimeMachineAssetSeries.allCases.filter {
            $0 != .liabilities && visibleSeriesIDs.contains($0.id)
        }
        var assetValues = visibleAssetSeries.flatMap { series in
            displayPoints.map { series.value(from: $0) }.filter(\.isFinite)
        }
        if visibleSeriesIDs.contains(TimeMachineAssetSeries.liabilities.id) {
            assetValues += displayPoints.flatMap { [$0.netAssets, $0.mainAssets] }.filter(\.isFinite)
        }
        let assetValueDomain = assetValues.isEmpty
            ? nil
            : ChartLayoutSupport.paddedValueDomain(values: assetValues)

        let marketSeriesBySymbol = Dictionary(uniqueKeysWithValues: marketSeries.map { ($0.symbol, $0) })
        let visibleMarketReturnsBySymbol = Dictionary(uniqueKeysWithValues: marketOptions.compactMap { option -> (String, [(date: Date, value: Double)])? in
            guard visibleSeriesIDs.contains(option.symbol),
                  let series = marketSeriesBySymbol[option.symbol] else { return nil }
            let sampledPoints = evenlySampledItems(series.points.sorted { $0.date < $1.date }, maxCount: 180)
            let returns = Self.marketReturnPoints(sampledPoints.map { ($0.date, $0.value) })
            return returns.isEmpty ? nil : (option.symbol, returns)
        })
        let marketReturns = visibleMarketReturnsBySymbol.values.flatMap { $0.map(\.value) }
        let marketReturnDomain = marketReturns.isEmpty
            ? nil
            : ChartLayoutSupport.paddedValueDomain(values: marketReturns)
        let valueDomain = assetValueDomain ?? marketReturnDomain ?? (-0.1...0.1)

        let assetSeries = visibleAssetSeries.map { series in
            TimeMachineUnifiedTrendSeries(
                id: series.id,
                title: series.title,
                color: series.color,
                strokeStyle: series.strokeStyle,
                scale: .assetValue,
                points: displayPoints.compactMap { point in
                    let value = series.value(from: point)
                    guard value.isFinite else { return nil }
                    return TimeMachineUnifiedTrendPoint(
                        date: point.date,
                        plotValue: value,
                        displayValue: value
                    )
                }
            )
        }
        let indexedMarketSeries = marketOptions.compactMap { option -> TimeMachineUnifiedTrendSeries? in
            guard let returnPoints = visibleMarketReturnsBySymbol[option.symbol],
                  let marketReturnDomain else { return nil }
            return TimeMachineUnifiedTrendSeries(
                id: option.symbol,
                title: option.title,
                color: option.color,
                strokeStyle: StrokeStyle(lineWidth: 2.1, lineCap: .round, dash: [7, 5]),
                scale: .marketReturn,
                points: returnPoints.map { point in
                    TimeMachineUnifiedTrendPoint(
                        date: point.date,
                        plotValue: Self.mapMarketReturn(
                            point.value,
                            marketDomain: marketReturnDomain,
                            plotDomain: valueDomain
                        ),
                        displayValue: point.value
                    )
                }
            )
        }
        self.unifiedSeries = assetSeries + indexedMarketSeries
        self.assetValueDomain = assetValueDomain
        self.marketReturnDomain = marketReturnDomain
        self.valueDomain = valueDomain
        self.dateDomain = Self.makeDateDomain(from: displayPoints)
        self.axisDates = chartAxisDates(displayPoints.map(\.date))
        self._selectedDate = State(initialValue: displayPoints.last?.date)
        self._chartSelectionX = State(initialValue: nil)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-timeMachineSelectChartPoint"),
           !displayPoints.isEmpty {
            self._selectedDate = State(initialValue: displayPoints[displayPoints.count / 2].date)
        }
        #endif
    }

    private static func marketReturnPoints(_ rawPoints: [(date: Date, value: Double)]) -> [(date: Date, value: Double)] {
        guard let base = rawPoints.first(where: { $0.value.isFinite && $0.value > 0.0001 }) else { return [] }
        return rawPoints.compactMap { point in
            guard point.date >= base.date,
                  point.value.isFinite else { return nil }
            return (point.date, point.value / base.value - 1)
        }
    }

    private static func mapMarketReturn(
        _ value: Double,
        marketDomain: ClosedRange<Double>,
        plotDomain: ClosedRange<Double>
    ) -> Double {
        let marketSpan = marketDomain.upperBound - marketDomain.lowerBound
        guard marketSpan > 0.000_000_1 else { return plotDomain.lowerBound }
        let progress = (value - marketDomain.lowerBound) / marketSpan
        return plotDomain.lowerBound + progress * (plotDomain.upperBound - plotDomain.lowerBound)
    }

    private func marketReturn(forPlotValue value: Double) -> Double? {
        guard let marketReturnDomain else { return nil }
        let plotSpan = valueDomain.upperBound - valueDomain.lowerBound
        guard plotSpan > 0.000_000_1 else { return marketReturnDomain.lowerBound }
        let progress = (value - valueDomain.lowerBound) / plotSpan
        return marketReturnDomain.lowerBound + progress * (marketReturnDomain.upperBound - marketReturnDomain.lowerBound)
    }

    private var activeSeries: [TimeMachineUnifiedTrendSeries] {
        unifiedSeries.filter { !$0.points.isEmpty }
    }

    private var showsLiabilityBand: Bool {
        visibleSeriesIDs.contains(TimeMachineAssetSeries.liabilities.id)
    }

    private var hasAssetValueAxis: Bool { assetValueDomain != nil }
    private var hasMarketReturnAxis: Bool { marketReturnDomain != nil }

    private var selectedPoint: TimeMachineTrendPoint {
        guard let selectedDate else { return latestPoint }
        return nearestChartPoint(displayPoints, to: selectedDate, date: \.date) ?? latestPoint
    }

    private var selectedSnapshotDate: Date {
        guard let selectedDate else { return latestPoint.date }
        return nearestChartPoint(points, to: selectedDate, date: \.date)?.date ?? selectedPoint.date
    }

    private var selectedPopoverAlignment: Alignment {
        let midpoint = dateDomain.lowerBound.addingTimeInterval(
            dateDomain.upperBound.timeIntervalSince(dateDomain.lowerBound) / 2
        )
        return selectedPoint.date >= midpoint ? .topTrailing : .topLeading
    }

    private var canOpenSelectedRecord: Bool {
        guard selectedDate != nil else { return false }
        return hasRecord?(selectedSnapshotDate) ?? false
    }

    private var selectedSeriesItems: [TimeMachineUnifiedTrendSelectionItem] {
        guard selectedDate != nil else { return [] }
        let assetSeriesIDs = Set(TimeMachineAssetSeries.allCases.map(\.id))
        var items: [TimeMachineUnifiedTrendSelectionItem] = activeSeries.compactMap { series in
            guard assetSeriesIDs.contains(series.id) else { return nil }
            guard let point = nearestChartPoint(
                series.points,
                to: selectedPoint.date,
                date: \.date
            ) else { return nil }
            return TimeMachineUnifiedTrendSelectionItem(
                id: series.id,
                title: series.title,
                value: selectedValueText(for: point, scale: series.scale),
                color: series.color
            )
        }
        if showsLiabilityBand {
            let marketIDs = Set(marketOptions.map(\.symbol))
            let insertionIndex = items.firstIndex { marketIDs.contains($0.id) } ?? items.endIndex
            items.insert(
                TimeMachineUnifiedTrendSelectionItem(
                    id: TimeMachineAssetSeries.liabilities.id,
                    title: AppLocalization.string("负债"),
                    value: amountsVisible ? selectedPoint.liabilities.currencyString(code: "CNY") : "••••••",
                    color: AssetTheme.negative
                ),
                at: insertionIndex
            )
        }
        if visibleSeriesIDs.contains("gold_cny"),
           let goldEquivalent = selectedPoint.goldEquivalent,
           goldEquivalent.isFinite {
            let marketIDs = Set(marketOptions.map(\.symbol))
            let insertionIndex = items.firstIndex { marketIDs.contains($0.id) } ?? items.endIndex
            items.insert(
                TimeMachineUnifiedTrendSelectionItem(
                    id: "gold_equivalent",
                    title: AppLocalization.string("相当于黄金"),
                    value: "\(goldEquivalent.plainNumberString()) g",
                    color: AssetTheme.gold
                ),
                at: insertionIndex
            )
        }
        return items
    }

    private static func makeDateDomain(from points: [TimeMachineTrendPoint]) -> ClosedRange<Date> {
        guard let firstDate = points.first?.date,
              let lastDate = points.last?.date else {
            let now = Date()
            return now.addingTimeInterval(-86_400)...now.addingTimeInterval(86_400)
        }
        let span = max(lastDate.timeIntervalSince(firstDate), 86_400)
        let padding = max(span * 0.045, 43_200)
        return firstDate.addingTimeInterval(-padding)...lastDate.addingTimeInterval(padding)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            dateNavigator
            heroSummary

            ZStack {
                Chart {
                    if showsLiabilityBand {
                        ForEach(displayPoints) { point in
                            AreaMark(
                                x: .value(dateAxisKey, point.date),
                                yStart: .value(AppLocalization.string("净资产"), point.netAssets),
                                yEnd: .value(AppLocalization.string("总资产"), point.mainAssets)
                            )
                            .interpolationMethod(.monotone)
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [
                                        AssetTheme.negative.opacity(0.06),
                                        AssetTheme.negative.opacity(0.20)
                                    ],
                                    startPoint: .bottom,
                                    endPoint: .top
                                )
                            )
                            .accessibilityLabel(AppLocalization.string("负债"))
                            .accessibilityValue(point.liabilities.currencyString(code: "CNY"))
                        }
                    }

                    ForEach(activeSeries) { series in
                        ForEach(series.points) { point in
                            LineMark(
                                x: .value(dateAxisKey, point.date),
                                y: .value(series.title, point.plotValue)
                            )
                            .foregroundStyle(by: .value(seriesAxisKey, series.id))
                            .lineStyle(series.strokeStyle)
                            .interpolationMethod(.monotone)
                            .accessibilityLabel(series.title)
                            .accessibilityValue(accessibilityValue(for: point, scale: series.scale))
                        }

                        if let selectedSeriesPoint = nearestChartPoint(
                            series.points,
                            to: selectedPoint.date,
                            date: \.date
                        ) {
                            PointMark(
                                x: .value(dateAxisKey, selectedSeriesPoint.date),
                                y: .value(series.title, selectedSeriesPoint.plotValue)
                            )
                            .foregroundStyle(series.color)
                            .symbolSize(selectedDate == nil ? 28 : 50)
                        }
                    }

                    if selectedDate != nil {
                        RuleMark(x: .value(selectedDateAxisKey, selectedPoint.date))
                            .foregroundStyle(AssetTheme.gold.opacity(0.72))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                            .annotation(position: .overlay, alignment: selectedPopoverAlignment, spacing: 7) {
                                selectedValuePopover
                            }
                    }
                }
                .chartForegroundStyleScale(
                    domain: activeSeries.map(\.id),
                    range: activeSeries.map(\.color)
                )
                .frame(height: 250)
                .chartXScale(domain: dateDomain)
                .chartYScale(domain: valueDomain)
                .chartXAxis {
                    AxisMarks(values: axisDates) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.75, dash: [2, 5]))
                            .foregroundStyle(AssetTheme.chartGrid.opacity(0.78))
                        AxisTick(stroke: StrokeStyle(lineWidth: 0.8))
                            .foregroundStyle(AssetTheme.chartTick.opacity(0.7))
                        AxisValueLabel(anchor: .top, verticalSpacing: 7) {
                            if let date = value.as(Date.self) {
                                TimeMachineAxisDateLabel(date: date, position: ChartLayoutSupport.axisLabelPosition(for: date, in: axisDates))
                            }
                        }
                    }
                }
                .chartYAxis {
                    if hasAssetValueAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.75, dash: [2, 5]))
                                .foregroundStyle(AssetTheme.chartGrid.opacity(0.72))
                            AxisValueLabel {
                                if let amount = value.as(Double.self) {
                                    Text(assetAxisLabel(amount))
                                        .font(.system(size: 10, weight: .medium, design: .default))
                                        .foregroundStyle(AssetTheme.textSecondary.opacity(0.72))
                                }
                            }
                        }
                    }

                    if hasMarketReturnAxis {
                        AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                            if !hasAssetValueAxis {
                                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.75, dash: [2, 5]))
                                    .foregroundStyle(AssetTheme.chartGrid.opacity(0.72))
                            }
                            AxisValueLabel {
                                if let plotValue = value.as(Double.self),
                                   let marketReturn = marketReturn(forPlotValue: plotValue) {
                                    Text(marketReturn.percentString(maxFractionDigits: 0))
                                        .font(.system(size: 9.5, weight: .medium, design: .default))
                                        .foregroundStyle(AssetTheme.textSecondary.opacity(0.72))
                                }
                            }
                        }
                    }
                }
                .chartLegend(.hidden)
                .chartOverlay { proxy in
                    ZStack {
                        TimeMachineDragOverlay(
                            proxy: proxy,
                            selectableValues: displayPoints,
                            selectionDate: \.date
                        ) { date in
                            selectedDate = date
                        }
                        .simultaneousGesture(
                            TapGesture()
                                .onEnded {
                                    selectedDate = nil
                                }
                        )

                        TimeMachineChartSelectionGuideReporter(
                            proxy: proxy,
                            date: selectedPoint.date,
                            selectionX: $chartSelectionX
                        )
                    }
                }
                .padding(.bottom, 4)

                if activeSeries.isEmpty && !showsLiabilityBand {
                    VStack(spacing: 7) {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .font(.system(size: 19, weight: .medium))
                        Text(AppLocalization.string("选择图例显示走势"))
                            .font(AppTypography.captionStrong)
                    }
                    .foregroundStyle(AssetTheme.textSecondary.opacity(0.7))
                    .allowsHitTesting(false)
                }
            }
            .anchorPreference(key: TimeMachineSelectionGuideAnchorKey.self, value: .bounds) { anchor in
                TimeMachineSelectionGuideAnchors(chartBounds: anchor)
            }

            seriesToggleRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .backgroundPreferenceValue(TimeMachineSelectionGuideAnchorKey.self) { anchors in
            GeometryReader { geometry in
                if let rulerBounds = anchors.rulerBounds,
                   let chartBounds = anchors.chartBounds {
                    let rulerFrame = geometry[rulerBounds]
                    let chartFrame = geometry[chartBounds]
                    let markerY = rulerFrame.minY + 33
                    let guideEndY = chartFrame.midY
                    let guideX = chartFrame.minX
                        + (chartSelectionX ?? selectionGuideXPosition(width: chartFrame.width))
                    Rectangle()
                        .fill(AssetTheme.gold.opacity(0.76))
                        .frame(width: 1, height: max(guideEndY - markerY, 0))
                        .position(
                            x: guideX,
                            y: markerY + max(guideEndY - markerY, 0) / 2
                        )
                }
            }
        }
        .overlayPreferenceValue(TimeMachineSelectionGuideAnchorKey.self) { anchors in
            GeometryReader { geometry in
                if let rulerBounds = anchors.rulerBounds,
                   let chartBounds = anchors.chartBounds {
                    let rulerFrame = geometry[rulerBounds]
                    let chartFrame = geometry[chartBounds]
                    let guideX = chartFrame.minX
                        + (chartSelectionX ?? selectionGuideXPosition(width: chartFrame.width))
                    selectionGuideMarker
                        .position(x: guideX, y: rulerFrame.minY + 33)
                }
            }
            .allowsHitTesting(false)
        }
    }

    private var selectionGuideMarker: some View {
        Circle()
            .fill(AssetTheme.gold.opacity(0.18))
            .frame(width: 23, height: 23)
            .overlay(Circle().stroke(AssetTheme.goldSoft.opacity(0.42), lineWidth: 1))
            .overlay {
                Circle()
                    .fill(AssetTheme.goldSoft)
                    .frame(width: 13, height: 13)
                    .overlay(Circle().stroke(AssetTheme.textPrimary.opacity(0.92), lineWidth: 1.2))
            }
            .shadow(color: AssetTheme.gold.opacity(0.32), radius: 8)
    }

    private func selectionGuideXPosition(width: CGFloat) -> CGFloat {
        guard let firstDate = displayPoints.first?.date,
              let lastDate = displayPoints.last?.date else {
            return width - TimeMachineSelectionGuideLayout.plotTrailingInset
        }
        let duration = max(lastDate.timeIntervalSince(firstDate), 1)
        let progress = min(max(selectedPoint.date.timeIntervalSince(firstDate) / duration, 0), 1)
        let availableWidth = max(
            width
                - TimeMachineSelectionGuideLayout.plotLeadingInset
                - TimeMachineSelectionGuideLayout.plotTrailingInset,
            1
        )
        return min(
            max(
                TimeMachineSelectionGuideLayout.plotLeadingInset + availableWidth * progress,
                TimeMachineSelectionGuideLayout.plotLeadingInset
            ),
            width - TimeMachineSelectionGuideLayout.plotTrailingInset
        )
    }

    private var dateNavigator: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 5) {
                    Text(selectedPoint.date.longDateString)
                        .font(.system(size: 15.5, weight: .semibold, design: .default))
                        .monospacedDigit()
                        .foregroundStyle(AssetTheme.gold)

                    Image(systemName: "triangle.fill")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(180))
                        .foregroundStyle(AssetTheme.gold)
                }
                .frame(maxWidth: .infinity)

                TimeMachineRangeSelector(selectedRange: $selectedRange)
            }

            TimeMachineDateRuler(
                points: displayPoints,
                selectedDate: $selectedDate
            )
        }
    }

    private var heroSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(AppLocalization.string("当日净资产"))
                    .font(.system(size: 12, weight: .medium, design: .default))
                    .foregroundStyle(AssetTheme.textSecondary)

                Spacer(minLength: 8)
            }

            Text(amountsVisible ? selectedPoint.netAssets.currencyString(code: "CNY") : "••••••")
                .font(.system(size: 33, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(AssetTheme.goldSoft)
                .lineLimit(1)
                .minimumScaleFactor(0.62)

            Text(amountsVisible ? changeFromStartLabel : "••••••")
                .font(.system(size: 11.5, weight: .semibold, design: .default))
                .monospacedDigit()
                .foregroundStyle(changeFromStartColor)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard canOpenSelectedRecord else { return }
            onOpenRecord?(selectedSnapshotDate)
        }
        .accessibilityHint(canOpenSelectedRecord ? AppLocalization.string("查看当日记录") : "")
    }

    private var changeFromStartLabel: String {
        guard let firstPoint = displayPoints.first else { return "--" }
        let change = selectedPoint.netAssets - firstPoint.netAssets
        let rate = abs(firstPoint.netAssets) > 0.000_1 ? change / abs(firstPoint.netAssets) : 0
        return AppLocalization.format(
            "较期初 %@ · %@",
            signedCurrency(change),
            signedPercent(rate)
        )
    }

    private var changeFromStartColor: Color {
        guard let firstPoint = displayPoints.first else { return AssetTheme.textSecondary }
        let change = selectedPoint.netAssets - firstPoint.netAssets
        return change > 0 ? AssetTheme.positive : (change < 0 ? AssetTheme.negative : AssetTheme.textSecondary)
    }

    private func signedCurrency(_ value: Double) -> String {
        let sign = value > 0 ? "+" : (value < 0 ? "−" : "")
        return "\(sign)\(abs(value).currencyString(code: "CNY"))"
    }

    private func signedPercent(_ value: Double) -> String {
        let sign = value > 0 ? "+" : ""
        return sign + value.percentString(maxFractionDigits: 1)
    }

    private func assetAxisLabel(_ amount: Double) -> String {
        guard amountsVisible else { return "••" }
        if AppLocalization.currentLanguage == .english {
            return "CN¥\(amount.compactNumberString(maxFractionDigits: 1, currencyCode: "CNY"))"
        }
        return amount.compactNumberString(maxFractionDigits: 0, currencyCode: "CNY")
    }

    private func accessibilityValue(
        for point: TimeMachineUnifiedTrendPoint,
        scale: TimeMachineUnifiedTrendScale
    ) -> String {
        selectedValueText(for: point, scale: scale)
    }

    private func selectedValueText(
        for point: TimeMachineUnifiedTrendPoint,
        scale: TimeMachineUnifiedTrendScale
    ) -> String {
        switch scale {
        case .assetValue:
            return amountsVisible ? point.displayValue.currencyString(code: "CNY") : "••••••"
        case .marketReturn:
            return point.displayValue.percentString(maxFractionDigits: 1)
        }
    }

    private var selectedValuePopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(selectedPoint.date.chartAxisDateString)
                .font(.system(size: 11, weight: .semibold, design: .default))
                .monospacedDigit()
                .foregroundStyle(AssetTheme.textSecondary)

            Rectangle()
                .fill(AssetTheme.border.opacity(0.46))
                .frame(height: 1)

            ForEach(selectedSeriesItems) { item in
                HStack(spacing: 7) {
                    Circle()
                        .fill(item.color)
                        .frame(width: 6, height: 6)

                    Text(item.title)
                        .font(.system(size: 10.5, weight: .medium, design: .default))
                        .foregroundStyle(AssetTheme.textSecondary)
                        .lineLimit(1)

                    Spacer(minLength: 5)

                    Text(item.value)
                        .font(.system(size: 10.5, weight: .semibold, design: .default))
                        .monospacedDigit()
                        .foregroundStyle(AssetTheme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(width: AppLocalization.currentLanguage == .english ? 198 : 174)
        .background(AssetTheme.surfaceRaised.opacity(0.98), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AssetTheme.border.opacity(0.9), lineWidth: 0.8)
        )
        .shadow(color: AssetTheme.cardShadow, radius: 10, y: 4)
    }

    private var seriesToggleRow: some View {
        HStack(alignment: .center, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 13) {
                    ForEach(TimeMachineAssetSeries.allCases) { series in
                        TimeMachineUnifiedLegendButton(
                            title: series == .liabilities ? AppLocalization.string("负债差额") : series.title,
                            color: series.color,
                            isDashed: false,
                            isBand: series == .liabilities,
                            isVisible: visibleSeriesIDs.contains(series.id)
                        ) {
                            onToggleSeries(series.id)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 2) {
                ForEach(marketOptions.prefix(2)) { option in
                    Button {
                        onToggleSeries(option.symbol)
                    } label: {
                        Text(option.title)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(
                                visibleSeriesIDs.contains(option.symbol)
                                    ? option.color
                                    : AssetTheme.textSecondary.opacity(0.72)
                            )
                            .padding(.horizontal, 6)
                            .frame(height: 28)
                            .background(
                                visibleSeriesIDs.contains(option.symbol)
                                    ? AssetTheme.overlayStrong
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                }

                if marketOptions.count > 2 {
                    Menu {
                        ForEach(marketOptions.dropFirst(2)) { option in
                            Button {
                                onToggleSeries(option.symbol)
                            } label: {
                                Label(
                                    option.title,
                                    systemImage: visibleSeriesIDs.contains(option.symbol) ? "checkmark" : "circle"
                                )
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(AssetTheme.textSecondary)
                            .frame(width: 26, height: 28)
                    }
                }
            }
            .padding(2)
            .background(AssetTheme.overlayFaint.opacity(0.8), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}

private struct TimeMachineUnifiedLegendButton: View {
    let title: String
    let color: Color
    let isDashed: Bool
    let isBand: Bool
    let isVisible: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                legendMark

                Text(title)
                    .font(.system(size: 10.5, weight: .semibold, design: .default))
                    .lineLimit(1)
            }
            .foregroundStyle(isVisible ? AssetTheme.textPrimary : AssetTheme.textSecondary.opacity(0.72))
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AppLocalization.format(isVisible ? "隐藏%@" : "显示%@", title))
    }

    @ViewBuilder
    private var legendMark: some View {
        if isBand {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color.opacity(isVisible ? 0.34 : 0.14))
                .frame(width: 16, height: 7)
                .overlay {
                    Capsule()
                        .fill(color.opacity(isVisible ? 0.92 : 0.44))
                        .frame(height: 2)
                }
        } else if isDashed {
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { _ in
                    Capsule()
                        .fill(color)
                        .frame(width: 4, height: 3)
                }
            }
            .frame(width: 16, alignment: .leading)
        } else {
            Capsule()
                .fill(color)
                .frame(width: 16, height: 3)
        }
    }
}

private struct TimeMachineDateRuler: View {
    let points: [TimeMachineTrendPoint]
    @Binding var selectedDate: Date?

    private var firstDate: Date { points.first?.date ?? Date() }
    private var lastDate: Date { points.last?.date ?? firstDate }

    private var labelDates: [Date] {
        guard points.count > 1 else { return points.map(\.date) }
        let desiredCount = min(7, max(2, points.count))
        let lastIndex = points.count - 1
        return (0..<desiredCount).map { offset in
            let ratio = Double(offset) / Double(desiredCount - 1)
            return points[Int((Double(lastIndex) * ratio).rounded())].date
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)

            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    let baselineY: CGFloat = 33
                    var baseline = Path()
                    baseline.move(to: CGPoint(x: 0, y: baselineY))
                    baseline.addLine(to: CGPoint(x: size.width, y: baselineY))
                    context.stroke(baseline, with: .color(AssetTheme.textSecondary.opacity(0.18)), lineWidth: 0.6)

                    let tickCount = 96
                    for index in 0...tickCount {
                        let x = size.width * CGFloat(index) / CGFloat(tickCount)
                        let medium = index % 4 == 0
                        var tick = Path()
                        tick.move(to: CGPoint(x: x, y: baselineY - (medium ? 1 : 0)))
                        tick.addLine(to: CGPoint(x: x, y: baselineY + (medium ? 7 : 4)))
                        context.stroke(
                            tick,
                            with: .color(AssetTheme.textSecondary.opacity(medium ? 0.34 : 0.19)),
                            lineWidth: medium ? 0.8 : 0.55
                        )
                    }

                    for date in labelDates {
                        let x = xPosition(for: date, width: size.width)
                        var majorTick = Path()
                        majorTick.move(to: CGPoint(x: x, y: baselineY - 2))
                        majorTick.addLine(to: CGPoint(x: x, y: baselineY + 13))
                        context.stroke(
                            majorTick,
                            with: .color(AssetTheme.textSecondary.opacity(0.5)),
                            lineWidth: 1
                        )
                    }
                }

                ForEach(Array(labelDates.enumerated()), id: \.offset) { index, date in
                    Text(rulerLabel(for: date, at: index))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(AssetTheme.textSecondary.opacity(0.82))
                        .lineLimit(1)
                        .position(
                            x: clampedLabelX(for: date, width: width),
                            y: 7
                        )
                }

            }
            .contentShape(Rectangle())
            .overlay {
                TimeMachineHorizontalPanGestureView { location in
                    updateSelection(at: location.x, width: width)
                } onEnded: {}
            }
            .anchorPreference(key: TimeMachineSelectionGuideAnchorKey.self, value: .bounds) { anchor in
                TimeMachineSelectionGuideAnchors(rulerBounds: anchor)
            }
        }
        .frame(height: 66)
        .accessibilityLabel(AppLocalization.string("选择历史日期"))
    }

    private func xPosition(for date: Date, width: CGFloat) -> CGFloat {
        let duration = max(lastDate.timeIntervalSince(firstDate), 1)
        let progress = min(max(date.timeIntervalSince(firstDate) / duration, 0), 1)
        return width * progress
    }

    private func clampedLabelX(for date: Date, width: CGFloat) -> CGFloat {
        min(max(xPosition(for: date, width: width), 27), width - 27)
    }

    private func updateSelection(at x: CGFloat, width: CGFloat) {
        guard !points.isEmpty else { return }
        let availableWidth = max(
            width
                - TimeMachineSelectionGuideLayout.plotLeadingInset
                - TimeMachineSelectionGuideLayout.plotTrailingInset,
            1
        )
        let progress = min(
            max((x - TimeMachineSelectionGuideLayout.plotLeadingInset) / availableWidth, 0),
            1
        )
        let index = min(max(Int((Double(points.count - 1) * Double(progress)).rounded()), 0), points.count - 1)
        selectedDate = points[index].date
    }

    private func rulerLabel(for date: Date, at index: Int) -> String {
        let calendar = Calendar.current
        let changesYear = index > 0 && !calendar.isDate(
            date,
            equalTo: labelDates[index - 1],
            toGranularity: .year
        )
        let format = index == 0 || changesYear
            ? AppLocalization.string("yyyy年M月")
            : AppLocalization.string("M月")
        return AppFormatterCache.dateFormatter(format: format).string(from: date)
    }
}

func nearestChartPoint<T>(_ points: [T], to date: Date, date keyPath: KeyPath<T, Date>) -> T? {
    guard !points.isEmpty else { return nil }

    var lowerBound = 0
    var upperBound = points.count

    while lowerBound < upperBound {
        let middle = lowerBound + (upperBound - lowerBound) / 2
        if points[middle][keyPath: keyPath] < date {
            lowerBound = middle + 1
        } else {
            upperBound = middle
        }
    }

    guard lowerBound > 0 else { return points[0] }
    guard lowerBound < points.count else { return points[points.count - 1] }

    let previous = points[lowerBound - 1]
    let next = points[lowerBound]
    let previousDistance = abs(previous[keyPath: keyPath].timeIntervalSince(date))
    let nextDistance = abs(next[keyPath: keyPath].timeIntervalSince(date))
    return previousDistance <= nextDistance ? previous : next
}

func chartAxisDates(_ dates: [Date]) -> [Date] {
    let sortedDates = Array(Set(dates)).sorted()
    guard let first = sortedDates.first else { return [] }
    guard sortedDates.count > 2, let last = sortedDates.last else { return sortedDates }

    let middle = sortedDates[sortedDates.count / 2]
    return Array(Set([first, middle, last])).sorted()
}

enum TimeMachineSurplusFormatting {
    static func paddedDomain(values: [Double]) -> ClosedRange<Double> {
        let filtered = values.filter { $0.isFinite }
        guard let minValue = filtered.min(), let maxValue = filtered.max() else {
            return -1...1
        }

        let adjustedMin = min(minValue, 0)
        let adjustedMax = max(maxValue, 0)
        if abs(adjustedMax - adjustedMin) < .ulpOfOne {
            let padding = max(abs(adjustedMax) * 0.08, 1)
            return (adjustedMin - padding)...(adjustedMax + padding)
        }
        let padding = max((adjustedMax - adjustedMin) * 0.14, max(abs(adjustedMax), abs(adjustedMin)) * 0.03, 1)
        return (adjustedMin - padding)...(adjustedMax + padding)
    }

    static func color(for value: Double) -> Color {
        value >= 0 ? AssetTheme.positive : AssetTheme.negative
    }

    static func formatted(_ value: Double) -> String {
        let prefix = value > 0 ? "+" : ""
        return prefix + value.currencyString()
    }
}

struct TimeMachineAxisDateLabel: View {
    enum Position {
        case leading
        case middle
        case trailing
    }

    let date: Date
    var position: Position = .middle

    private var anchor: UnitPoint {
        switch position {
        case .leading:
            return .topLeading
        case .middle:
            return .top
        case .trailing:
            return .topTrailing
        }
    }

    private var xOffset: CGFloat {
        switch position {
        case .leading:
            return 12
        case .middle:
            return 0
        case .trailing:
            return -12
        }
    }

    var body: some View {
        Text(date.chartAxisCompactTickString)
            .font(.system(size: 9.5, weight: .medium, design: .default))
            .foregroundStyle(AssetTheme.textSecondary)
            .lineLimit(1)
            .fixedSize()
            .offset(x: xOffset)
    }
}

struct TimeMachineMonthlySurplusCard: View {
    let points: [TimeMachineMonthlySurplusPoint]
    let annualPoints: [TimeMachineAnnualSurplusPoint]
    let amountsVisible: Bool
    @State private var selectedDate: Date?
    @State private var selectedAnnualDate: Date?
    @State private var selectedGranularity: SurplusGranularity = .monthly
    private let displayPoints: [TimeMachineMonthlySurplusPoint]
    private let latestPoint: TimeMachineMonthlySurplusPoint?
    private let leftDomain: ClosedRange<Double>
    private let axisDates: [Date]

    init(
        points: [TimeMachineMonthlySurplusPoint],
        annualPoints: [TimeMachineAnnualSurplusPoint],
        amountsVisible: Bool = true
    ) {
        self.points = points
        self.annualPoints = annualPoints
        self.amountsVisible = amountsVisible

        let displayPoints = evenlySampledItems(points, maxCount: 48)
        self.displayPoints = displayPoints
        self.latestPoint = displayPoints.last ?? points.last
        self.leftDomain = TimeMachineSurplusFormatting.paddedDomain(
            values: displayPoints.map(\.surplus)
        )
        self.axisDates = chartAxisDates(displayPoints.map(\.monthStart))
        self._selectedDate = State(initialValue: displayPoints.last?.monthStart)
        self._selectedAnnualDate = State(initialValue: annualPoints.last?.yearStart)
    }

    private enum SurplusGranularity: String, CaseIterable, Identifiable {
        case monthly
        case annual

        var id: String { rawValue }

        var shortTitle: String {
            switch self {
            case .monthly: return AppLocalization.string("月")
            case .annual: return AppLocalization.string("年")
            }
        }
    }

    private var activeGranularity: SurplusGranularity {
        switch selectedGranularity {
        case .monthly:
            return points.isEmpty && !annualPoints.isEmpty ? .annual : .monthly
        case .annual:
            return annualPoints.isEmpty && !points.isEmpty ? .monthly : .annual
        }
    }

    private var selectedPoint: TimeMachineMonthlySurplusPoint? {
        guard let latestPoint else { return nil }
        guard let selectedDate else { return latestPoint }
        return nearestChartPoint(displayPoints, to: selectedDate, date: \.monthStart) ?? latestPoint
    }

    private var selectedAnnualPoint: TimeMachineAnnualSurplusPoint? {
        guard let latestPoint = annualPoints.last else { return nil }
        guard let selectedAnnualDate else { return latestPoint }
        return nearestChartPoint(annualPoints, to: selectedAnnualDate, date: \.yearStart) ?? latestPoint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if activeGranularity == .monthly, !displayPoints.isEmpty {
                chartSection
            } else if activeGranularity == .annual, !annualPoints.isEmpty {
                TimeMachineAnnualSurplusCard(
                    points: annualPoints,
                    amountsVisible: amountsVisible,
                    selectedDate: $selectedAnnualDate
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .center, spacing: 10) {
                Text(AppLocalization.string("结余"))
                    .font(.system(size: 19, weight: .bold, design: .default))
                    .foregroundStyle(AssetTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    Text(currentSurplusPeriodText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AssetTheme.textSecondary)

                    Text(amountsVisible ? currentSurplusText : "••••")
                        .font(.system(size: 14, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(currentSurplusColor)
                }
            }

            Picker(AppLocalization.string("结余周期"), selection: $selectedGranularity) {
                ForEach(SurplusGranularity.allCases) { granularity in
                    Text(granularity.shortTitle).tag(granularity)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 110)
            .disabled(points.isEmpty || annualPoints.isEmpty)
        }
    }

    private var currentSurplusValue: Double {
        switch activeGranularity {
        case .monthly:
            return selectedPoint?.surplus ?? 0
        case .annual:
            return selectedAnnualPoint?.surplus ?? 0
        }
    }

    private var currentSurplusPeriodText: String {
        switch activeGranularity {
        case .monthly:
            guard let date = selectedPoint?.monthStart else { return "—" }
            return AppFormatterCache.dateFormatter(
                format: AppLocalization.string("yyyy年M月")
            ).string(from: date)
        case .annual:
            guard let date = selectedAnnualPoint?.yearStart else { return "—" }
            return AppFormatterCache.dateFormatter(
                format: AppLocalization.string("yyyy年")
            ).string(from: date)
        }
    }

    private var currentSurplusText: String {
        TimeMachineSurplusFormatting.formatted(currentSurplusValue)
    }

    private var currentSurplusColor: Color {
        TimeMachineSurplusFormatting.color(for: currentSurplusValue)
    }

    private var chartSection: some View {
        GeometryReader { geometry in
            let leftWidth: CGFloat = 46
            let chartWidth = max(geometry.size.width - leftWidth - 18, 120)

            HStack(spacing: 6) {
                TimeMachineAxisStrip(
                    topLabel: surplusAxisLabel(leftDomain.upperBound),
                    middleLabel: amountsVisible ? "0" : "••",
                    bottomLabel: surplusAxisLabel(leftDomain.lowerBound),
                    alignment: .leading,
                    color: AssetTheme.gold
                )
                .frame(width: leftWidth)

                Chart {
                    RuleMark(y: .value(AppLocalization.string("零线"), normalized(0, in: leftDomain)))
                        .foregroundStyle(AssetTheme.border.opacity(0.42))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))

                    ForEach(displayPoints) { point in
                        BarMark(
                            x: .value(AppLocalization.string("月份"), point.monthStart),
                            yStart: .value(AppLocalization.string("零线"), normalized(0, in: leftDomain)),
                            yEnd: .value(AppLocalization.string("月结余"), normalized(point.surplus, in: leftDomain))
                        )
                        .foregroundStyle(surplusBarColor(for: point.surplus).opacity(selectedPoint?.id == point.id ? 1 : 0.84))
                    }

                    if let selectedPoint {
                        RuleMark(x: .value(AppLocalization.string("选中月份"), selectedPoint.monthStart))
                            .foregroundStyle(AssetTheme.gold.opacity(0.72))
                            .lineStyle(StrokeStyle(lineWidth: 1))

                        PointMark(
                            x: .value(AppLocalization.string("选中月份"), selectedPoint.monthStart),
                            y: .value(AppLocalization.string("月结余"), normalized(selectedPoint.surplus, in: leftDomain))
                        )
                        .foregroundStyle(AssetTheme.goldSoft)
                        .symbolSize(32)
                    }
                }
                .frame(width: chartWidth, height: 142)
                .chartYScale(domain: 0...1)
                .chartYAxis(.hidden)
                .chartXAxis { bottomAxisMarks }
                .chartLegend(.hidden)
                .chartOverlay { proxy in
                    TimeMachineDragOverlay(
                        proxy: proxy,
                        selectableValues: displayPoints,
                        selectionDate: \.monthStart
                    ) { date in
                        selectedDate = date
                    }
                }
            }
        }
        .frame(height: 150)
    }

    private var bottomAxisMarks: some AxisContent {
        AxisMarks(values: axisDates) { value in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.7, dash: [2, 4]))
                .foregroundStyle(AssetTheme.border.opacity(0.28))
            AxisTick(stroke: StrokeStyle(lineWidth: 0.8))
                .foregroundStyle(AssetTheme.border.opacity(0.5))
            AxisValueLabel(anchor: .top, verticalSpacing: 8) {
                if let date = value.as(Date.self) {
                    Text(date.dashboardAxisDateString)
                        .font(.system(size: 9, weight: .medium, design: .default))
                        .foregroundStyle(AssetTheme.textSecondary)
                }
            }
        }
    }

    private func normalized(_ value: Double, in domain: ClosedRange<Double>) -> Double {
        let span = domain.upperBound - domain.lowerBound
        guard span.isFinite, span > 0 else { return 0.5 }
        return (value - domain.lowerBound) / span
    }

    private func surplusBarColor(for value: Double) -> Color {
        value >= 0 ? AssetTheme.positive : AssetTheme.negative
    }

    private func surplusAxisLabel(_ value: Double) -> String {
        guard amountsVisible else { return "••" }
        guard abs(value) > 0.5 else { return "0" }
        let sign = value > 0 ? "+" : "−"
        return sign + abs(value).compactNumberString(maxFractionDigits: 1, currencyCode: "CNY")
    }
}

struct TimeMachineAnnualSurplusCard: View {
    let points: [TimeMachineAnnualSurplusPoint]
    let amountsVisible: Bool
    @Binding private var selectedDate: Date?

    init(
        points: [TimeMachineAnnualSurplusPoint],
        amountsVisible: Bool = true,
        selectedDate: Binding<Date?>
    ) {
        self.points = points
        self.amountsVisible = amountsVisible
        self._selectedDate = selectedDate
    }

    private var latestPoint: TimeMachineAnnualSurplusPoint? {
        points.last
    }

    private var selectedPoint: TimeMachineAnnualSurplusPoint? {
        guard let latestPoint else { return nil }
        guard let selectedDate else { return latestPoint }
        return nearestChartPoint(points, to: selectedDate, date: \.yearStart) ?? latestPoint
    }

    private var domain: ClosedRange<Double> {
        TimeMachineSurplusFormatting.paddedDomain(values: points.map(\.surplus))
    }

    private var dateDomain: ClosedRange<Date> {
        let sortedDates = points.map(\.yearStart).sorted()
        guard let first = sortedDates.first, let last = sortedDates.last else {
            let fallback = Date()
            return fallback...fallback.addingTimeInterval(365 * 24 * 60 * 60)
        }

        if first == last {
            let calendar = Calendar.current
            let lower = calendar.date(byAdding: .month, value: -6, to: first) ?? first.addingTimeInterval(-182 * 24 * 60 * 60)
            let upper = calendar.date(byAdding: .month, value: 6, to: first) ?? first.addingTimeInterval(182 * 24 * 60 * 60)
            return lower...upper
        }

        let interval = last.timeIntervalSince(first)
        let yearSpacing = interval / Double(max(sortedDates.count - 1, 1))
        let padding = max(yearSpacing * 0.42, 45 * 24 * 60 * 60)
        return first.addingTimeInterval(-padding)...last.addingTimeInterval(padding)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !points.isEmpty {
                chartSection
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var chartSection: some View {
        GeometryReader { geometry in
            let leftWidth: CGFloat = 46
            let chartWidth = max(geometry.size.width - leftWidth - 18, 120)
            let barWidth = min(max(chartWidth / CGFloat(max(points.count, 1)) * 0.42, 10), 34)

            HStack(spacing: 6) {
                TimeMachineAxisStrip(
                    topLabel: surplusAxisLabel(domain.upperBound),
                    middleLabel: amountsVisible ? "0" : "••",
                    bottomLabel: surplusAxisLabel(domain.lowerBound),
                    alignment: .leading,
                    color: AssetTheme.gold
                )
                .frame(width: leftWidth)

                Chart {
                    RuleMark(y: .value(AppLocalization.string("零线"), normalized(0, in: domain)))
                        .foregroundStyle(AssetTheme.border.opacity(0.42))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))

                    ForEach(points) { point in
                        BarMark(
                            x: .value(AppLocalization.string("年份"), point.yearStart),
                            yStart: .value(AppLocalization.string("零线"), normalized(0, in: domain)),
                            yEnd: .value(AppLocalization.string("年结余"), normalized(point.surplus, in: domain)),
                            width: .fixed(barWidth)
                        )
                        .foregroundStyle((point.surplus >= 0 ? AssetTheme.positive : AssetTheme.negative).opacity(selectedPoint?.id == point.id ? 1 : 0.84))
                    }

                    if let selectedPoint {
                        RuleMark(x: .value(AppLocalization.string("选中年份"), selectedPoint.yearStart))
                            .foregroundStyle(AssetTheme.gold.opacity(0.72))
                            .lineStyle(StrokeStyle(lineWidth: 1))

                        PointMark(
                            x: .value(AppLocalization.string("选中年份"), selectedPoint.yearStart),
                            y: .value(AppLocalization.string("年结余"), normalized(selectedPoint.surplus, in: domain))
                        )
                        .foregroundStyle(AssetTheme.goldSoft)
                        .symbolSize(32)
                    }
                }
                .frame(width: chartWidth, height: 132)
                .chartXScale(
                    domain: dateDomain,
                    range: .plotDimension(startPadding: 4, endPadding: 4)
                )
                .chartYScale(domain: 0...1)
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks(values: points.map(\.yearStart)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.7, dash: [2, 4]))
                            .foregroundStyle(AssetTheme.border.opacity(0.24))
                        AxisTick(stroke: StrokeStyle(lineWidth: 0.8))
                            .foregroundStyle(AssetTheme.border.opacity(0.44))
                        AxisValueLabel(anchor: .top, verticalSpacing: 8) {
                            if let date = value.as(Date.self) {
                                Text(date.yearAxisDateString)
                                    .font(.system(size: 9, weight: .medium, design: .default))
                                    .foregroundStyle(AssetTheme.textSecondary)
                            }
                        }
                    }
                }
                .chartLegend(.hidden)
                .chartOverlay { proxy in
                    TimeMachineDragOverlay(
                        proxy: proxy,
                        selectableValues: points,
                        selectionDate: \.yearStart
                    ) { date in
                        selectedDate = date
                    }
                }
            }
        }
        .frame(height: 140)
    }

    private func normalized(_ value: Double, in domain: ClosedRange<Double>) -> Double {
        let span = domain.upperBound - domain.lowerBound
        guard span.isFinite, span > 0 else { return 0.5 }
        return (value - domain.lowerBound) / span
    }

    private func surplusAxisLabel(_ value: Double) -> String {
        guard amountsVisible else { return "••" }
        guard abs(value) > 0.5 else { return "0" }
        let sign = value > 0 ? "+" : "−"
        return sign + abs(value).compactNumberString(maxFractionDigits: 1, currencyCode: "CNY")
    }
}

private final class TimeMachineDragInteractionState {
    var lastReportedDate: Date?
    var pendingDate: Date?
    var lastReportUptime: TimeInterval = 0

    func reset() {
        lastReportedDate = nil
        pendingDate = nil
        lastReportUptime = 0
    }
}

struct TimeMachineHorizontalPanGestureView: UIViewRepresentable {
    let onChanged: (CGPoint) -> Void
    let onEnded: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChanged: onChanged, onEnded: onEnded)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isAccessibilityElement = false

        let recognizer = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )
        recognizer.maximumNumberOfTouches = 1
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = context.coordinator
        view.addGestureRecognizer(recognizer)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onChanged: (CGPoint) -> Void
        var onEnded: () -> Void

        init(onChanged: @escaping (CGPoint) -> Void, onEnded: @escaping () -> Void) {
            self.onChanged = onChanged
            self.onEnded = onEnded
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed:
                guard let view = recognizer.view else { return }
                onChanged(recognizer.location(in: view))
            case .ended, .cancelled, .failed:
                onEnded()
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let view = pan.view else { return false }

            let velocity = pan.velocity(in: view)
            let translation = pan.translation(in: view)
            let direction = abs(velocity.x) + abs(velocity.y) > 1
                ? velocity
                : translation
            let horizontalDistance = abs(direction.x)
            let verticalDistance = abs(direction.y)
            return horizontalDistance > verticalDistance * 1.15
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            if otherGestureRecognizer is UIPanGestureRecognizer {
                return false
            }
            return true
        }
    }
}

struct TimeMachineDragOverlay<SelectableValue>: View {
    let proxy: ChartProxy
    let selectableValues: [SelectableValue]
    let selectionDate: KeyPath<SelectableValue, Date>
    let onChanged: (Date) -> Void
    var onEnded: (() -> Void)? = nil

    @State private var interactionState = TimeMachineDragInteractionState()

    var body: some View {
        GeometryReader { geometry in
            TimeMachineHorizontalPanGestureView {
                reportSelection(at: $0, in: geometry)
            } onEnded: {
                finishInteraction()
            }
        }
    }

    private func reportSelection(at location: CGPoint, in geometry: GeometryProxy) {
        guard let plotFrame = proxy.plotFrame else { return }
        let frame = geometry[plotFrame]
        let locationX = min(max(location.x - frame.origin.x, 0), frame.size.width)
        guard let rawDate: Date = proxy.value(atX: locationX) else { return }

        let reportedDate = nearestChartPoint(
            selectableValues,
            to: rawDate,
            date: selectionDate
        )?[keyPath: selectionDate] ?? rawDate

        interactionState.pendingDate = reportedDate
        guard reportedDate != interactionState.lastReportedDate else { return }

        emit(reportedDate, at: ProcessInfo.processInfo.systemUptime)
    }

    private func finishInteraction() {
        let didReportSelection = interactionState.lastReportedDate != nil

        if onEnded == nil,
           let pendingDate = interactionState.pendingDate,
           pendingDate != interactionState.lastReportedDate {
            emit(pendingDate, at: ProcessInfo.processInfo.systemUptime)
        }

        interactionState.reset()
        guard didReportSelection else { return }

        withoutAnimations {
            onEnded?()
        }
    }

    private func emit(_ date: Date, at uptime: TimeInterval) {
        interactionState.lastReportedDate = date
        interactionState.lastReportUptime = uptime

        withoutAnimations {
            onChanged(date)
        }
    }

    private func withoutAnimations(_ action: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, action)
    }
}

struct TimeMachineAxisStrip: View {
    let topLabel: String
    let middleLabel: String
    let bottomLabel: String
    let alignment: HorizontalAlignment
    let color: Color

    var body: some View {
        VStack(alignment: alignment, spacing: 0) {
            Text(topLabel)
                .font(.system(size: 8.8, weight: .semibold, design: .default))
                .foregroundStyle(color.opacity(0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            Spacer(minLength: 10)
            Text(middleLabel)
                .font(.system(size: 8.8, weight: .medium, design: .default))
                .foregroundStyle(AssetTheme.textSecondary.opacity(0.84))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            Spacer(minLength: 10)
            Text(bottomLabel)
                .font(.system(size: 8.8, weight: .semibold, design: .default))
                .foregroundStyle(color.opacity(0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }
}

import SwiftUI
import SwiftData
import Charts
import UIKit

enum BacktestChartValueStyle {
    case multiple
    case currency(code: String)

    func label(for value: Double) -> String {
        switch self {
        case .multiple:
            return String(format: "%.2fx", value)
        case let .currency(code):
            return value.currencyString(code: code)
        }
    }

    func axisLabel(for value: Double) -> String {
        switch self {
        case .multiple:
            if value >= 100 {
                return String(format: "%.0fx", value)
            }
            return String(format: "%.1fx", value)
        case let .currency(code):
            return value.formatted(
                .currency(code: code)
                .precision(.fractionLength(0...1))
                .notation(.compactName)
            )
        }
    }
}

enum BacktestChartSeriesTitle {
    static var strategy: String { AppLocalization.string("策略净值") }
}

enum BacktestChartSeriesKey {
    static let strategy = "strategy"
    static let legacyBenchmark = "benchmark"
}

struct BacktestChartComparisonSeries: Identifiable {
    let id: String
    let title: String
    let points: [BacktestSeriesPoint]
    let color: Color
}

struct BacktestChartLegendItem: Identifiable {
    let id: String
    let title: String
    let color: Color
    let isDashed: Bool
}

enum BacktestChartPalette {
    static var strategyLine: Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 1.00, green: 0.74, blue: 0.14, alpha: 1)
                : UIColor(red: 0.78, green: 0.36, blue: 0.02, alpha: 1)
        })
    }

    static var benchmarkLine: Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.00, green: 0.86, blue: 1.00, alpha: 1)
                : UIColor(red: 0.00, green: 0.28, blue: 0.86, alpha: 1)
        })
    }

    static func comparisonLine(at index: Int) -> Color {
        let palette: [Color] = [
            benchmarkLine,
            Color(uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 0.56, green: 0.95, blue: 0.56, alpha: 1)
                    : UIColor(red: 0.00, green: 0.48, blue: 0.24, alpha: 1)
            }),
            Color(uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 0.78, green: 0.64, blue: 1.00, alpha: 1)
                    : UIColor(red: 0.42, green: 0.25, blue: 0.86, alpha: 1)
            }),
            Color(uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 1.00, green: 0.58, blue: 0.44, alpha: 1)
                    : UIColor(red: 0.84, green: 0.22, blue: 0.12, alpha: 1)
            }),
            Color(uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 0.52, green: 0.82, blue: 1.00, alpha: 1)
                    : UIColor(red: 0.04, green: 0.42, blue: 0.68, alpha: 1)
            })
        ]
        return palette[abs(index) % palette.count]
    }

    static var strategyAreaTop: Color { strategyLine.opacity(0.18) }
    static var strategyAreaBottom: Color { strategyLine.opacity(0.025) }
}

struct InteractiveBacktestChart: View {
    let points: [BacktestSeriesPoint]
    var comparisonPoints: [BacktestSeriesPoint] = []
    var comparisonSeries: [BacktestChartComparisonSeries] = []
    var valueStyle: BacktestChartValueStyle = .multiple
    var visibleSeriesIDs: Set<String> = []
    var placesViewportControlsAboveChart = false
    @State private var selectedDate: Date?
    @State private var viewportStartRatio: Double = 0
    @State private var visibleSpanRatio: Double = 1

    private let minVisibleSpanRatio = 0.12
    private let zoomStep = 0.64

    private var resolvedComparisonSeries: [BacktestChartComparisonSeries] {
        let explicitSeries = comparisonSeries.filter { !$0.points.isEmpty }
        if !explicitSeries.isEmpty { return explicitSeries }
        guard !comparisonPoints.isEmpty else { return [] }
        return [
            BacktestChartComparisonSeries(
                id: BacktestChartSeriesKey.legacyBenchmark,
                title: AppLocalization.string("买入持有"),
                points: comparisonPoints,
                color: BacktestChartPalette.comparisonLine(at: 0)
            )
        ]
    }

    private var availableSeriesIDs: Set<String> {
        Set([BacktestChartSeriesKey.strategy] + resolvedComparisonSeries.map(\.id))
    }

    private var effectiveVisibleSeriesIDs: Set<String> {
        let visibleAvailableSeries = visibleSeriesIDs.intersection(availableSeriesIDs)
        return visibleAvailableSeries.isEmpty ? availableSeriesIDs : visibleAvailableSeries
    }

    private var interactionSeriesID: String? {
        let visibleSeriesIDs = effectiveVisibleSeriesIDs
        if visibleSeriesIDs.contains(BacktestChartSeriesKey.strategy) { return BacktestChartSeriesKey.strategy }
        return resolvedComparisonSeries.first(where: { visibleSeriesIDs.contains($0.id) })?.id
    }

    private var interactionPoints: [BacktestSeriesPoint] {
        guard let interactionSeriesID else { return [] }
        if interactionSeriesID == BacktestChartSeriesKey.strategy { return points }
        return resolvedComparisonSeries.first(where: { $0.id == interactionSeriesID })?.points ?? []
    }

    private var interactionColor: Color {
        guard let interactionSeriesID else { return BacktestChartPalette.strategyLine }
        if interactionSeriesID == BacktestChartSeriesKey.strategy { return BacktestChartPalette.strategyLine }
        return resolvedComparisonSeries.first(where: { $0.id == interactionSeriesID })?.color ?? BacktestChartPalette.benchmarkLine
    }

    private var selectedPoint: BacktestSeriesPoint? {
        let activePoints = interactionPoints
        guard let selectedDate else { return activePoints.last }
        return Self.nearestPoint(to: selectedDate, in: activePoints)
    }

    private var fullDateDomain: ClosedRange<Date>? {
        let visibleSeriesIDs = effectiveVisibleSeriesIDs
        var lowerBound: Date?
        var upperBound: Date?

        func include(_ points: [BacktestSeriesPoint]) {
            for point in points {
                lowerBound = lowerBound.map { min($0, point.date) } ?? point.date
                upperBound = upperBound.map { max($0, point.date) } ?? point.date
            }
        }

        if visibleSeriesIDs.contains(BacktestChartSeriesKey.strategy) {
            include(points)
        }
        for series in resolvedComparisonSeries where visibleSeriesIDs.contains(series.id) {
            include(series.points)
        }

        guard let lowerBound, let upperBound else { return nil }
        if lowerBound == upperBound {
            return lowerBound...lowerBound.addingTimeInterval(24 * 60 * 60)
        }
        return lowerBound...upperBound
    }

    private var maxViewportStartRatio: Double {
        max(1 - visibleSpanRatio, 0)
    }

    private var visibleDateDomain: ClosedRange<Date>? {
        guard let fullDateDomain else { return nil }
        let fullInterval = max(fullDateDomain.upperBound.timeIntervalSince(fullDateDomain.lowerBound), 1)
        let safeSpan = min(max(visibleSpanRatio, minVisibleSpanRatio), 1)
        let safeStart = min(max(viewportStartRatio, 0), max(1 - safeSpan, 0))
        let start = fullDateDomain.lowerBound.addingTimeInterval(fullInterval * safeStart)
        let end = start.addingTimeInterval(fullInterval * safeSpan)
        return start...min(end, fullDateDomain.upperBound)
    }

    private var chartDateDomain: ClosedRange<Date> {
        if let visibleDateDomain { return visibleDateDomain }
        let fallbackStart = Date()
        return fallbackStart...fallbackStart.addingTimeInterval(24 * 60 * 60)
    }

    private var canShowViewportControls: Bool {
        guard let fullDateDomain else { return false }
        return fullDateDomain.upperBound > fullDateDomain.lowerBound
    }

    private var canZoomIn: Bool {
        canShowViewportControls && visibleSpanRatio > minVisibleSpanRatio + 0.001
    }

    private var canZoomOut: Bool {
        canShowViewportControls && visibleSpanRatio < 0.999
    }

    private var canPanLeft: Bool {
        canShowViewportControls && viewportStartRatio > 0.001
    }

    private var canPanRight: Bool {
        canShowViewportControls && viewportStartRatio < maxViewportStartRatio - 0.001
    }

    private func valueDomain(in dateDomain: ClosedRange<Date>?) -> ClosedRange<Double> {
        var minValue = Double.infinity
        var maxValue = -Double.infinity
        let visibleSeriesIDs = effectiveVisibleSeriesIDs

        func isVisible(_ point: BacktestSeriesPoint) -> Bool {
            guard let dateDomain else { return true }
            return point.date >= dateDomain.lowerBound && point.date <= dateDomain.upperBound
        }

        if visibleSeriesIDs.contains(BacktestChartSeriesKey.strategy) {
            for point in points where point.portfolioValue.isFinite && isVisible(point) {
                minValue = min(minValue, point.portfolioValue)
                maxValue = max(maxValue, point.portfolioValue)
            }
        }
        for series in resolvedComparisonSeries where visibleSeriesIDs.contains(series.id) {
            for point in series.points where point.portfolioValue.isFinite && isVisible(point) {
                minValue = min(minValue, point.portfolioValue)
                maxValue = max(maxValue, point.portfolioValue)
            }
        }

        guard minValue.isFinite, maxValue.isFinite else {
            return 0...1
        }
        if abs(maxValue - minValue) < .ulpOfOne {
            let padding = max(abs(maxValue) * 0.08, 1)
            return (minValue - padding)...(maxValue + padding)
        }
        let padding = max((maxValue - minValue) * 0.12, abs(maxValue) * 0.02)
        return (minValue - padding)...(maxValue + padding)
    }

    private func clampViewport() {
        visibleSpanRatio = min(max(visibleSpanRatio, minVisibleSpanRatio), 1)
        viewportStartRatio = min(max(viewportStartRatio, 0), maxViewportStartRatio)
    }

    private func zoomViewport(by factor: Double) {
        guard canShowViewportControls else { return }
        let oldSpan = visibleSpanRatio
        let oldCenter = viewportStartRatio + oldSpan / 2
        let nextSpan = min(max(oldSpan * factor, minVisibleSpanRatio), 1)
        visibleSpanRatio = nextSpan
        viewportStartRatio = min(max(oldCenter - nextSpan / 2, 0), max(1 - nextSpan, 0))
    }

    private func panViewport(by spanFraction: Double) {
        guard canShowViewportControls else { return }
        let step = visibleSpanRatio * spanFraction
        viewportStartRatio = min(max(viewportStartRatio + step, 0), maxViewportStartRatio)
    }

    private func resetViewport() {
        visibleSpanRatio = 1
        viewportStartRatio = 0
        selectedDate = nil
    }

    private var foregroundStyleDomain: [String] {
        [BacktestChartSeriesTitle.strategy] + resolvedComparisonSeries.map(\.title)
    }

    private var foregroundStyleRange: [Color] {
        [BacktestChartPalette.strategyLine] + resolvedComparisonSeries.map(\.color)
    }

    private static func nearestPoint(to date: Date, in points: [BacktestSeriesPoint]) -> BacktestSeriesPoint? {
        guard !points.isEmpty else { return nil }
        guard points.count > 1 else { return points[0] }

        var lowerBound = 0
        var upperBound = points.count - 1
        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            if points[middle].date < date {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }

        if lowerBound == 0 { return points[0] }
        let nextPoint = points[lowerBound]
        let previousPoint = points[lowerBound - 1]
        return abs(previousPoint.date.timeIntervalSince(date)) <= abs(nextPoint.date.timeIntervalSince(date)) ? previousPoint : nextPoint
    }

    @ChartContentBuilder
    private func strategyMarks(domain: ClosedRange<Double>, strategySeries: String) -> some ChartContent {
        if effectiveVisibleSeriesIDs.contains(BacktestChartSeriesKey.strategy) {
            ForEach(points) { point in
                AreaMark(
                    x: .value(AppLocalization.string("日期"), point.date),
                    yStart: .value(AppLocalization.string("组合净值下沿"), domain.lowerBound),
                    yEnd: .value(AppLocalization.string("组合净值"), point.portfolioValue)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [BacktestChartPalette.strategyAreaTop, BacktestChartPalette.strategyAreaBottom],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                LineMark(
                    x: .value(AppLocalization.string("日期"), point.date),
                    y: .value(AppLocalization.string("组合净值"), point.portfolioValue)
                )
                .foregroundStyle(by: .value(AppLocalization.string("系列"), strategySeries))
                .lineStyle(StrokeStyle(lineWidth: 2.9, lineCap: .round, lineJoin: .round))
            }
        }
    }

    @ChartContentBuilder
    private func comparisonMarks(seriesList: [BacktestChartComparisonSeries], visibleSeriesIDs: Set<String>) -> some ChartContent {
        ForEach(seriesList) { series in
            if visibleSeriesIDs.contains(series.id) {
                ForEach(series.points) { point in
                    LineMark(
                        x: .value(AppLocalization.string("日期"), point.date),
                        y: .value(series.title, point.portfolioValue)
                    )
                    .foregroundStyle(by: .value(AppLocalization.string("系列"), series.title))
                    .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round, dash: [8, 5]))
                }
            }
        }
    }

    @ChartContentBuilder
    private func selectionMarks() -> some ChartContent {
        if let selectedPoint {
            PointMark(
                x: .value(AppLocalization.string("日期"), selectedPoint.date),
                y: .value(AppLocalization.string("组合净值"), selectedPoint.portfolioValue)
            )
            .foregroundStyle(interactionColor)
            .symbolSize(44)
        }

        if selectedDate != nil, let selectedPoint {
            RuleMark(x: .value(AppLocalization.string("选中日期"), selectedPoint.date))
                .foregroundStyle(AssetTheme.textSecondary.opacity(0.45))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
    }

    @ViewBuilder
    private var selectedValueBadge: some View {
        if selectedDate != nil, let selectedPoint {
            VStack(alignment: .trailing, spacing: 2) {
                Text(AppLocalization.string("资产"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AssetTheme.textSecondary)
                Text(valueStyle.label(for: selectedPoint.portfolioValue))
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(AssetTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(AssetTheme.overlaySoft.opacity(0.96), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(AssetTheme.border.opacity(0.45), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.16), radius: 8, y: 4)
            .padding(.top, 8)
            .padding(.horizontal, 8)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var viewportControls: some View {
        if canShowViewportControls {
            HStack(spacing: 5) {
                viewportControlButton(
                    systemImage: "plus.magnifyingglass",
                    accessibilityLabel: AppLocalization.string("放大图表"),
                    isEnabled: canZoomIn
                ) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        zoomViewport(by: zoomStep)
                    }
                }

                viewportControlButton(
                    systemImage: "minus.magnifyingglass",
                    accessibilityLabel: AppLocalization.string("缩小图表"),
                    isEnabled: canZoomOut
                ) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        zoomViewport(by: 1 / zoomStep)
                    }
                }

                Divider()
                    .frame(width: 1, height: 18)
                    .overlay(AssetTheme.border.opacity(0.55))

                viewportControlButton(
                    systemImage: "chevron.left",
                    accessibilityLabel: AppLocalization.string("图表左移"),
                    isEnabled: canPanLeft
                ) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        panViewport(by: -0.38)
                    }
                }

                viewportControlButton(
                    systemImage: "chevron.right",
                    accessibilityLabel: AppLocalization.string("图表右移"),
                    isEnabled: canPanRight
                ) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        panViewport(by: 0.38)
                    }
                }

                viewportControlButton(
                    systemImage: "arrow.counterclockwise",
                    accessibilityLabel: AppLocalization.string("重置图表视图"),
                    isEnabled: canZoomOut || canPanLeft || canPanRight
                ) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        resetViewport()
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .fixedSize(horizontal: true, vertical: false)
            .background(AssetTheme.overlaySoft.opacity(0.94), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(AssetTheme.border.opacity(0.48), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.14), radius: 10, y: 5)
            .padding(.trailing, 6)
            .padding(.top, placesViewportControlsAboveChart ? 0 : 8)
            .offset(y: placesViewportControlsAboveChart ? -44 : 0)
        }
    }

    private func viewportControlButton(
        systemImage: String,
        accessibilityLabel: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(isEnabled ? AssetTheme.textPrimary : AssetTheme.textSecondary.opacity(0.42))
                .frame(width: 28, height: 28)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(accessibilityLabel)
    }

    var body: some View {
        let xDomain = chartDateDomain
        let domain = valueDomain(in: xDomain)
        let visibleSeriesIDs = effectiveVisibleSeriesIDs
        let comparisonSeries = resolvedComparisonSeries
        let strategySeries = BacktestChartSeriesTitle.strategy

        Chart {
            strategyMarks(domain: domain, strategySeries: strategySeries)
            comparisonMarks(seriesList: comparisonSeries, visibleSeriesIDs: visibleSeriesIDs)
            selectionMarks()
        }
        .frame(height: 220)
        .clipped()
        .chartXScale(domain: xDomain)
        .chartYScale(domain: domain)
        .chartForegroundStyleScale(domain: foregroundStyleDomain, range: foregroundStyleRange)
        .animation(.easeInOut(duration: 0.2), value: visibleSeriesIDs)
        .animation(.easeInOut(duration: 0.18), value: viewportStartRatio)
        .animation(.easeInOut(duration: 0.18), value: visibleSpanRatio)
        .chartPlotStyle { plotArea in
            plotArea
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) {
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.7, dash: [2, 4]))
                    .foregroundStyle(AssetTheme.border.opacity(0.35))
                AxisValueLabel(format: .dateTime.year())
                    .foregroundStyle(AssetTheme.textSecondary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.7, dash: [2, 4]))
                    .foregroundStyle(AssetTheme.border.opacity(0.35))
                AxisValueLabel {
                    if let doubleValue = value.as(Double.self) {
                        Text(valueStyle.axisLabel(for: doubleValue))
                            .font(.system(size: 9.5, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(AssetTheme.textSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .frame(width: 42, alignment: .trailing)
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            TimeMachineDragOverlay(proxy: proxy) { date in
                selectedDate = date
            } onEnded: {
                selectedDate = nil
            }
        }
        .overlay(alignment: .topLeading) {
            selectedValueBadge
        }
        .overlay(alignment: .topTrailing) {
            viewportControls
        }
        .onChange(of: points.count) { _ in
            clampViewport()
        }
        .onChange(of: visibleSeriesIDs) { _ in
            clampViewport()
        }
    }

}

enum BacktestChartData {
    static func sampledPoints(from points: [BacktestSeriesPoint], maxCount: Int = 240) -> [BacktestSeriesPoint] {
        guard points.count > maxCount, maxCount > 1 else { return points }

        let step = Double(points.count - 1) / Double(maxCount - 1)
        var sampled: [BacktestSeriesPoint] = []
        sampled.reserveCapacity(maxCount)

        for index in 0 ..< maxCount {
            let rawIndex = Int((Double(index) * step).rounded())
            let safeIndex = min(max(rawIndex, 0), points.count - 1)
            let point = points[safeIndex]
            if sampled.last?.date != point.date {
                sampled.append(point)
            }
        }

        if sampled.last?.date != points.last?.date, let last = points.last {
            sampled.append(last)
        }

        return sampled.enumerated().map { index, point in
            BacktestSeriesPoint(date: point.date, portfolioValue: point.portfolioValue, sequence: index)
        }
    }

    static func normalizedComparisonPoints(
        _ points: [BacktestSeriesPoint],
        targetStartValue: Double?
    ) -> [BacktestSeriesPoint] {
        guard let targetStartValue,
              targetStartValue.isFinite,
              targetStartValue > 0,
              let firstValue = points.first?.portfolioValue,
              firstValue.isFinite,
              firstValue > 0 else {
            return points
        }

        let scale = targetStartValue / firstValue
        guard scale.isFinite, abs(scale - 1) > 0.000001 else { return points }

        return points.map { point in
            BacktestSeriesPoint(
                date: point.date,
                portfolioValue: point.portfolioValue * scale,
                sequence: point.id
            )
        }
    }

    static func legendItems(for comparisonSeries: [BacktestChartComparisonSeries]) -> [BacktestChartLegendItem] {
        [
            BacktestChartLegendItem(
                id: BacktestChartSeriesKey.strategy,
                title: BacktestChartSeriesTitle.strategy,
                color: BacktestChartPalette.strategyLine,
                isDashed: false
            )
        ] + comparisonSeries.map { series in
            BacktestChartLegendItem(id: series.id, title: series.title, color: series.color, isDashed: true)
        }
    }
}

struct BacktestValueChartSection: View {
    let points: [BacktestSeriesPoint]
    var comparisonSeries: [BacktestChartComparisonSeries] = []
    var valueStyle: BacktestChartValueStyle = .multiple
    var title: String = AppLocalization.string("净值走势")
    var footnote: String? = nil
    @State private var visibleSeriesIDs: Set<String> = []

    private var chartPoints: [BacktestSeriesPoint] {
        BacktestChartData.sampledPoints(from: points)
    }

    private var chartComparisonSeries: [BacktestChartComparisonSeries] {
        comparisonSeries.compactMap { series in
            let sampledPoints = BacktestChartData.sampledPoints(from: series.points)
            guard !sampledPoints.isEmpty else { return nil }
            return BacktestChartComparisonSeries(
                id: series.id,
                title: series.title,
                points: sampledPoints,
                color: series.color
            )
        }
    }

    private var legendItems: [BacktestChartLegendItem] {
        BacktestChartData.legendItems(for: chartComparisonSeries)
    }

    private var availableSeriesIDs: [String] {
        legendItems.map(\.id)
    }

    private var effectiveVisibleSeriesIDs: Set<String> {
        let availableSet = Set(availableSeriesIDs)
        let visibleAvailableSeries = visibleSeriesIDs.intersection(availableSet)
        return visibleAvailableSeries.isEmpty ? availableSet : visibleAvailableSeries
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(AssetTheme.textPrimary)

            InteractiveBacktestChart(
                points: chartPoints,
                comparisonSeries: chartComparisonSeries,
                valueStyle: valueStyle,
                visibleSeriesIDs: effectiveVisibleSeriesIDs,
                placesViewportControlsAboveChart: true
            )

            if legendItems.count > 1 {
                ATMFlowLayout(horizontalSpacing: 8, verticalSpacing: 8, rowAlignment: .center) {
                    ForEach(legendItems) { series in
                        legendToggle(
                            series: series,
                            isVisible: effectiveVisibleSeriesIDs.contains(series.id),
                            canHide: effectiveVisibleSeriesIDs.count > 1
                        )
                    }
                }
                .padding(.top, -2)
                .frame(maxWidth: .infinity, alignment: .center)
            }

            if let footnote, !footnote.isEmpty {
                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(AssetTheme.textSecondary.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func toggleSeries(_ seriesID: String) {
        let availableSet = Set(availableSeriesIDs)
        var nextVisibleSeries = effectiveVisibleSeriesIDs

        if nextVisibleSeries.contains(seriesID) {
            guard nextVisibleSeries.count > 1 else { return }
            nextVisibleSeries.remove(seriesID)
        } else {
            nextVisibleSeries.insert(seriesID)
        }

        visibleSeriesIDs = nextVisibleSeries.intersection(availableSet)
    }

    private func legendToggle(series: BacktestChartLegendItem, isVisible: Bool, canHide: Bool) -> some View {
        Button {
            guard !isVisible || canHide else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                toggleSeries(series.id)
            }
        } label: {
            HStack(spacing: 6) {
                if series.isDashed {
                    Capsule()
                        .stroke(series.color, style: StrokeStyle(lineWidth: 2.4, dash: [6, 4]))
                        .frame(width: 24, height: 7)
                } else {
                    Circle()
                        .fill(series.color)
                        .frame(width: 9, height: 9)
                }

                Text(series.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isVisible ? AssetTheme.textSecondary : AssetTheme.textSecondary.opacity(0.58))
                    .strikethrough(!isVisible, color: AssetTheme.textSecondary.opacity(0.72))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(isVisible ? AssetTheme.overlaySoft : AssetTheme.overlayFaint, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(isVisible ? series.color.opacity(0.45) : AssetTheme.border.opacity(0.4), lineWidth: 1)
            )
            .opacity(isVisible ? 1 : 0.48)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isVisible && !canHide)
        .accessibilityLabel(series.title)
        .accessibilityHint(AppLocalization.string(isVisible ? "点击隐藏曲线" : "点击显示曲线"))
    }
}

struct BacktestAllocationSlice: Identifiable {
    let title: String
    let amount: Double
    let color: Color

    var id: String { title }
}

import SwiftUI
import SwiftData
import Charts
import UIKit

enum BacktestChartValueStyle: Equatable {
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
            return value.chartAxisCurrencyLabel(code: code)
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
    nonisolated static var strategyLine: Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 1.00, green: 0.74, blue: 0.14, alpha: 1)
                : UIColor(red: 0.78, green: 0.36, blue: 0.02, alpha: 1)
        })
    }

    nonisolated static var benchmarkLine: Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.00, green: 0.86, blue: 1.00, alpha: 1)
                : UIColor(red: 0.00, green: 0.28, blue: 0.86, alpha: 1)
        })
    }

    nonisolated static func comparisonLine(at index: Int) -> Color {
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

    nonisolated static func exposureLine(at index: Int) -> Color {
        let palette: [Color] = [
            Color(red: 0.93, green: 0.63, blue: 0.18),
            Color(red: 0.16, green: 0.58, blue: 0.95),
            Color(red: 0.22, green: 0.72, blue: 0.45),
            Color(red: 0.74, green: 0.38, blue: 0.92),
            Color(red: 0.95, green: 0.32, blue: 0.31),
            Color(red: 0.10, green: 0.72, blue: 0.76),
            Color(red: 0.95, green: 0.47, blue: 0.16),
            Color(red: 0.42, green: 0.50, blue: 0.94),
            Color(red: 0.54, green: 0.72, blue: 0.20),
            Color(red: 0.90, green: 0.31, blue: 0.64)
        ]
        return palette[abs(index) % palette.count]
    }

    static var strategyAreaTop: Color { strategyLine.opacity(0.18) }
    static var strategyAreaBottom: Color { strategyLine.opacity(0.025) }
}

struct InteractiveBacktestChart: View, Equatable {
    let points: [BacktestSeriesPoint]
    var comparisonPoints: [BacktestSeriesPoint] = []
    var comparisonSeries: [BacktestChartComparisonSeries] = []
    var valueStyle: BacktestChartValueStyle = .multiple
    var visibleSeriesIDs: Set<String> = []
    var placesViewportControlsAboveChart = false
    var onVisibleDateDomainChange: ((ClosedRange<Date>) -> Void)? = nil
    @State private var selectedDate: Date?
    @State private var viewportStartRatio: Double = 0
    @State private var visibleSpanRatio: Double = 1

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.valueStyle == rhs.valueStyle
            && lhs.visibleSeriesIDs == rhs.visibleSeriesIDs
            && lhs.placesViewportControlsAboveChart == rhs.placesViewportControlsAboveChart
            && seriesIdentityMatches(lhs.points, rhs.points)
            && seriesIdentityMatches(lhs.comparisonPoints, rhs.comparisonPoints)
            && comparisonIdentityMatches(lhs.comparisonSeries, rhs.comparisonSeries)
    }

    private static func seriesIdentityMatches(
        _ lhs: [BacktestSeriesPoint],
        _ rhs: [BacktestSeriesPoint]
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (lhsPoint, rhsPoint) in zip(lhs, rhs) {
            guard lhsPoint.date == rhsPoint.date,
                  lhsPoint.portfolioValue == rhsPoint.portfolioValue else { return false }
        }
        return true
    }

    private static func comparisonIdentityMatches(
        _ lhs: [BacktestChartComparisonSeries],
        _ rhs: [BacktestChartComparisonSeries]
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (lhsSeries, rhsSeries) in zip(lhs, rhs) {
            guard lhsSeries.id == rhsSeries.id,
                  lhsSeries.title == rhsSeries.title,
                  seriesIdentityMatches(lhsSeries.points, rhsSeries.points) else { return false }
        }
        return true
    }

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

    private func publishVisibleDateDomain() {
        guard let visibleDateDomain else { return }
        onVisibleDateDomainChange?(visibleDateDomain)
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
                    .font(AppTypography.chartCaptionStrong)
                    .foregroundStyle(AssetTheme.textSecondary)
                Text(valueStyle.label(for: selectedPoint.portfolioValue))
                    .font(AppTypography.captionStrong)
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
                .font(AppTypography.captionStrong)
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
        .chartXScale(domain: xDomain)
        .chartXScale(range: .plotDimension(startPadding: 4, endPadding: 46))
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
            AxisMarks(values: BacktestChartData.dateAxisValues(in: xDomain)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.7, dash: [2, 4]))
                    .foregroundStyle(AssetTheme.border.opacity(0.35))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date, format: .dateTime.year())
                            .foregroundStyle(AssetTheme.textSecondary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.7, dash: [2, 4]))
                    .foregroundStyle(AssetTheme.border.opacity(0.35))
                AxisValueLabel {
                    if let doubleValue = value.as(Double.self) {
                        Text(valueStyle.axisLabel(for: doubleValue))
                            .font(AppTypography.chartAxisCompact)
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
            TimeMachineDragOverlay(
                proxy: proxy,
                selectableValues: interactionPoints,
                selectionDate: \.date
            ) { date in
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
        .onChange(of: points.count) { _, _ in
            clampViewport()
            publishVisibleDateDomain()
        }
        .onChange(of: visibleSeriesIDs) { _, _ in
            clampViewport()
            publishVisibleDateDomain()
        }
        .onChange(of: viewportStartRatio) { _, _ in
            publishVisibleDateDomain()
        }
        .onChange(of: visibleSpanRatio) { _, _ in
            publishVisibleDateDomain()
        }
        .onAppear {
            publishVisibleDateDomain()
        }
    }

}

private enum BacktestExposureSeriesKey {
    static let total = "exposure.total"

    static func asset(_ symbol: String) -> String {
        "exposure.asset.\(symbol)"
    }
}

enum BacktestChartData {
    static func dateAxisValues(in domain: ClosedRange<Date>, desiredCount: Int = 4) -> [Date] {
        guard desiredCount > 1 else { return [domain.lowerBound] }
        let interval = domain.upperBound.timeIntervalSince(domain.lowerBound)
        guard interval > 0 else { return [domain.lowerBound] }
        let leadingInset = 0.07
        let trailingInset = 0.12
        let availableRatio = 1 - leadingInset - trailingInset
        return (0..<desiredCount).map { index in
            let progress = leadingInset + availableRatio * Double(index) / Double(desiredCount - 1)
            return domain.lowerBound.addingTimeInterval(interval * progress)
        }
    }

    nonisolated static func sampledPoints(from points: [BacktestSeriesPoint], maxCount: Int = 240) -> [BacktestSeriesPoint] {
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

    nonisolated static func normalizedComparisonPoints(
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
                .font(AppTypography.rowTitle)
                .foregroundStyle(AssetTheme.textPrimary)

            InteractiveBacktestChart(
                points: chartPoints,
                comparisonSeries: chartComparisonSeries,
                valueStyle: valueStyle,
                visibleSeriesIDs: effectiveVisibleSeriesIDs,
                placesViewportControlsAboveChart: true
            )
            .equatable()

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
                    .font(AppTypography.chartCaptionStrong)
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

struct AdvancedBacktestCombinedChartSection: View {
    let points: [BacktestSeriesPoint]
    let comparisonSeries: [BacktestChartComparisonSeries]
    let exposurePoints: [BacktestExposurePoint]
    let assetExposureSeries: [BacktestAssetExposureSeries]
    let averageExposureRatio: Double

    @State private var visibleValueSeriesIDs: Set<String> = []
    @State private var visibleExposureSeriesIDs: Set<String> = []
    @State private var visibleDateDomain: ClosedRange<Date>?
    @State private var showsLegend = false

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

    private var valueLegendItems: [BacktestChartLegendItem] {
        BacktestChartData.legendItems(for: chartComparisonSeries)
    }

    private var exposureLegendItems: [BacktestChartLegendItem] {
        let assets = assetExposureSeries.enumerated().map { index, series in
            BacktestChartLegendItem(
                id: BacktestExposureSeriesKey.asset(series.symbol),
                title: series.title,
                color: BacktestChartPalette.exposureLine(at: index),
                isDashed: false
            )
        }
        let total = BacktestChartLegendItem(
            id: BacktestExposureSeriesKey.total,
            title: AppLocalization.string("总仓位"),
            color: assetExposureSeries.isEmpty ? BacktestChartPalette.strategyLine : AssetTheme.textSecondary.opacity(0.72),
            isDashed: !assetExposureSeries.isEmpty
        )
        return assets + [total]
    }

    private var effectiveVisibleValueSeriesIDs: Set<String> {
        let available = Set(valueLegendItems.map(\.id))
        let selected = visibleValueSeriesIDs.intersection(available)
        return selected.isEmpty ? available : selected
    }

    private var effectiveVisibleExposureSeriesIDs: Set<String> {
        let available = Set(exposureLegendItems.map(\.id))
        let selected = visibleExposureSeriesIDs.intersection(available)
        return selected.isEmpty ? available : selected
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Text(AppLocalization.string("净值走势"))
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(AssetTheme.textPrimary)

                Spacer(minLength: 8)

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showsLegend.toggle()
                    }
                } label: {
                    Label(AppLocalization.string("图例"), systemImage: showsLegend ? "list.bullet.circle.fill" : "list.bullet.circle")
                        .font(AppTypography.chartCaptionStrong)
                        .foregroundStyle(showsLegend ? AssetTheme.gold : AssetTheme.textSecondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(AssetTheme.overlaySoft, in: Capsule())
                }
                .buttonStyle(.plain)
            }

            InteractiveBacktestChart(
                points: chartPoints,
                comparisonSeries: chartComparisonSeries,
                valueStyle: .currency(code: "CNY"),
                visibleSeriesIDs: effectiveVisibleValueSeriesIDs,
                placesViewportControlsAboveChart: false,
                onVisibleDateDomainChange: { domain in
                    visibleDateDomain = domain
                }
            )

            Divider()
                .overlay(AssetTheme.border.opacity(0.55))

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(AppLocalization.string(assetExposureSeries.isEmpty ? "持仓比例走势" : "资产持仓走势"))
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(AssetTheme.textPrimary)

                Spacer(minLength: 8)

                HStack(spacing: 5) {
                    Text(AppLocalization.string("平均仓位"))
                    Text(averageExposureRatio.percentString(maxFractionDigits: 0))
                        .foregroundStyle(AssetTheme.textPrimary)
                }
                .font(AppTypography.chartCaptionStrong)
                .foregroundStyle(AssetTheme.textSecondary)
                .monospacedDigit()
            }

            BacktestExposureChartSection(
                points: exposurePoints,
                assetSeries: assetExposureSeries,
                dateDomain: visibleDateDomain,
                visibleSeriesIDs: effectiveVisibleExposureSeriesIDs
            )

            if showsLegend {
                Divider()
                    .overlay(AssetTheme.border.opacity(0.45))

                VStack(alignment: .leading, spacing: 8) {
                    Text(AppLocalization.string("净值走势"))
                        .font(AppTypography.chartCaptionStrong)
                        .foregroundStyle(AssetTheme.textSecondary.opacity(0.72))

                    ATMFlowLayout(horizontalSpacing: 8, verticalSpacing: 8, rowAlignment: .center) {
                        ForEach(valueLegendItems) { item in
                            combinedLegendToggle(
                                item,
                                isVisible: effectiveVisibleValueSeriesIDs.contains(item.id),
                                canHide: effectiveVisibleValueSeriesIDs.count > 1,
                                isExposureSeries: false
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(AppLocalization.string(assetExposureSeries.isEmpty ? "持仓比例走势" : "资产持仓走势"))
                        .font(AppTypography.chartCaptionStrong)
                        .foregroundStyle(AssetTheme.textSecondary.opacity(0.72))
                        .padding(.top, 2)

                    ATMFlowLayout(horizontalSpacing: 8, verticalSpacing: 8, rowAlignment: .center) {
                        ForEach(exposureLegendItems) { item in
                            combinedLegendToggle(
                                item,
                                isVisible: effectiveVisibleExposureSeriesIDs.contains(item.id),
                                canHide: effectiveVisibleExposureSeriesIDs.count > 1,
                                isExposureSeries: true
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func combinedLegendToggle(
        _ item: BacktestChartLegendItem,
        isVisible: Bool,
        canHide: Bool,
        isExposureSeries: Bool
    ) -> some View {
        Button {
            guard !isVisible || canHide else { return }
            withAnimation(.easeInOut(duration: 0.18)) {
                if isExposureSeries {
                    visibleExposureSeriesIDs = toggledSeries(
                        item.id,
                        current: effectiveVisibleExposureSeriesIDs,
                        available: Set(exposureLegendItems.map(\.id))
                    )
                } else {
                    visibleValueSeriesIDs = toggledSeries(
                        item.id,
                        current: effectiveVisibleValueSeriesIDs,
                        available: Set(valueLegendItems.map(\.id))
                    )
                }
            }
        } label: {
            HStack(spacing: 6) {
                if item.isDashed {
                    Capsule()
                        .stroke(item.color, style: StrokeStyle(lineWidth: 2.2, dash: [5, 3]))
                        .frame(width: 20, height: 6)
                } else {
                    Circle()
                        .fill(item.color)
                        .frame(width: 8, height: 8)
                }

                Text(item.title)
                    .font(AppTypography.chartCaptionStrong)
                    .foregroundStyle(isVisible ? AssetTheme.textSecondary : AssetTheme.textSecondary.opacity(0.55))
                    .strikethrough(!isVisible, color: AssetTheme.textSecondary.opacity(0.7))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(isVisible ? AssetTheme.overlaySoft : AssetTheme.overlayFaint, in: Capsule())
            .overlay(Capsule().stroke(isVisible ? item.color.opacity(0.42) : AssetTheme.border.opacity(0.4), lineWidth: 1))
            .opacity(isVisible ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(isVisible && !canHide)
        .accessibilityLabel(item.title)
        .accessibilityHint(AppLocalization.string(isVisible ? "点击隐藏曲线" : "点击显示曲线"))
    }

    private func toggledSeries(
        _ id: String,
        current: Set<String>,
        available: Set<String>
    ) -> Set<String> {
        var next = current
        if next.contains(id) {
            guard next.count > 1 else { return next }
            next.remove(id)
        } else {
            next.insert(id)
        }
        return next.intersection(available)
    }
}

struct BacktestExposureChartSection: View {
    let points: [BacktestExposurePoint]
    let assetSeries: [BacktestAssetExposureSeries]
    var dateDomain: ClosedRange<Date>? = nil
    var visibleSeriesIDs: Set<String> = []

    private var chartPoints: [BacktestExposurePoint] {
        BacktestExposureSampling.sampled(points)
    }

    private var peakRatio: Double {
        points.map(\.ratio).max() ?? 0
    }

    private var sampledAssetSeries: [BacktestAssetExposureSeries] {
        assetSeries.map { series in
            BacktestAssetExposureSeries(
                symbol: series.symbol,
                title: series.title,
                points: BacktestExposureSampling.sampled(series.points)
            )
        }
    }

    private var yMaximum: Double {
        guard peakRatio > 1 else { return 1 }
        return max(ceil(peakRatio * 4) / 4, 1.25)
    }

    private var yAxisValues: [Double] {
        let step = yMaximum / 4
        return (0...4).map { Double($0) * step }
    }

    private var availableSeriesIDs: Set<String> {
        Set(assetSeries.map { BacktestExposureSeriesKey.asset($0.symbol) } + [BacktestExposureSeriesKey.total])
    }

    private var effectiveVisibleSeriesIDs: Set<String> {
        let selected = visibleSeriesIDs.intersection(availableSeriesIDs)
        return selected.isEmpty ? availableSeriesIDs : selected
    }

    private var resolvedDateDomain: ClosedRange<Date> {
        if let dateDomain { return dateDomain }
        let dates = points.map(\.date) + assetSeries.flatMap { $0.points.map(\.date) }
        guard let first = dates.min(), let last = dates.max() else {
            let fallback = Date()
            return fallback...fallback.addingTimeInterval(24 * 60 * 60)
        }
        return first == last ? first...first.addingTimeInterval(24 * 60 * 60) : first...last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Chart {
                if assetSeries.isEmpty, effectiveVisibleSeriesIDs.contains(BacktestExposureSeriesKey.total) {
                    ForEach(chartPoints) { point in
                        AreaMark(
                            x: .value(AppLocalization.string("日期"), point.date),
                            yStart: .value(AppLocalization.string("持仓比例"), 0),
                            yEnd: .value(AppLocalization.string("持仓比例"), point.ratio)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [BacktestChartPalette.strategyLine.opacity(0.24), BacktestChartPalette.strategyLine.opacity(0.025)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                        LineMark(
                            x: .value(AppLocalization.string("日期"), point.date),
                            y: .value(AppLocalization.string("持仓比例"), point.ratio)
                        )
                        .foregroundStyle(BacktestChartPalette.strategyLine)
                        .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                    }
                } else {
                    ForEach(Array(sampledAssetSeries.enumerated()), id: \.element.id) { index, series in
                        if effectiveVisibleSeriesIDs.contains(BacktestExposureSeriesKey.asset(series.symbol)) {
                            ForEach(series.points) { point in
                                LineMark(
                                    x: .value(AppLocalization.string("日期"), point.date),
                                    y: .value(AppLocalization.string("持仓比例"), point.ratio),
                                    series: .value(AppLocalization.string("资产"), series.symbol)
                                )
                                .foregroundStyle(BacktestChartPalette.exposureLine(at: index))
                                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                            }
                        }
                    }

                    if effectiveVisibleSeriesIDs.contains(BacktestExposureSeriesKey.total) {
                        ForEach(chartPoints) { point in
                            LineMark(
                                x: .value(AppLocalization.string("日期"), point.date),
                                y: .value(AppLocalization.string("持仓比例"), point.ratio),
                                series: .value(AppLocalization.string("资产"), "total-exposure")
                            )
                            .foregroundStyle(AssetTheme.textSecondary.opacity(0.72))
                            .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [4, 4]))
                        }
                    }
                }
            }
            .frame(height: 160)
            .chartXScale(domain: resolvedDateDomain)
            .chartXScale(range: .plotDimension(startPadding: 4, endPadding: 46))
            .chartYScale(domain: 0...yMaximum)
            .chartXAxis {
                AxisMarks(values: BacktestChartData.dateAxisValues(in: resolvedDateDomain)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.7, dash: [2, 4]))
                        .foregroundStyle(AssetTheme.border.opacity(0.35))
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(date, format: .dateTime.year())
                                .font(AppTypography.chartAxisCompact)
                                .foregroundStyle(AssetTheme.textSecondary)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: yAxisValues) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.7, dash: [2, 4]))
                        .foregroundStyle(AssetTheme.border.opacity(0.35))
                    AxisValueLabel {
                        if let ratio = value.as(Double.self) {
                            Text(ratio.percentString(maxFractionDigits: 0))
                                .font(AppTypography.chartAxisCompact)
                                .monospacedDigit()
                                .foregroundStyle(AssetTheme.textSecondary)
                        }
                    }
                }
            }
            .chartPlotStyle { plotArea in
                plotArea.clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(AppLocalization.string(assetSeries.isEmpty ? "持仓比例走势" : "资产持仓走势"))
        }
    }
}

struct BacktestAllocationSlice: Identifiable {
    let title: String
    let amount: Double
    let color: Color

    var id: String { title }
}

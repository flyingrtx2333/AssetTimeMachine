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
    private static let assetBenchmarkPrefix = "asset-benchmark-"

    static func assetBenchmark(_ symbol: String) -> String {
        "\(assetBenchmarkPrefix)\(symbol)"
    }

    static func assetSymbol(fromBenchmarkID id: String) -> String? {
        guard id.hasPrefix(assetBenchmarkPrefix) else { return nil }
        return String(id.dropFirst(assetBenchmarkPrefix.count))
    }
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

struct BacktestChartSelectionItem: Identifiable {
    let id: String
    let title: String
    let value: String
    let color: Color
}

private struct BacktestChartGuideGeometry: Equatable {
    let lowerX: CGFloat
    let upperX: CGFloat
    let selectedX: CGFloat
}

private struct BacktestChartGuideReporter: View {
    let proxy: ChartProxy
    let dateDomain: ClosedRange<Date>
    let selectedDate: Date
    @Binding var guideGeometry: BacktestChartGuideGeometry?

    var body: some View {
        GeometryReader { geometry in
            let resolvedGeometry = resolvedGuideGeometry(in: geometry)
            Color.clear
                .onAppear {
                    report(resolvedGeometry)
                }
                .onChange(of: resolvedGeometry) { _, newValue in
                    report(newValue)
                }
        }
        .allowsHitTesting(false)
    }

    private func resolvedGuideGeometry(in geometry: GeometryProxy) -> BacktestChartGuideGeometry? {
        guard let plotFrame = proxy.plotFrame,
              let lowerPlotX = proxy.position(forX: dateDomain.lowerBound),
              let upperPlotX = proxy.position(forX: dateDomain.upperBound),
              let selectedPlotX = proxy.position(forX: selectedDate) else {
            return nil
        }
        let frame = geometry[plotFrame]
        let lowerX = frame.minX + lowerPlotX
        let upperX = frame.minX + upperPlotX
        let selectedX = frame.minX + selectedPlotX
        guard lowerX.isFinite, upperX.isFinite, selectedX.isFinite else { return nil }
        return BacktestChartGuideGeometry(
            lowerX: min(lowerX, upperX),
            upperX: max(lowerX, upperX),
            selectedX: selectedX
        )
    }

    private func report(_ value: BacktestChartGuideGeometry?) {
        guard guideGeometry != value else { return }
        guideGeometry = value
    }
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
            Color(red: 0.16, green: 0.58, blue: 0.95),
            Color(red: 0.22, green: 0.72, blue: 0.45),
            Color(red: 0.74, green: 0.38, blue: 0.92),
            Color(red: 0.95, green: 0.32, blue: 0.31),
            Color(red: 0.10, green: 0.72, blue: 0.76),
            Color(red: 0.93, green: 0.63, blue: 0.18),
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
    var onVisibleDateDomainChange: ((ClosedRange<Date>) -> Void)? = nil
    var selection: Binding<Date?>? = nil
    var selectionItems: [BacktestChartSelectionItem] = []
    var showsDateRuler = false
    var keepsSelectionAfterInteraction = false
    @State private var localSelectedDate: Date?
    @State private var viewportStartRatio: Double = 0
    @State private var visibleSpanRatio: Double = 1
    @State private var chartGuideGeometry: BacktestChartGuideGeometry?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.valueStyle == rhs.valueStyle
            && lhs.visibleSeriesIDs == rhs.visibleSeriesIDs
            && lhs.showsDateRuler == rhs.showsDateRuler
            && lhs.keepsSelectionAfterInteraction == rhs.keepsSelectionAfterInteraction
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

    private var activeSelectedDate: Date? {
        selection?.wrappedValue ?? localSelectedDate
    }

    private var activeSelectionBinding: Binding<Date?> {
        Binding(
            get: { activeSelectedDate },
            set: { updateSelection($0) }
        )
    }

    private var selectedPoint: BacktestSeriesPoint? {
        let activePoints = interactionPoints
        guard let selectedDate = activeSelectedDate else { return activePoints.last }
        return Self.nearestPoint(to: selectedDate, in: activePoints)
    }

    private var selectedPopoverAlignment: Alignment {
        guard let selectedPoint else { return .topLeading }
        let midpoint = chartDateDomain.lowerBound.addingTimeInterval(
            chartDateDomain.upperBound.timeIntervalSince(chartDateDomain.lowerBound) / 2
        )
        return selectedPoint.date >= midpoint ? .topTrailing : .topLeading
    }

    private var resolvedSelectionItems: [BacktestChartSelectionItem] {
        if !selectionItems.isEmpty { return selectionItems }
        guard let selectedPoint else { return [] }
        let title: String
        if interactionSeriesID == BacktestChartSeriesKey.strategy {
            title = BacktestChartSeriesTitle.strategy
        } else {
            title = resolvedComparisonSeries.first(where: { $0.id == interactionSeriesID })?.title
                ?? AppLocalization.string("资产")
        }
        return [
            BacktestChartSelectionItem(
                id: interactionSeriesID ?? BacktestChartSeriesKey.strategy,
                title: title,
                value: valueStyle.label(for: selectedPoint.portfolioValue),
                color: interactionColor
            )
        ]
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

    private func clampSelectionToVisibleDomain() {
        guard let selectedDate = activeSelectedDate,
              let domain = visibleDateDomain,
              selectedDate < domain.lowerBound || selectedDate > domain.upperBound else {
            return
        }
        let boundaryDate = selectedDate < domain.lowerBound ? domain.lowerBound : domain.upperBound
        updateSelection(Self.nearestPoint(to: boundaryDate, in: interactionPoints)?.date)
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
        updateSelection(nil)
    }

    private func updateSelection(_ date: Date?) {
        if let selection {
            selection.wrappedValue = date
        } else {
            localSelectedDate = date
        }
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

        if activeSelectedDate != nil, let selectedPoint {
            RuleMark(x: .value(AppLocalization.string("选中日期"), selectedPoint.date))
                .foregroundStyle(AssetTheme.gold.opacity(0.72))
                .lineStyle(StrokeStyle(lineWidth: 1))
                .annotation(position: .overlay, alignment: selectedPopoverAlignment, spacing: 7) {
                    selectedValuePopover
                }
        }
    }

    private var selectedValuePopover: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(selectedPoint?.date.chartAxisDateString ?? "--")
                .font(.system(size: 11, weight: .semibold, design: .default))
                .monospacedDigit()
                .foregroundStyle(AssetTheme.textSecondary)

            Rectangle()
                .fill(AssetTheme.border.opacity(0.46))
                .frame(height: 1)

            ForEach(resolvedSelectionItems) { item in
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
                        .minimumScaleFactor(0.7)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: AppLocalization.currentLanguage == .english ? 216 : 192)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .background(AssetTheme.surface.opacity(0.78), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AssetTheme.border.opacity(0.9), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.24), radius: 12, y: 5)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var dateNavigator: some View {
        if showsDateRuler, let selectedPoint {
            VStack(spacing: 5) {
                Text(selectedPoint.date.longDateString)
                    .font(.system(size: 15, weight: .semibold, design: .default))
                    .monospacedDigit()
                    .foregroundStyle(AssetTheme.gold)

                Image(systemName: "triangle.fill")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(180))
                    .foregroundStyle(AssetTheme.gold)

                BacktestDateRuler(
                    dates: interactionPoints.map(\.date),
                    dateDomain: chartDateDomain,
                    guideGeometry: chartGuideGeometry,
                    selectedDate: activeSelectionBinding
                )
            }
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

        VStack(alignment: .trailing, spacing: 8) {
            viewportControls

            dateNavigator

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
                ZStack {
                    TimeMachineDragOverlay(
                        proxy: proxy,
                        selectableValues: interactionPoints,
                        selectionDate: \.date
                    ) { date in
                        updateSelection(date)
                    } onEnded: {
                        if !keepsSelectionAfterInteraction {
                            updateSelection(nil)
                        }
                    }

                    if let selectedPoint {
                        BacktestChartGuideReporter(
                            proxy: proxy,
                            dateDomain: xDomain,
                            selectedDate: selectedPoint.date,
                            guideGeometry: $chartGuideGeometry
                        )
                    }
                }
            }
        }
        .onChange(of: points.count) { _, _ in
            clampViewport()
            publishVisibleDateDomain()
        }
        .onChange(of: visibleSeriesIDs) { _, _ in
            clampViewport()
            clampSelectionToVisibleDomain()
            publishVisibleDateDomain()
        }
        .onChange(of: viewportStartRatio) { _, _ in
            clampSelectionToVisibleDomain()
            publishVisibleDateDomain()
        }
        .onChange(of: visibleSpanRatio) { _, _ in
            clampSelectionToVisibleDomain()
            publishVisibleDateDomain()
        }
        .onAppear {
            publishVisibleDateDomain()
        }
    }

}

private enum BacktestDateRulerLayout {
    static let plotLeadingInset: CGFloat = 54
    static let plotTrailingInset: CGFloat = 46
}

private struct BacktestDateRuler: View {
    let dates: [Date]
    let dateDomain: ClosedRange<Date>
    let guideGeometry: BacktestChartGuideGeometry?
    @Binding var selectedDate: Date?

    private var availableDates: [Date] {
        dates
            .filter { $0 >= dateDomain.lowerBound && $0 <= dateDomain.upperBound }
            .sorted()
    }

    private var labelDates: [Date] {
        let points = availableDates
        guard points.count > 1 else { return points }
        let preferredCount = AppLocalization.currentLanguage == .english ? 5 : 6
        let desiredCount = min(preferredCount, max(2, points.count))
        let lastIndex = points.count - 1
        return (0..<desiredCount).map { offset in
            let ratio = Double(offset) / Double(desiredCount - 1)
            return points[Int((Double(lastIndex) * ratio).rounded())]
        }
    }

    private var resolvedSelectedDate: Date {
        selectedDate.flatMap(nearestDate(to:)) ?? availableDates.last ?? dateDomain.upperBound
    }

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)

            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    let baselineY: CGFloat = 24
                    let plotRange = resolvedPlotRange(width: size.width)
                    var baseline = Path()
                    baseline.move(to: CGPoint(x: plotRange.lowerBound, y: baselineY))
                    baseline.addLine(to: CGPoint(x: plotRange.upperBound, y: baselineY))
                    context.stroke(
                        baseline,
                        with: .color(AssetTheme.textSecondary.opacity(0.18)),
                        lineWidth: 0.6
                    )

                    let tickCount = 84
                    let availableWidth = max(plotRange.upperBound - plotRange.lowerBound, 1)
                    for index in 0...tickCount {
                        let x = plotRange.lowerBound
                            + availableWidth * CGFloat(index) / CGFloat(tickCount)
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

                    if selectedDate != nil {
                        let selectionX = resolvedSelectionX(width: size.width)
                        var selectionGuide = Path()
                        selectionGuide.move(to: CGPoint(x: selectionX, y: baselineY))
                        selectionGuide.addLine(to: CGPoint(x: selectionX, y: size.height))
                        context.stroke(
                            selectionGuide,
                            with: .color(AssetTheme.gold.opacity(0.76)),
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
                            y: 5
                        )
                }

                selectionMarker
                    .position(
                        x: resolvedSelectionX(width: width),
                        y: 24
                    )

                if selectedDate != nil {
                    Rectangle()
                        .fill(AssetTheme.gold.opacity(0.76))
                        .frame(width: 1, height: 10)
                        .position(
                            x: resolvedSelectionX(width: width),
                            y: geometry.size.height + 5
                        )
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .overlay {
                TimeMachineHorizontalPanGestureView { location in
                    updateSelection(at: location.x, width: width)
                } onEnded: {}
            }
        }
        .frame(height: 52)
        .accessibilityLabel(AppLocalization.string("选择历史日期"))
    }

    private var selectionMarker: some View {
        Circle()
            .fill(AssetTheme.gold.opacity(0.18))
            .frame(width: 21, height: 21)
            .overlay(Circle().stroke(AssetTheme.goldSoft.opacity(0.42), lineWidth: 1))
            .overlay {
                Circle()
                    .fill(AssetTheme.goldSoft)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(AssetTheme.textPrimary.opacity(0.92), lineWidth: 1.1))
            }
            .shadow(color: AssetTheme.gold.opacity(0.28), radius: 7)
    }

    private func xPosition(for date: Date, width: CGFloat) -> CGFloat {
        let duration = max(dateDomain.upperBound.timeIntervalSince(dateDomain.lowerBound), 1)
        let progress = min(max(date.timeIntervalSince(dateDomain.lowerBound) / duration, 0), 1)
        let plotRange = resolvedPlotRange(width: width)
        let availableWidth = max(plotRange.upperBound - plotRange.lowerBound, 1)
        return plotRange.lowerBound + availableWidth * progress
    }

    private func resolvedSelectionX(width: CGFloat) -> CGFloat {
        if let selectedX = guideGeometry?.selectedX, selectedX.isFinite {
            return min(max(selectedX, 0), width)
        }
        return xPosition(for: resolvedSelectedDate, width: width)
    }

    private func resolvedPlotRange(width: CGFloat) -> ClosedRange<CGFloat> {
        if let guideGeometry,
           guideGeometry.lowerX.isFinite,
           guideGeometry.upperX.isFinite,
           guideGeometry.upperX > guideGeometry.lowerX {
            return min(max(guideGeometry.lowerX, 0), width)...min(max(guideGeometry.upperX, 0), width)
        }
        let lowerBound = BacktestDateRulerLayout.plotLeadingInset
        let upperBound = max(
            width - BacktestDateRulerLayout.plotTrailingInset,
            lowerBound + 1
        )
        return lowerBound...upperBound
    }

    private func clampedLabelX(for date: Date, width: CGFloat) -> CGFloat {
        min(max(xPosition(for: date, width: width), 28), width - 28)
    }

    private func updateSelection(at x: CGFloat, width: CGFloat) {
        guard !availableDates.isEmpty else { return }
        let plotRange = resolvedPlotRange(width: width)
        let availableWidth = max(plotRange.upperBound - plotRange.lowerBound, 1)
        let progress = min(
            max((x - plotRange.lowerBound) / availableWidth, 0),
            1
        )
        let targetDate = dateDomain.lowerBound.addingTimeInterval(
            dateDomain.upperBound.timeIntervalSince(dateDomain.lowerBound) * Double(progress)
        )
        selectedDate = nearestDate(to: targetDate)
    }

    private func nearestDate(to targetDate: Date) -> Date? {
        let sortedDates = availableDates
        guard !sortedDates.isEmpty else { return nil }
        var lowerBound = 0
        var upperBound = sortedDates.count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if sortedDates[middle] < targetDate {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        guard lowerBound > 0 else { return sortedDates[0] }
        guard lowerBound < sortedDates.count else { return sortedDates[sortedDates.count - 1] }
        let previous = sortedDates[lowerBound - 1]
        let next = sortedDates[lowerBound]
        return abs(previous.timeIntervalSince(targetDate)) <= abs(next.timeIntervalSince(targetDate))
            ? previous
            : next
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
                showsDateRuler: true,
                keepsSelectionAfterInteraction: true
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

private struct CombinedBacktestLegendItem: Identifiable {
    let id: String
    let title: String
    let color: Color
    let isDashed: Bool
    let valueSeriesID: String?
    let exposureSeriesID: String?
}

struct AdvancedBacktestCombinedChartSection: View {
    let points: [BacktestSeriesPoint]
    let comparisonSeries: [BacktestChartComparisonSeries]
    let exposurePoints: [BacktestExposurePoint]
    let assetExposureSeries: [BacktestAssetExposureSeries]
    let averageExposureRatio: Double

    @State private var hiddenLegendItemIDs: Set<String> = []
    @State private var visibleDateDomain: ClosedRange<Date>?
    @State private var showsLegend = false
    @State private var selectedDate: Date?

    private var chartPoints: [BacktestSeriesPoint] {
        BacktestChartData.sampledPoints(from: points)
    }

    private var chartComparisonSeries: [BacktestChartComparisonSeries] {
        comparisonSeries.compactMap { series in
            let sampledPoints = BacktestChartData.sampledPoints(from: series.points)
            guard !sampledPoints.isEmpty else { return nil }
            let symbol = BacktestChartSeriesKey.assetSymbol(fromBenchmarkID: series.id)
            return BacktestChartComparisonSeries(
                id: series.id,
                title: series.title,
                points: sampledPoints,
                color: symbol.flatMap { assetColors[$0] } ?? series.color
            )
        }
    }

    private var chartAssetExposureSeries: [BacktestAssetExposureSeries] {
        var seenSymbols: Set<String> = []
        return assetExposureSeries.filter { seenSymbols.insert($0.symbol).inserted }
    }

    private var assetSymbols: [String] {
        var symbols: [String] = []
        for series in chartAssetExposureSeries where !symbols.contains(series.symbol) {
            symbols.append(series.symbol)
        }
        for series in comparisonSeries {
            guard let symbol = BacktestChartSeriesKey.assetSymbol(fromBenchmarkID: series.id),
                  !symbols.contains(symbol) else { continue }
            symbols.append(symbol)
        }
        return symbols
    }

    private var assetColors: [String: Color] {
        Dictionary(uniqueKeysWithValues: assetSymbols.enumerated().map { index, symbol in
            (symbol, BacktestChartPalette.exposureLine(at: index))
        })
    }

    private var legendItems: [CombinedBacktestLegendItem] {
        var items = [CombinedBacktestLegendItem(
            id: "combined.strategy",
            title: BacktestChartSeriesTitle.strategy,
            color: BacktestChartPalette.strategyLine,
            isDashed: false,
            valueSeriesID: BacktestChartSeriesKey.strategy,
            exposureSeriesID: nil
        )]

        for symbol in assetSymbols {
            let comparison = chartComparisonSeries.first {
                BacktestChartSeriesKey.assetSymbol(fromBenchmarkID: $0.id) == symbol
            }
            let exposure = chartAssetExposureSeries.first { $0.symbol == symbol }
            items.append(CombinedBacktestLegendItem(
                id: "combined.asset.\(symbol)",
                title: exposure?.title ?? comparison?.title ?? symbol,
                color: assetColors[symbol] ?? BacktestChartPalette.exposureLine(at: items.count - 1),
                isDashed: false,
                valueSeriesID: comparison?.id,
                exposureSeriesID: exposure.map { BacktestExposureSeriesKey.asset($0.symbol) }
            ))
        }

        items.append(contentsOf: chartComparisonSeries.compactMap { series in
            guard BacktestChartSeriesKey.assetSymbol(fromBenchmarkID: series.id) == nil else { return nil }
            return CombinedBacktestLegendItem(
                id: "combined.value.\(series.id)",
                title: series.title,
                color: series.color,
                isDashed: true,
                valueSeriesID: series.id,
                exposureSeriesID: nil
            )
        })

        if !exposurePoints.isEmpty || !chartAssetExposureSeries.isEmpty {
            items.append(CombinedBacktestLegendItem(
                id: "combined.exposure.total",
                title: AppLocalization.string("总仓位"),
                color: chartAssetExposureSeries.isEmpty
                    ? BacktestChartPalette.strategyLine
                    : AssetTheme.textSecondary.opacity(0.72),
                isDashed: !assetExposureSeries.isEmpty,
                valueSeriesID: nil,
                exposureSeriesID: BacktestExposureSeriesKey.total
            ))
        }

        return items
    }

    private var effectiveVisibleValueSeriesIDs: Set<String> {
        Set(legendItems.compactMap { item in
            hiddenLegendItemIDs.contains(item.id) ? nil : item.valueSeriesID
        })
    }

    private var effectiveVisibleExposureSeriesIDs: Set<String> {
        Set(legendItems.compactMap { item in
            hiddenLegendItemIDs.contains(item.id) ? nil : item.exposureSeriesID
        })
    }

    private var selectedAmountItems: [BacktestChartSelectionItem] {
        guard let selectedDate,
              let portfolioPoint = nearestChartPoint(points, to: selectedDate, date: \.date) else {
            return []
        }

        let portfolioValue = portfolioPoint.portfolioValue
        var items = [
            BacktestChartSelectionItem(
                id: BacktestChartSeriesKey.strategy,
                title: BacktestChartSeriesTitle.strategy,
                value: portfolioValue.currencyString(code: "CNY"),
                color: BacktestChartPalette.strategyLine
            )
        ]

        if chartAssetExposureSeries.isEmpty {
            if let exposurePoint = nearestChartPoint(exposurePoints, to: selectedDate, date: \.date) {
                let ratio = max(exposurePoint.ratio, 0)
                items.append(
                    BacktestChartSelectionItem(
                        id: BacktestExposureSeriesKey.total,
                        title: AppLocalization.string("资产"),
                        value: (portfolioValue * ratio).currencyString(code: "CNY"),
                        color: BacktestChartPalette.strategyLine
                    )
                )
                items.append(
                    BacktestChartSelectionItem(
                        id: "selection.cash",
                        title: AppLocalization.string("现金"),
                        value: (portfolioValue * (1 - ratio)).currencyString(code: "CNY"),
                        color: AssetTheme.textSecondary
                    )
                )
            }
            return items
        }

        var totalAssetRatio = 0.0
        for series in chartAssetExposureSeries {
            let seriesID = BacktestExposureSeriesKey.asset(series.symbol)
            guard let exposurePoint = nearestChartPoint(series.points, to: selectedDate, date: \.date) else {
                continue
            }
            let ratio = max(exposurePoint.ratio, 0)
            totalAssetRatio += ratio
            guard effectiveVisibleExposureSeriesIDs.contains(seriesID) else { continue }
            items.append(
                BacktestChartSelectionItem(
                    id: seriesID,
                    title: series.title,
                    value: (portfolioValue * ratio).currencyString(code: "CNY"),
                    color: assetColors[series.symbol] ?? BacktestChartPalette.exposureLine(at: items.count - 1)
                )
            )
        }

        items.append(
            BacktestChartSelectionItem(
                id: "selection.cash",
                title: AppLocalization.string("现金"),
                value: (portfolioValue * (1 - totalAssetRatio)).currencyString(code: "CNY"),
                color: AssetTheme.textSecondary
            )
        )
        return items
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
                onVisibleDateDomainChange: { domain in
                    visibleDateDomain = domain
                },
                selection: $selectedDate,
                selectionItems: selectedAmountItems,
                showsDateRuler: true,
                keepsSelectionAfterInteraction: true
            )

            Divider()
                .overlay(AssetTheme.border.opacity(0.55))

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(AppLocalization.string(chartAssetExposureSeries.isEmpty ? "持仓比例走势" : "资产持仓走势"))
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
                assetSeries: chartAssetExposureSeries,
                dateDomain: visibleDateDomain,
                visibleSeriesIDs: effectiveVisibleExposureSeriesIDs,
                assetColors: assetColors,
                selectedDate: selectedDate
            )

            if showsLegend {
                Divider()
                    .overlay(AssetTheme.border.opacity(0.45))

                ATMFlowLayout(horizontalSpacing: 8, verticalSpacing: 8, rowAlignment: .center) {
                    ForEach(legendItems) { item in
                        combinedLegendToggle(item)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onChange(of: legendItems.map(\.id)) { _, itemIDs in
            hiddenLegendItemIDs.formIntersection(itemIDs)
        }
        #if DEBUG
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("-backtestSelectChartPoint"),
               selectedDate == nil,
               !points.isEmpty {
                selectedDate = points[points.count / 2].date
            }
        }
        #endif
    }

    private func combinedLegendToggle(_ item: CombinedBacktestLegendItem) -> some View {
        let isVisible = !hiddenLegendItemIDs.contains(item.id)
        let canHide = canHide(item)

        return Button {
            guard !isVisible || canHide else { return }
            withAnimation(.easeInOut(duration: 0.18)) {
                if isVisible {
                    hiddenLegendItemIDs.insert(item.id)
                } else {
                    hiddenLegendItemIDs.remove(item.id)
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

    private func canHide(_ item: CombinedBacktestLegendItem) -> Bool {
        let visibleItems = legendItems.filter { !hiddenLegendItemIDs.contains($0.id) }
        if item.valueSeriesID != nil,
           visibleItems.filter({ $0.valueSeriesID != nil }).count <= 1 {
            return false
        }
        if item.exposureSeriesID != nil,
           visibleItems.filter({ $0.exposureSeriesID != nil }).count <= 1 {
            return false
        }
        return true
    }
}

struct BacktestExposureChartSection: View {
    let points: [BacktestExposurePoint]
    let assetSeries: [BacktestAssetExposureSeries]
    var dateDomain: ClosedRange<Date>? = nil
    var visibleSeriesIDs: Set<String> = []
    var assetColors: [String: Color] = [:]
    var selectedDate: Date? = nil

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

    @ChartContentBuilder
    private var exposureMarks: some ChartContent {
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
                        .foregroundStyle(assetColors[series.symbol] ?? BacktestChartPalette.exposureLine(at: index))
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

    @ChartContentBuilder
    private var selectionMarks: some ChartContent {
        if let selectedDate {
            RuleMark(x: .value(AppLocalization.string("选中日期"), selectedDate))
                .foregroundStyle(AssetTheme.gold.opacity(0.72))
                .lineStyle(StrokeStyle(lineWidth: 1))

            if assetSeries.isEmpty {
                if effectiveVisibleSeriesIDs.contains(BacktestExposureSeriesKey.total),
                   let selectedPoint = nearestChartPoint(points, to: selectedDate, date: \.date) {
                    PointMark(
                        x: .value(AppLocalization.string("日期"), selectedPoint.date),
                        y: .value(AppLocalization.string("持仓比例"), selectedPoint.ratio)
                    )
                    .foregroundStyle(BacktestChartPalette.strategyLine)
                    .symbolSize(42)
                }
            } else {
                ForEach(Array(assetSeries.enumerated()), id: \.element.id) { index, series in
                    if effectiveVisibleSeriesIDs.contains(BacktestExposureSeriesKey.asset(series.symbol)),
                       let selectedPoint = nearestChartPoint(series.points, to: selectedDate, date: \.date) {
                        PointMark(
                            x: .value(AppLocalization.string("日期"), selectedPoint.date),
                            y: .value(AppLocalization.string("持仓比例"), selectedPoint.ratio)
                        )
                        .foregroundStyle(assetColors[series.symbol] ?? BacktestChartPalette.exposureLine(at: index))
                        .symbolSize(38)
                    }
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Chart {
                exposureMarks
                selectionMarks
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
                                .frame(width: 42, alignment: .trailing)
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

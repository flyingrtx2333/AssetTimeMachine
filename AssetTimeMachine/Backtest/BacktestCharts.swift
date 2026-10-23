import AssetTimeMachineBacktestCore
import SwiftUI
import SwiftData
import Charts
import UIKit
import Combine

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

private struct BacktestChartPlotBounds: Equatable {
    let lowerX: CGFloat
    let upperX: CGFloat
}

private struct BacktestChartGuideReporter: View {
    let proxy: ChartProxy
    let dateDomain: ClosedRange<Date>
    @Binding var guideBounds: BacktestChartPlotBounds?

    var body: some View {
        GeometryReader { geometry in
            let resolvedBounds = resolvedPlotBounds(in: geometry)
            Color.clear
                .onAppear {
                    report(resolvedBounds)
                }
                .onChange(of: resolvedBounds) { _, newValue in
                    report(newValue)
                }
        }
        .allowsHitTesting(false)
    }

    private func resolvedPlotBounds(in geometry: GeometryProxy) -> BacktestChartPlotBounds? {
        guard let plotFrame = proxy.plotFrame,
              let lowerPlotX = proxy.position(forX: dateDomain.lowerBound),
              let upperPlotX = proxy.position(forX: dateDomain.upperBound) else {
            return nil
        }
        let frame = geometry[plotFrame]
        let lowerX = frame.minX + lowerPlotX
        let upperX = frame.minX + upperPlotX
        guard lowerX.isFinite, upperX.isFinite else { return nil }
        return BacktestChartPlotBounds(
            lowerX: min(lowerX, upperX),
            upperX: max(lowerX, upperX)
        )
    }

    private func report(_ value: BacktestChartPlotBounds?) {
        guard guideBounds != value else { return }
        guideBounds = value
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

@MainActor
final class BacktestChartSelectionCoordinator: ObservableObject {
    @Published var selectedDate: Date? = nil

    init(initialDate: Date? = nil) {
        self.selectedDate = initialDate
    }
}

private func seriesIdentityMatches(
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

private func comparisonIdentityMatches(
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

struct InteractiveBacktestChart: View, Equatable {
    let points: [BacktestSeriesPoint]
    var comparisonPoints: [BacktestSeriesPoint] = []
    var comparisonSeries: [BacktestChartComparisonSeries] = []
    var valueStyle: BacktestChartValueStyle = .multiple
    var visibleSeriesIDs: Set<String> = []
    var onVisibleDateDomainChange: ((ClosedRange<Date>) -> Void)? = nil
    var selectionDate: Date? = nil
    var onSelectionChange: ((Date?) -> Void)? = nil
    var selectionItems: [BacktestChartSelectionItem] = []
    var selectionItemsProvider: ((Date) -> [BacktestChartSelectionItem])? = nil
    var showsDateRuler = false
    var showsXAxis = true
    var keepsSelectionAfterInteraction = false
    var selectionCoordinator: BacktestChartSelectionCoordinator? = nil

    @StateObject private var internalCoordinator = BacktestChartSelectionCoordinator()
    @State private var viewportStartRatio: Double = 0
    @State private var visibleSpanRatio: Double = 1
    @State private var chartGuideBounds: BacktestChartPlotBounds?
    @State private var pinchStartSpanRatio: Double?
    @State private var pinchStartViewportStartRatio: Double?
    @State private var pinchAnchorRatio: Double = 0.5

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.valueStyle == rhs.valueStyle
            && lhs.visibleSeriesIDs == rhs.visibleSeriesIDs
            && lhs.showsDateRuler == rhs.showsDateRuler
            && lhs.showsXAxis == rhs.showsXAxis
            && lhs.keepsSelectionAfterInteraction == rhs.keepsSelectionAfterInteraction
            && lhs.selectionDate == rhs.selectionDate
            && seriesIdentityMatches(lhs.points, rhs.points)
            && seriesIdentityMatches(lhs.comparisonPoints, rhs.comparisonPoints)
            && comparisonIdentityMatches(lhs.comparisonSeries, rhs.comparisonSeries)
    }

    private var activeCoordinator: BacktestChartSelectionCoordinator {
        selectionCoordinator ?? internalCoordinator
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

    private var hasAdjustedViewport: Bool {
        canZoomOut || canPanLeft || canPanRight
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
        guard let selectedDate = activeCoordinator.selectedDate,
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

    private func updateViewportMagnification(_ value: MagnifyGesture.Value) {
        guard canShowViewportControls else { return }

        if pinchStartSpanRatio == nil {
            pinchStartSpanRatio = visibleSpanRatio
            pinchStartViewportStartRatio = viewportStartRatio
            pinchAnchorRatio = min(max(Double(value.startAnchor.x), 0), 1)
        }

        guard let startSpan = pinchStartSpanRatio,
              let startViewport = pinchStartViewportStartRatio else { return }
        let scale = max(Double(value.magnification), 0.01)
        let nextSpan = min(max(startSpan / scale, minVisibleSpanRatio), 1)
        let anchoredRatio = startViewport + startSpan * pinchAnchorRatio
        visibleSpanRatio = nextSpan
        viewportStartRatio = min(
            max(anchoredRatio - nextSpan * pinchAnchorRatio, 0),
            max(1 - nextSpan, 0)
        )
    }

    private func finishViewportMagnification() {
        pinchStartSpanRatio = nil
        pinchStartViewportStartRatio = nil
        clampViewport()
    }

    private var viewportMagnifyGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                updateViewportMagnification(value)
            }
            .onEnded { _ in
                finishViewportMagnification()
            }
    }

    private func updateSelection(_ date: Date?) {
        activeCoordinator.selectedDate = date
        onSelectionChange?(date)
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

    static func nearestPoint(to date: Date, in points: [BacktestSeriesPoint]) -> BacktestSeriesPoint? {
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
        let coordinator = activeCoordinator

        VStack(alignment: .trailing, spacing: 8) {
            if !showsDateRuler {
                viewportControls
            }

            if showsDateRuler {
                InteractiveBacktestDateNavigator(
                    coordinator: coordinator,
                    points: interactionPoints,
                    dateDomain: xDomain,
                    guideBounds: chartGuideBounds,
                    canPanLeft: canPanLeft,
                    canPanRight: canPanRight,
                    hasAdjustedViewport: hasAdjustedViewport,
                    onPanLeft: {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            panViewport(by: -0.38)
                        }
                    },
                    onPanRight: {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            panViewport(by: 0.38)
                        }
                    },
                    onReset: {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            resetViewport()
                        }
                    },
                    onSelectionChange: onSelectionChange
                )
            }

            InteractiveBacktestChartCurves(
                points: points,
                comparisonSeries: comparisonSeries,
                visibleSeriesIDs: visibleSeriesIDs,
                domain: domain,
                strategySeries: strategySeries,
                xDomain: xDomain,
                showsXAxis: showsXAxis,
                valueStyle: valueStyle,
                foregroundStyleDomain: foregroundStyleDomain,
                foregroundStyleRange: foregroundStyleRange,
                viewportStartRatio: viewportStartRatio,
                visibleSpanRatio: visibleSpanRatio,
                pinchStartSpanRatio: pinchStartSpanRatio,
                coordinator: coordinator,
                interactionPoints: interactionPoints,
                interactionColor: interactionColor,
                valueStyleForSelection: valueStyle,
                interactionSeriesID: interactionSeriesID,
                resolvedComparisonSeries: comparisonSeries,
                selectionItems: selectionItems,
                selectionItemsProvider: selectionItemsProvider,
                keepsSelectionAfterInteraction: keepsSelectionAfterInteraction,
                chartGuideBounds: $chartGuideBounds,
                onSelectionChange: onSelectionChange
            )
            .equatable()
        }
        .simultaneousGesture(viewportMagnifyGesture)
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
        .onChange(of: selectionDate) { _, newDate in
            if coordinator.selectedDate != newDate {
                coordinator.selectedDate = newDate
            }
        }
        .onAppear {
            if let selectionDate, coordinator.selectedDate == nil {
                coordinator.selectedDate = selectionDate
            }
            publishVisibleDateDomain()
        }
    }
}

private struct InteractiveBacktestDateNavigator: View {
    @ObservedObject var coordinator: BacktestChartSelectionCoordinator
    let points: [BacktestSeriesPoint]
    let dateDomain: ClosedRange<Date>
    let guideBounds: BacktestChartPlotBounds?
    let canPanLeft: Bool
    let canPanRight: Bool
    let hasAdjustedViewport: Bool
    let onPanLeft: () -> Void
    let onPanRight: () -> Void
    let onReset: () -> Void
    var onSelectionChange: ((Date?) -> Void)? = nil

    private var selectedPoint: BacktestSeriesPoint? {
        guard let selectedDate = coordinator.selectedDate else { return points.last }
        return InteractiveBacktestChart.nearestPoint(to: selectedDate, in: points)
    }

    var body: some View {
        if let selectedPoint {
            VStack(spacing: 5) {
                HStack(spacing: 8) {
                    dateRowViewportButton(
                        systemImage: "chevron.left",
                        accessibilityLabel: AppLocalization.string("图表左移"),
                        isEnabled: canPanLeft,
                        action: onPanLeft
                    )

                    Spacer(minLength: 6)

                    HStack(spacing: 6) {
                        Text(selectedPoint.date.longDateString)
                            .font(.system(size: 15, weight: .semibold, design: .default))
                            .monospacedDigit()
                            .foregroundStyle(AssetTheme.gold)

                        if hasAdjustedViewport {
                            Button(action: onReset) {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(AssetTheme.textSecondary)
                                    .frame(width: 22, height: 22)
                                    .background(AssetTheme.overlaySoft.opacity(0.72), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(AppLocalization.string("重置图表视图"))
                        }
                    }

                    Spacer(minLength: 6)

                    dateRowViewportButton(
                        systemImage: "chevron.right",
                        accessibilityLabel: AppLocalization.string("图表右移"),
                        isEnabled: canPanRight,
                        action: onPanRight
                    )
                }
                .frame(maxWidth: .infinity)

                Image(systemName: "triangle.fill")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(180))
                    .foregroundStyle(AssetTheme.gold)

                BacktestDateRuler(
                    points: points,
                    dateDomain: dateDomain,
                    guideBounds: guideBounds,
                    selectedDate: Binding(
                        get: { coordinator.selectedDate },
                        set: {
                            coordinator.selectedDate = $0
                            onSelectionChange?($0)
                        }
                    )
                )
            }
        }
    }

    private func dateRowViewportButton(
        systemImage: String,
        accessibilityLabel: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isEnabled ? AssetTheme.textPrimary : AssetTheme.textSecondary.opacity(0.30))
                .frame(width: 30, height: 28)
                .background(AssetTheme.overlaySoft.opacity(isEnabled ? 0.72 : 0.34), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct InteractiveBacktestChartCurves: View, Equatable {
    let points: [BacktestSeriesPoint]
    let comparisonSeries: [BacktestChartComparisonSeries]
    let visibleSeriesIDs: Set<String>
    let domain: ClosedRange<Double>
    let strategySeries: String
    let xDomain: ClosedRange<Date>
    let showsXAxis: Bool
    let valueStyle: BacktestChartValueStyle
    let foregroundStyleDomain: [String]
    let foregroundStyleRange: [Color]
    let viewportStartRatio: Double
    let visibleSpanRatio: Double
    let pinchStartSpanRatio: Double?

    let coordinator: BacktestChartSelectionCoordinator
    let interactionPoints: [BacktestSeriesPoint]
    let interactionColor: Color
    let valueStyleForSelection: BacktestChartValueStyle
    let interactionSeriesID: String?
    let resolvedComparisonSeries: [BacktestChartComparisonSeries]
    let selectionItems: [BacktestChartSelectionItem]
    let selectionItemsProvider: ((Date) -> [BacktestChartSelectionItem])?
    let keepsSelectionAfterInteraction: Bool
    @Binding var chartGuideBounds: BacktestChartPlotBounds?
    var onSelectionChange: ((Date?) -> Void)? = nil

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.visibleSeriesIDs == rhs.visibleSeriesIDs
            && lhs.xDomain == rhs.xDomain
            && lhs.domain == rhs.domain
            && lhs.showsXAxis == rhs.showsXAxis
            && lhs.valueStyle == rhs.valueStyle
            && lhs.viewportStartRatio == rhs.viewportStartRatio
            && lhs.visibleSpanRatio == rhs.visibleSpanRatio
            && lhs.pinchStartSpanRatio == rhs.pinchStartSpanRatio
            && lhs.foregroundStyleDomain == rhs.foregroundStyleDomain
            && lhs.foregroundStyleRange == rhs.foregroundStyleRange
            && seriesIdentityMatches(lhs.points, rhs.points)
            && comparisonIdentityMatches(lhs.comparisonSeries, rhs.comparisonSeries)
    }

    @ChartContentBuilder
    private func strategyMarks(domain: ClosedRange<Double>, strategySeries: String) -> some ChartContent {
        if visibleSeriesIDs.contains(BacktestChartSeriesKey.strategy) {
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

    var body: some View {
        Chart {
            strategyMarks(domain: domain, strategySeries: strategySeries)
            comparisonMarks(seriesList: comparisonSeries, visibleSeriesIDs: visibleSeriesIDs)
        }
        .frame(height: 220)
        .chartXScale(domain: xDomain)
        .chartXScale(range: .plotDimension(startPadding: 4, endPadding: 46))
        .chartXAxis(showsXAxis ? .visible : .hidden)
        .chartYScale(domain: domain)
        .chartForegroundStyleScale(domain: foregroundStyleDomain, range: foregroundStyleRange)
        .animation(.easeInOut(duration: 0.2), value: visibleSeriesIDs)
        .animation(pinchStartSpanRatio == nil ? .easeInOut(duration: 0.18) : nil, value: viewportStartRatio)
        .animation(pinchStartSpanRatio == nil ? .easeInOut(duration: 0.18) : nil, value: visibleSpanRatio)
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
            BacktestChartSelectionOverlay(
                proxy: proxy,
                coordinator: coordinator,
                points: interactionPoints,
                interactionColor: interactionColor,
                valueStyle: valueStyleForSelection,
                interactionSeriesID: interactionSeriesID,
                resolvedComparisonSeries: resolvedComparisonSeries,
                selectionItems: selectionItems,
                selectionItemsProvider: selectionItemsProvider,
                xDomain: xDomain,
                keepsSelectionAfterInteraction: keepsSelectionAfterInteraction,
                chartGuideBounds: $chartGuideBounds,
                onSelectionChange: onSelectionChange
            )
        }
    }
}

private struct BacktestChartSelectionOverlay: View {
    let proxy: ChartProxy
    @ObservedObject var coordinator: BacktestChartSelectionCoordinator
    let points: [BacktestSeriesPoint]
    let interactionColor: Color
    let valueStyle: BacktestChartValueStyle
    let interactionSeriesID: String?
    let resolvedComparisonSeries: [BacktestChartComparisonSeries]
    let selectionItems: [BacktestChartSelectionItem]
    let selectionItemsProvider: ((Date) -> [BacktestChartSelectionItem])?
    let xDomain: ClosedRange<Date>
    let keepsSelectionAfterInteraction: Bool
    @Binding var chartGuideBounds: BacktestChartPlotBounds?
    var onSelectionChange: ((Date?) -> Void)? = nil

    private var selectedPoint: BacktestSeriesPoint? {
        guard let selectedDate = coordinator.selectedDate else { return points.last }
        return InteractiveBacktestChart.nearestPoint(to: selectedDate, in: points)
    }

    private var resolvedSelectionItems: [BacktestChartSelectionItem] {
        if let selectedDate = coordinator.selectedDate,
           let provider = selectionItemsProvider {
            let items = provider(selectedDate)
            if !items.isEmpty { return items }
        }
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

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                TimeMachineDragOverlay(
                    proxy: proxy,
                    selectableValues: points,
                    selectionDate: \.date
                ) { date in
                    coordinator.selectedDate = date
                    onSelectionChange?(date)
                } onEnded: {
                    if !keepsSelectionAfterInteraction {
                        coordinator.selectedDate = nil
                        onSelectionChange?(nil)
                    }
                }
                .simultaneousGesture(
                    TapGesture()
                        .onEnded {
                            coordinator.selectedDate = nil
                            onSelectionChange?(nil)
                        }
                )

                if let selectedPoint,
                   let plotFrame = proxy.plotFrame,
                   let plotX = proxy.position(forX: selectedPoint.date) {
                    let frame = geometry[plotFrame]
                    let xPos = frame.minX + plotX

                    Rectangle()
                        .fill(AssetTheme.gold.opacity(0.72))
                        .frame(width: 1, height: frame.height)
                        .offset(x: xPos, y: frame.minY)
                        .allowsHitTesting(false)

                    if let plotY = proxy.position(forY: selectedPoint.portfolioValue) {
                        Circle()
                            .fill(interactionColor)
                            .frame(width: 7, height: 7)
                            .offset(x: xPos - 3.5, y: frame.minY + plotY - 3.5)
                            .allowsHitTesting(false)
                    }

                    let popoverWidth: CGFloat = AppLocalization.currentLanguage == .english ? 216 : 194
                    let isRightHalf = selectedPoint.date >= xDomain.lowerBound.addingTimeInterval(
                        xDomain.upperBound.timeIntervalSince(xDomain.lowerBound) / 2
                    )
                    let targetLeftX = isRightHalf
                        ? xPos - popoverWidth - 8
                        : xPos + 8
                    let safeLeftX = min(max(targetLeftX, 6), geometry.size.width - popoverWidth - 6)

                    selectedValuePopover(for: selectedPoint)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            coordinator.selectedDate = nil
                            onSelectionChange?(nil)
                        }
                        .offset(x: safeLeftX, y: frame.minY + 4)
                }

                BacktestChartGuideReporter(
                    proxy: proxy,
                    dateDomain: xDomain,
                    guideBounds: $chartGuideBounds
                )
            }
        }
    }

    private func selectedValuePopover(for point: BacktestSeriesPoint) -> some View {
        let items = resolvedSelectionItems
        let itemCount = items.count
        let itemSpacing: CGFloat = itemCount > 8 ? 4.5 : 6.5
        let vPadding: CGFloat = itemCount > 8 ? 8 : 10

        return VStack(alignment: .leading, spacing: itemSpacing) {
            Text(point.date.chartAxisDateString)
                .font(.system(size: 11, weight: .semibold, design: .default))
                .monospacedDigit()
                .foregroundStyle(AssetTheme.textSecondary)

            Rectangle()
                .fill(AssetTheme.border.opacity(0.46))
                .frame(height: 1)

            ForEach(items) { item in
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
        .padding(.horizontal, 11)
        .padding(.vertical, vPadding)
        .frame(width: AppLocalization.currentLanguage == .english ? 216 : 194)
        .background(AssetTheme.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AssetTheme.border.opacity(0.85), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.22), radius: 8, y: 4)
    }
}

private enum BacktestDateRulerLayout {
    static let plotLeadingInset: CGFloat = 54
    static let plotTrailingInset: CGFloat = 46
}

private struct BacktestRulerTicksView: View, Equatable {
    let plotRange: ClosedRange<CGFloat>
    let labelDates: [Date]
    let dateDomain: ClosedRange<Date>
    let width: CGFloat

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.plotRange == rhs.plotRange
            && lhs.width == rhs.width
            && lhs.dateDomain == rhs.dateDomain
            && lhs.labelDates == rhs.labelDates
    }

    var body: some View {
        Canvas { context, size in
            let baselineY: CGFloat = 24
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

            let duration = max(dateDomain.upperBound.timeIntervalSince(dateDomain.lowerBound), 1)
            for date in labelDates {
                let progress = min(max(date.timeIntervalSince(dateDomain.lowerBound) / duration, 0), 1)
                let x = plotRange.lowerBound + availableWidth * progress
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
        .allowsHitTesting(false)
    }
}

private struct BacktestDateRuler: View {
    let dateDomain: ClosedRange<Date>
    let guideBounds: BacktestChartPlotBounds?
    @Binding var selectedDate: Date?

    private let points: [BacktestSeriesPoint]
    private let labelDates: [Date]

    init(
        points: [BacktestSeriesPoint],
        dateDomain: ClosedRange<Date>,
        guideBounds: BacktestChartPlotBounds?,
        selectedDate: Binding<Date?>
    ) {
        self.dateDomain = dateDomain
        self.guideBounds = guideBounds
        self._selectedDate = selectedDate
        self.points = points
        self.labelDates = Self.computeLabelDates(in: dateDomain, points: points)
    }

    private static func computeLabelDates(in dateDomain: ClosedRange<Date>, points: [BacktestSeriesPoint]) -> [Date] {
        guard !points.isEmpty else { return [] }
        let preferredCount = AppLocalization.currentLanguage == .english ? 5 : 6
        let totalDuration = dateDomain.upperBound.timeIntervalSince(dateDomain.lowerBound)
        guard totalDuration > 0 else { return [points[0].date] }
        let step = totalDuration / Double(preferredCount - 1)
        return (0..<preferredCount).map { index in
            let targetDate = dateDomain.lowerBound.addingTimeInterval(step * Double(index))
            return nearestDate(to: targetDate, in: points)
        }
    }

    private var resolvedSelectedDate: Date {
        selectedDate.map { Self.nearestDate(to: $0, in: points) } ?? points.last?.date ?? dateDomain.upperBound
    }

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let plotRange = resolvedPlotRange(width: width)
            let selectionX = resolvedSelectionX(width: width)

            ZStack(alignment: .topLeading) {
                BacktestRulerTicksView(
                    plotRange: plotRange,
                    labelDates: labelDates,
                    dateDomain: dateDomain,
                    width: width
                )
                .equatable()

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

                if selectedDate != nil {
                    Rectangle()
                        .fill(AssetTheme.gold.opacity(0.76))
                        .frame(width: 1, height: geometry.size.height - 24)
                        .position(
                            x: selectionX,
                            y: 24 + (geometry.size.height - 24) / 2
                        )
                        .allowsHitTesting(false)

                    selectionMarker
                        .position(
                            x: selectionX,
                            y: 24
                        )

                    Rectangle()
                        .fill(AssetTheme.gold.opacity(0.76))
                        .frame(width: 1, height: 10)
                        .position(
                            x: selectionX,
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
        xPosition(for: resolvedSelectedDate, width: width)
    }

    private func resolvedPlotRange(width: CGFloat) -> ClosedRange<CGFloat> {
        if let guideBounds,
           guideBounds.lowerX.isFinite,
           guideBounds.upperX.isFinite,
           guideBounds.upperX > guideBounds.lowerX {
            return min(max(guideBounds.lowerX, 0), width)...min(max(guideBounds.upperX, 0), width)
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
        guard !points.isEmpty else { return }
        let plotRange = resolvedPlotRange(width: width)
        let availableWidth = max(plotRange.upperBound - plotRange.lowerBound, 1)
        let progress = min(
            max((x - plotRange.lowerBound) / availableWidth, 0),
            1
        )
        let targetDate = dateDomain.lowerBound.addingTimeInterval(
            dateDomain.upperBound.timeIntervalSince(dateDomain.lowerBound) * Double(progress)
        )
        let nearest = Self.nearestDate(to: targetDate, in: points)
        if nearest != selectedDate {
            selectedDate = nearest
        }
    }

    private static func nearestDate(to targetDate: Date, in points: [BacktestSeriesPoint]) -> Date {
        guard !points.isEmpty else { return targetDate }
        var lowerBound = 0
        var upperBound = points.count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if points[middle].date < targetDate {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        guard lowerBound > 0 else { return points[0].date }
        guard lowerBound < points.count else { return points[points.count - 1].date }
        let previous = points[lowerBound - 1].date
        let next = points[lowerBound].date
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
    let comparisonSeries: [BacktestChartComparisonSeries]
    let valueStyle: BacktestChartValueStyle
    let title: String
    private let chartPoints: [BacktestSeriesPoint]
    private let chartComparisonSeries: [BacktestChartComparisonSeries]
    @State private var visibleSeriesIDs: Set<String> = []

    init(
        points: [BacktestSeriesPoint],
        comparisonSeries: [BacktestChartComparisonSeries] = [],
        valueStyle: BacktestChartValueStyle = .multiple,
        title: String = AppLocalization.string("净值走势")
    ) {
        self.points = points
        self.comparisonSeries = comparisonSeries
        self.valueStyle = valueStyle
        self.title = title
        self.chartPoints = BacktestChartData.sampledPoints(from: points)
        self.chartComparisonSeries = comparisonSeries.compactMap { series in
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

    private let chartPoints: [BacktestSeriesPoint]
    private let chartComparisonSeries: [BacktestChartComparisonSeries]
    private let chartAssetExposureSeries: [BacktestAssetExposureSeries]
    private let chartExposurePoints: [BacktestExposurePoint]
    private let chartSampledAssetSeries: [BacktestAssetExposureSeries]
    private let assetSymbols: [String]
    private let assetColors: [String: Color]

    @StateObject private var selectionCoordinator = BacktestChartSelectionCoordinator()
    @State private var hiddenLegendItemIDs: Set<String> = []
    @State private var visibleDateDomain: ClosedRange<Date>?
    @State private var showsLegend = false

    init(
        points: [BacktestSeriesPoint],
        comparisonSeries: [BacktestChartComparisonSeries],
        exposurePoints: [BacktestExposurePoint],
        assetExposureSeries: [BacktestAssetExposureSeries],
        averageExposureRatio: Double
    ) {
        self.points = points
        self.comparisonSeries = comparisonSeries
        self.exposurePoints = exposurePoints
        self.assetExposureSeries = assetExposureSeries
        self.averageExposureRatio = averageExposureRatio

        self.chartPoints = BacktestChartData.sampledPoints(from: points)

        var seenSymbols: Set<String> = []
        let uniqueExposure = assetExposureSeries.filter { seenSymbols.insert($0.symbol).inserted }
        self.chartAssetExposureSeries = uniqueExposure

        self.chartExposurePoints = BacktestExposureSampling.sampled(exposurePoints)
        self.chartSampledAssetSeries = uniqueExposure.map { series in
            BacktestAssetExposureSeries(
                symbol: series.symbol,
                title: series.title,
                points: BacktestExposureSampling.sampled(series.points)
            )
        }

        var symbols: [String] = []
        for series in uniqueExposure where !symbols.contains(series.symbol) {
            symbols.append(series.symbol)
        }
        for series in comparisonSeries {
            guard let symbol = BacktestChartSeriesKey.assetSymbol(fromBenchmarkID: series.id),
                  !symbols.contains(symbol) else { continue }
            symbols.append(symbol)
        }
        self.assetSymbols = symbols

        let colors = Dictionary(uniqueKeysWithValues: symbols.enumerated().map { index, symbol in
            (symbol, BacktestChartPalette.exposureLine(at: index))
        })
        self.assetColors = colors

        self.chartComparisonSeries = comparisonSeries.compactMap { series in
            let sampledPoints = BacktestChartData.sampledPoints(from: series.points)
            guard !sampledPoints.isEmpty else { return nil }
            let symbol = BacktestChartSeriesKey.assetSymbol(fromBenchmarkID: series.id)
            return BacktestChartComparisonSeries(
                id: series.id,
                title: series.title,
                points: sampledPoints,
                color: symbol.flatMap { colors[$0] } ?? series.color
            )
        }
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

    private func makeSelectedAmountItems(for selectedDate: Date) -> [BacktestChartSelectionItem] {
        guard let portfolioPoint = nearestChartPoint(points, to: selectedDate, date: \.date) else {
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

            VStack(alignment: .leading, spacing: 0) {
                InteractiveBacktestChart(
                    points: chartPoints,
                    comparisonSeries: chartComparisonSeries,
                    valueStyle: .currency(code: "CNY"),
                    visibleSeriesIDs: effectiveVisibleValueSeriesIDs,
                    onVisibleDateDomainChange: { domain in
                        visibleDateDomain = domain
                    },
                    selectionItemsProvider: { targetDate in
                        makeSelectedAmountItems(for: targetDate)
                    },
                    showsDateRuler: true,
                    showsXAxis: false,
                    keepsSelectionAfterInteraction: true,
                    selectionCoordinator: selectionCoordinator
                )

                BacktestExposureChartSection(
                    chartPoints: chartExposurePoints,
                    sampledAssetSeries: chartSampledAssetSeries,
                    dateDomain: visibleDateDomain,
                    visibleSeriesIDs: effectiveVisibleExposureSeriesIDs,
                    assetColors: assetColors,
                    selectionCoordinator: selectionCoordinator
                )
            }

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
               !points.isEmpty {
                let testDate = points[points.count / 2].date
                Task { @MainActor in
                    await Task.yield()
                    selectionCoordinator.selectedDate = testDate
                }
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
    let chartPoints: [BacktestExposurePoint]
    let sampledAssetSeries: [BacktestAssetExposureSeries]
    var dateDomain: ClosedRange<Date>? = nil
    var visibleSeriesIDs: Set<String> = []
    var assetColors: [String: Color] = [:]
    var selectionCoordinator: BacktestChartSelectionCoordinator? = nil
    var onSelectionChange: ((Date?) -> Void)? = nil

    @StateObject private var internalCoordinator = BacktestChartSelectionCoordinator()

    private let yMaximum: Double
    private let yAxisValues: [Double]

    private var activeCoordinator: BacktestChartSelectionCoordinator {
        selectionCoordinator ?? internalCoordinator
    }

    init(
        chartPoints: [BacktestExposurePoint],
        sampledAssetSeries: [BacktestAssetExposureSeries],
        dateDomain: ClosedRange<Date>? = nil,
        visibleSeriesIDs: Set<String> = [],
        assetColors: [String: Color] = [:],
        selectionCoordinator: BacktestChartSelectionCoordinator? = nil,
        onSelectionChange: ((Date?) -> Void)? = nil
    ) {
        self.chartPoints = chartPoints
        self.sampledAssetSeries = sampledAssetSeries
        self.dateDomain = dateDomain
        self.visibleSeriesIDs = visibleSeriesIDs
        self.assetColors = assetColors
        self.selectionCoordinator = selectionCoordinator
        self.onSelectionChange = onSelectionChange

        let peak = chartPoints.map(\.ratio).max() ?? 0
        let maxRatio: Double
        if peak > 1 {
            maxRatio = max(ceil(peak * 4) / 4, 1.25)
        } else {
            maxRatio = 1
        }
        self.yMaximum = maxRatio

        let step = maxRatio / 4
        self.yAxisValues = (0...4).map { Double($0) * step }
    }

    init(
        points: [BacktestExposurePoint],
        assetSeries: [BacktestAssetExposureSeries],
        dateDomain: ClosedRange<Date>? = nil,
        visibleSeriesIDs: Set<String> = [],
        assetColors: [String: Color] = [:],
        selectedDate: Binding<Date?>
    ) {
        let sampled = BacktestExposureSampling.sampled(points)
        let sampledSeries = assetSeries.map { series in
            BacktestAssetExposureSeries(
                symbol: series.symbol,
                title: series.title,
                points: BacktestExposureSampling.sampled(series.points)
            )
        }
        self.init(
            chartPoints: sampled,
            sampledAssetSeries: sampledSeries,
            dateDomain: dateDomain,
            visibleSeriesIDs: visibleSeriesIDs,
            assetColors: assetColors,
            selectionCoordinator: nil,
            onSelectionChange: { selectedDate.wrappedValue = $0 }
        )
    }

    private var availableSeriesIDs: Set<String> {
        Set(sampledAssetSeries.map { BacktestExposureSeriesKey.asset($0.symbol) } + [BacktestExposureSeriesKey.total])
    }

    private var effectiveVisibleSeriesIDs: Set<String> {
        let selected = visibleSeriesIDs.intersection(availableSeriesIDs)
        return selected.isEmpty ? availableSeriesIDs : selected
    }

    private var resolvedDateDomain: ClosedRange<Date> {
        if let dateDomain { return dateDomain }
        let dates = chartPoints.map(\.date)
        guard let first = dates.first, let last = dates.last else {
            let fallback = Date()
            return fallback...fallback.addingTimeInterval(24 * 60 * 60)
        }
        return first == last ? first...first.addingTimeInterval(24 * 60 * 60) : first...last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            BacktestStaticExposureChart(
                chartPoints: chartPoints,
                sampledAssetSeries: sampledAssetSeries,
                resolvedDateDomain: resolvedDateDomain,
                effectiveVisibleSeriesIDs: effectiveVisibleSeriesIDs,
                assetColors: assetColors,
                yMaximum: yMaximum,
                yAxisValues: yAxisValues,
                coordinator: activeCoordinator,
                onSelectionChange: onSelectionChange
            )
            .equatable()
            .accessibilityElement(children: .combine)
            .accessibilityLabel(AppLocalization.string(sampledAssetSeries.isEmpty ? "持仓比例走势" : "资产持仓走势"))
        }
    }
}

private struct BacktestStaticExposureChart: View, Equatable {
    let chartPoints: [BacktestExposurePoint]
    let sampledAssetSeries: [BacktestAssetExposureSeries]
    let resolvedDateDomain: ClosedRange<Date>
    let effectiveVisibleSeriesIDs: Set<String>
    let assetColors: [String: Color]
    let yMaximum: Double
    let yAxisValues: [Double]
    let coordinator: BacktestChartSelectionCoordinator
    var onSelectionChange: ((Date?) -> Void)? = nil

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.resolvedDateDomain == rhs.resolvedDateDomain
            && lhs.effectiveVisibleSeriesIDs == rhs.effectiveVisibleSeriesIDs
            && lhs.yMaximum == rhs.yMaximum
            && lhs.yAxisValues == rhs.yAxisValues
            && lhs.chartPoints.count == rhs.chartPoints.count
            && lhs.sampledAssetSeries.count == rhs.sampledAssetSeries.count
    }

    @ChartContentBuilder
    private var exposureMarks: some ChartContent {
        if sampledAssetSeries.isEmpty, effectiveVisibleSeriesIDs.contains(BacktestExposureSeriesKey.total) {
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

    var body: some View {
        Chart {
            exposureMarks
        }
        .frame(height: 160)
        .chartXScale(domain: resolvedDateDomain)
        .chartXScale(range: .plotDimension(startPadding: 4, endPadding: 46))
        .chartXAxis(.hidden)
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
        .chartOverlay { proxy in
            BacktestExposureSelectionOverlay(
                proxy: proxy,
                coordinator: coordinator,
                chartPoints: chartPoints,
                sampledAssetSeries: sampledAssetSeries,
                effectiveVisibleSeriesIDs: effectiveVisibleSeriesIDs,
                assetColors: assetColors,
                onSelectionChange: onSelectionChange
            )
        }
    }
}

private struct BacktestExposureSelectionOverlay: View {
    let proxy: ChartProxy
    @ObservedObject var coordinator: BacktestChartSelectionCoordinator
    let chartPoints: [BacktestExposurePoint]
    let sampledAssetSeries: [BacktestAssetExposureSeries]
    let effectiveVisibleSeriesIDs: Set<String>
    let assetColors: [String: Color]
    var onSelectionChange: ((Date?) -> Void)? = nil

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                TimeMachineDragOverlay(
                    proxy: proxy,
                    selectableValues: chartPoints,
                    selectionDate: \.date
                ) { date in
                    coordinator.selectedDate = date
                    onSelectionChange?(date)
                } onEnded: {
                    coordinator.selectedDate = nil
                    onSelectionChange?(nil)
                }
                .simultaneousGesture(
                    TapGesture()
                        .onEnded {
                            coordinator.selectedDate = nil
                            onSelectionChange?(nil)
                        }
                )

                if let selectedDate = coordinator.selectedDate,
                   let plotFrame = proxy.plotFrame,
                   let plotX = proxy.position(forX: selectedDate) {
                    let frame = geometry[plotFrame]
                    let xPos = frame.minX + plotX

                    Rectangle()
                        .fill(AssetTheme.gold.opacity(0.72))
                        .frame(width: 1, height: frame.height)
                        .offset(x: xPos, y: frame.minY)
                        .allowsHitTesting(false)

                    if sampledAssetSeries.isEmpty {
                        if effectiveVisibleSeriesIDs.contains(BacktestExposureSeriesKey.total),
                           let selectedPoint = nearestChartPoint(chartPoints, to: selectedDate, date: \.date),
                           let plotY = proxy.position(forY: selectedPoint.ratio) {
                            Circle()
                                .fill(BacktestChartPalette.strategyLine)
                                .frame(width: 6, height: 6)
                                .offset(x: xPos - 3, y: frame.minY + plotY - 3)
                                .allowsHitTesting(false)
                        }
                    } else {
                        ForEach(Array(sampledAssetSeries.enumerated()), id: \.element.id) { index, series in
                            if effectiveVisibleSeriesIDs.contains(BacktestExposureSeriesKey.asset(series.symbol)),
                               let selectedPoint = nearestChartPoint(series.points, to: selectedDate, date: \.date),
                               let plotY = proxy.position(forY: selectedPoint.ratio) {
                                Circle()
                                    .fill(assetColors[series.symbol] ?? BacktestChartPalette.exposureLine(at: index))
                                    .frame(width: 6, height: 6)
                                    .offset(x: xPos - 3, y: frame.minY + plotY - 3)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct BacktestAllocationSlice: Identifiable {
    let title: String
    let amount: Double
    let color: Color

    var id: String { title }
}

import SwiftUI
import SwiftData
import Charts
import UIKit

enum TimeMachineRange: String, CaseIterable, Identifiable {
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

    var monthlyBucketLimit: Int? {
        switch self {
        case .halfMonth, .oneMonth:
            return 1
        case .sixMonths:
            return 6
        case .oneYear:
            return 12
        case .threeYears:
            return 36
        case .all:
            return nil
        }
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

    func filter(_ points: [TimeMachineSingleAxisPoint], calendar: Calendar = .current) -> [TimeMachineSingleAxisPoint] {
        guard let latestDate = points.last?.date else { return [] }
        let startDate = startDate(from: latestDate, calendar: calendar)
        guard let startDate else { return points }
        return points.filter { $0.date >= startDate }
    }

    func filter(_ points: [TimeMachineCandlestickPoint], calendar: Calendar = .current) -> [TimeMachineCandlestickPoint] {
        guard let latestDate = points.last?.date else { return [] }
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

struct TimeMachineTrendPoint: Identifiable {
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

struct TimeMachineTrendPointCacheEntry {
    let token: Int
    let point: TimeMachineTrendPoint
}

struct TimeMachineMonthlySurplusPoint: Identifiable {
    let monthStart: Date
    let date: Date
    let surplus: Double
    let monthEndNetAssets: Double

    var id: Date { monthStart }
}

struct TimeMachineAnnualSurplusPoint: Identifiable {
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
            self.leftDomain = Self.paddedDomain(values: sampledCandlesticks.flatMap { [$0.low, $0.high] })
        } else {
            self.leftDomain = Self.paddedDomain(values: sampledDualPoints.map(\.leftValue) + sampledLeftOnlyPoints.map(\.value))
        }
        self.rightDomain = Self.paddedDomain(values: sampledDualPoints.map(\.rightValue))
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

    private static func paddedDomain(values: [Double]) -> ClosedRange<Double> {
        let filtered = values.filter { $0.isFinite }
        guard let minValue = filtered.min(), let maxValue = filtered.max() else {
            return 0...1
        }
        if abs(maxValue - minValue) < .ulpOfOne {
            let padding = max(abs(maxValue) * 0.08, 1)
            return (minValue - padding)...(maxValue + padding)
        }
        let padding = max((maxValue - minValue) * 0.12, abs(maxValue) * 0.02)
        return (minValue - padding)...(maxValue + padding)
    }
}

struct TimeMachineDetailComparisonOption: Identifiable {
    let symbol: String
    let title: String
    let color: Color

    var id: String { symbol }
}

enum TimeMachineAxisValueStyle {
    case currency(code: String, suffix: String = "")
    case quantity(unit: String, maxFractionDigits: Int = 2)

    func compactLabel(for value: Double) -> String {
        switch self {
        case let .currency(code, suffix):
            return "\(currencySymbol(for: code))\(value.compactNumberString())\(suffix)"
        case let .quantity(unit, maxFractionDigits):
            return "\(value.compactNumberString(maxFractionDigits: maxFractionDigits))\(unit)"
        }
    }

    private func currencySymbol(for code: String) -> String {
        switch code.uppercased() {
        case "USD":
            return "$"
        case "HKD":
            return "HK$"
        case "JPY":
            return "¥"
        case "GBP":
            return "£"
        case "EUR":
            return "€"
        default:
            return "¥"
        }
    }
}

struct TimeMachineDualAxisPoint: Identifiable {
    let date: Date
    let leftValue: Double
    let rightValue: Double

    var id: Date { date }
}

struct TimeMachineSingleAxisPoint: Identifiable {
    let date: Date
    let value: Double

    var id: Date { date }
}

struct TimeMachineCandlestickPoint: Identifiable {
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

    var id: String { title }

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

struct DashboardAllocationDetail: Identifiable {
    let title: String
    let amount: Double

    var id: String { title }
}

struct DashboardAllocationSlice: Identifiable {
    let title: String
    let amount: Double
    let color: Color
    let details: [DashboardAllocationDetail]

    var id: String { title }
}

enum DashboardAllocationPalette {
    static let colors: [Color] = [
        AssetTheme.goldSoft,
        AssetTheme.accentBlue,
        AssetTheme.positive,
        AssetTheme.accentOrange,
        Color(red: 173 / 255, green: 132 / 255, blue: 255 / 255),
        Color(red: 105 / 255, green: 196 / 255, blue: 219 / 255)
    ]
}

struct DashboardAllocationChart: View {
    let slices: [DashboardAllocationSlice]
    let totalAmount: Double

    @State private var selectedSliceID: DashboardAllocationSlice.ID?
    @State private var selectedAngleValue: Double?

    private let legendColumns = [
        GridItem(.flexible(), spacing: 16, alignment: .topLeading),
        GridItem(.flexible(), spacing: 16, alignment: .topLeading)
    ]

    private var displaySlice: DashboardAllocationSlice? {
        if let selectedSliceID,
           let selectedSlice = slices.first(where: { $0.id == selectedSliceID }) {
            return selectedSlice
        }
        return slices.first
    }

    private var totalSliceAmount: Double {
        slices.reduce(0) { $0 + $1.amount }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ZStack {
                Chart(slices) { slice in
                    SectorMark(
                        angle: .value(AppLocalization.string("占比"), slice.amount),
                        innerRadius: .ratio(0.76),
                        angularInset: 1.6
                    )
                    .foregroundStyle(slice.color)
                    .opacity(isHighlighted(slice) ? 1 : 0.42)
                }
                .chartLegend(.hidden)
                .chartAngleSelection(value: $selectedAngleValue)
                .onChange(of: selectedAngleValue) { _, newValue in
                    guard let newValue,
                          let matchedSlice = slice(for: newValue) else { return }
                    selectedSliceID = matchedSlice.id
                }
                .frame(height: 278)

                VStack(spacing: 6) {
                    Text(AppLocalization.string("总资产"))
                        .font(AppTypography.eyebrow)
                        .foregroundStyle(AssetTheme.textSecondary)

                    Text(totalAmount.currencyString())
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(AssetTheme.textPrimary)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.7)
                        .lineLimit(2)
                }
                .padding(.horizontal, 18)
                .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity)

            LazyVGrid(columns: legendColumns, alignment: .leading, spacing: 12) {
                ForEach(slices) { slice in
                    Button {
                        toggleSelection(for: slice)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Circle()
                                .fill(slice.color)
                                .frame(width: 8, height: 8)
                                .padding(.top, 5)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(AppLocalization.string(slice.title))
                                    .font(AppTypography.meta.weight(isHighlighted(slice) ? .semibold : .regular))
                                    .foregroundStyle(AssetTheme.textPrimary)
                                    .lineLimit(1)

                                Text(isHighlighted(slice) ? slice.amount.currencyString() : percentageText(for: slice))
                                    .font(AppTypography.eyebrow)
                                    .monospacedDigit()
                                    .foregroundStyle(isHighlighted(slice) ? AssetTheme.goldSoft : AssetTheme.textSecondary)
                            }

                            Spacer(minLength: 0)
                        }
                        .opacity(isHighlighted(slice) ? 1 : 0.78)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            if let displaySlice, displaySlice.details.count > 1 {
                VStack(alignment: .leading, spacing: 10) {
                    Text(displaySlice.title == AppLocalization.string("其他") ? AppLocalization.string("其他资产明细") : AppLocalization.string("资产明细"))
                        .font(AppTypography.eyebrow)
                        .foregroundStyle(AssetTheme.textSecondary)

                    ForEach(displaySlice.details) { detail in
                        HStack(spacing: 12) {
                            Text(AppLocalization.string(detail.title))
                                .font(AppTypography.meta)
                                .foregroundStyle(AssetTheme.textPrimary)
                                .lineLimit(1)

                            Spacer()

                            Text(detail.amount.currencyString())
                                .font(AppTypography.meta.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(AssetTheme.goldSoft)
                        }
                    }
                }
            }
        }
    }

    private func percentageText(for slice: DashboardAllocationSlice) -> String {
        guard totalAmount > 0 else { return "0%" }
        return (slice.amount / totalAmount).formatted(.percent.precision(.fractionLength(0)))
    }

    private func isHighlighted(_ slice: DashboardAllocationSlice) -> Bool {
        displaySlice?.id == slice.id
    }

    private func toggleSelection(for slice: DashboardAllocationSlice) {
        selectedSliceID = slice.id
        selectedAngleValue = midAngleValue(for: slice)
    }

    private func slice(for angleValue: Double) -> DashboardAllocationSlice? {
        guard totalSliceAmount > 0 else { return nil }

        var currentAngle = 0.0
        for slice in slices {
            let nextAngle = currentAngle + slice.amount
            if angleValue >= currentAngle && angleValue < nextAngle {
                return slice
            }
            currentAngle = nextAngle
        }

        return slices.last
    }

    private func midAngleValue(for slice: DashboardAllocationSlice) -> Double? {
        guard totalSliceAmount > 0 else { return nil }

        var currentAngle = 0.0
        for candidate in slices {
            let nextAngle = currentAngle + candidate.amount
            if candidate.id == slice.id {
                return (currentAngle + nextAngle) / 2
            }
            currentAngle = nextAngle
        }

        return nil
    }
}

struct FinancialFreedomProjection {
    enum Status {
        case alreadyFree
        case projected(months: Int)
        case unreachable
    }

    let status: Status
    let monthlySalary: Double
    let annualReturnRate: Double
    let currentMonthlyExpense: Double
    let currentPassiveIncome: Double
    let maximumReachableMonthlyExpense: Double
    let requiredMonthlySalaryToReachFreedom: Double?
    let currentNetAssets: Double
    let currentTotalAssets: Double
    let projectedAnnualSurplus: Double
    let projectionPoints: [FinancialFreedomProjectionPoint]
}

struct FinancialFreedomProjectionPoint: Identifiable {
    let monthOffset: Int
    let date: Date
    let projectedPassiveIncome: Double
    let projectedMonthlyExpense: Double
    let projectedTotalAssets: Double

    var id: Int { monthOffset }
}

enum FinancialFreedomEstimator {
    private static let maxProjectionMonths = 100 * 12

    static func estimate(
        points: [TimeMachineTrendPoint],
        monthlySalary: Double,
        annualReturnRate: Double,
        monthlyExpense: Double,
        annualInflationRate: Double
    ) -> FinancialFreedomProjection? {
        guard let currentPoint = points.last,
              currentPoint.netAssets.isFinite,
              currentPoint.mainAssets.isFinite else { return nil }
        let currentNetAssets = currentPoint.netAssets
        let currentTotalAssets = currentPoint.mainAssets
        let currentLiabilities = max(currentPoint.liabilities, 0)
        let currentPassiveIncome = passiveMonthlyIncome(from: currentNetAssets, annualReturnRate: annualReturnRate)
        let monthlyReturnRate = monthlyReturnRate(from: annualReturnRate)
        let maximumReachableMonthlyExpense = maximumReachableMonthlyExpense(
            currentNetAssets: currentNetAssets,
            monthlySalary: monthlySalary,
            monthlyReturnRate: monthlyReturnRate,
            annualInflationRate: annualInflationRate
        )
        let requiredMonthlySalaryToReachFreedom = minimumRequiredMonthlySalaryToReachFreedom(
            currentNetAssets: currentNetAssets,
            monthlyExpense: monthlyExpense,
            monthlyReturnRate: monthlyReturnRate,
            annualInflationRate: annualInflationRate
        )

        let status: FinancialFreedomProjection.Status
        if currentPassiveIncome >= monthlyExpense {
            status = .alreadyFree
        } else {
            var projectedAssets = currentNetAssets
            var projectedMonths: Int?
            for month in 1...maxProjectionMonths {
                let projectedExpense = monthlyExpense * pow(1 + annualInflationRate, Double(month) / 12)
                projectedAssets = projectedAssets * (1 + monthlyReturnRate) + monthlySalary - projectedExpense
                if passiveMonthlyIncome(from: projectedAssets, annualReturnRate: annualReturnRate) >= projectedExpense {
                    projectedMonths = month
                    break
                }
            }
            status = projectedMonths.map { .projected(months: $0) } ?? .unreachable
        }

        let projectedAnnualSurplus = projectedAssetGrowth(
            currentNetAssets: currentNetAssets,
            months: 12,
            monthlySalary: monthlySalary,
            monthlyExpense: monthlyExpense,
            monthlyReturnRate: monthlyReturnRate,
            annualInflationRate: annualInflationRate
        )

        return FinancialFreedomProjection(
            status: status,
            monthlySalary: monthlySalary,
            annualReturnRate: annualReturnRate,
            currentMonthlyExpense: monthlyExpense,
            currentPassiveIncome: currentPassiveIncome,
            maximumReachableMonthlyExpense: maximumReachableMonthlyExpense,
            requiredMonthlySalaryToReachFreedom: requiredMonthlySalaryToReachFreedom,
            currentNetAssets: currentNetAssets,
            currentTotalAssets: currentTotalAssets,
            projectedAnnualSurplus: projectedAnnualSurplus,
            projectionPoints: projectionPoints(
                from: Calendar.current.startOfDay(for: max(currentPoint.date, Date())),
                currentNetAssets: currentNetAssets,
                currentLiabilities: currentLiabilities,
                monthlySalary: monthlySalary,
                monthlyReturnRate: monthlyReturnRate,
                monthlyExpense: monthlyExpense,
                annualInflationRate: annualInflationRate,
                status: status
            )
        )
    }

    private static func projectionPoints(
        from startDate: Date,
        currentNetAssets: Double,
        currentLiabilities: Double,
        monthlySalary: Double,
        monthlyReturnRate: Double,
        monthlyExpense: Double,
        annualInflationRate: Double,
        status: FinancialFreedomProjection.Status
    ) -> [FinancialFreedomProjectionPoint] {
        let horizonMonths = chartHorizonMonths(for: status, monthlySalary: monthlySalary, monthlyReturnRate: monthlyReturnRate)
        let calendar = Calendar.current
        var projectedAssets = currentNetAssets

        return (0...horizonMonths).compactMap { month in
            guard let date = calendar.date(byAdding: .month, value: month, to: startDate) else { return nil }
            let projectedMonthlyExpense = monthlyExpense * pow(1 + annualInflationRate, Double(month) / 12)
            if month > 0 {
                projectedAssets = projectedAssets * (1 + monthlyReturnRate) + monthlySalary - projectedMonthlyExpense
            }
            return FinancialFreedomProjectionPoint(
                monthOffset: month,
                date: date,
                projectedPassiveIncome: passiveMonthlyIncome(from: projectedAssets, annualReturnRate: monthlyReturnRateToAnnualRate(monthlyReturnRate)),
                projectedMonthlyExpense: projectedMonthlyExpense,
                projectedTotalAssets: projectedAssets + currentLiabilities
            )
        }
    }

    private static func chartHorizonMonths(
        for status: FinancialFreedomProjection.Status,
        monthlySalary: Double,
        monthlyReturnRate: Double
    ) -> Int {
        switch status {
        case .alreadyFree:
            return 36
        case let .projected(months):
            return min(max(months + 6, 18), 120)
        case .unreachable:
            return monthlySalary > 0 || monthlyReturnRate > 0 ? 60 : 36
        }
    }

    private static func maximumReachableMonthlyExpense(
        currentNetAssets: Double,
        monthlySalary: Double,
        monthlyReturnRate: Double,
        annualInflationRate: Double
    ) -> Double {
        let annualReturnRate = monthlyReturnRateToAnnualRate(monthlyReturnRate)

        func canReachFreedom(monthlyExpense: Double) -> Bool {
            if passiveMonthlyIncome(from: currentNetAssets, annualReturnRate: annualReturnRate) >= monthlyExpense {
                return true
            }

            var projectedAssets = currentNetAssets
            for month in 1...maxProjectionMonths {
                let projectedExpense = monthlyExpense * pow(1 + annualInflationRate, Double(month) / 12)
                projectedAssets = projectedAssets * (1 + monthlyReturnRate) + monthlySalary - projectedExpense
                guard projectedAssets.isFinite else { return false }
                if passiveMonthlyIncome(from: projectedAssets, annualReturnRate: annualReturnRate) >= projectedExpense {
                    return true
                }
            }
            return false
        }

        var lower = 0.0
        var upper = max(monthlySalary + passiveMonthlyIncome(from: currentNetAssets, annualReturnRate: annualReturnRate), 1)
        while canReachFreedom(monthlyExpense: upper), upper < 1_000_000_000 {
            lower = upper
            upper *= 2
        }

        for _ in 0..<40 {
            let middle = (lower + upper) / 2
            if canReachFreedom(monthlyExpense: middle) {
                lower = middle
            } else {
                upper = middle
            }
        }

        return max(0, lower)
    }

    private static func minimumRequiredMonthlySalaryToReachFreedom(
        currentNetAssets: Double,
        monthlyExpense: Double,
        monthlyReturnRate: Double,
        annualInflationRate: Double
    ) -> Double? {
        let annualReturnRate = monthlyReturnRateToAnnualRate(monthlyReturnRate)
        guard annualReturnRate > 0, monthlyExpense > 0 else { return nil }

        func canReachFreedom(monthlySalary: Double) -> Bool {
            if passiveMonthlyIncome(from: currentNetAssets, annualReturnRate: annualReturnRate) >= monthlyExpense {
                return true
            }

            var projectedAssets = currentNetAssets
            for month in 1...maxProjectionMonths {
                let projectedExpense = monthlyExpense * pow(1 + annualInflationRate, Double(month) / 12)
                projectedAssets = projectedAssets * (1 + monthlyReturnRate) + monthlySalary - projectedExpense
                guard projectedAssets.isFinite else { return false }
                if passiveMonthlyIncome(from: projectedAssets, annualReturnRate: annualReturnRate) >= projectedExpense {
                    return true
                }
            }
            return false
        }

        var lower = 0.0
        var upper = max(monthlyExpense, 1)
        while !canReachFreedom(monthlySalary: upper), upper < 1_000_000_000 {
            lower = upper
            upper *= 2
        }

        guard canReachFreedom(monthlySalary: upper) else { return nil }

        for _ in 0..<40 {
            let middle = (lower + upper) / 2
            if canReachFreedom(monthlySalary: middle) {
                upper = middle
            } else {
                lower = middle
            }
        }

        return max(0, upper)
    }

    private static func projectedAssetGrowth(
        currentNetAssets: Double,
        months: Int,
        monthlySalary: Double,
        monthlyExpense: Double,
        monthlyReturnRate: Double,
        annualInflationRate: Double
    ) -> Double {
        guard months > 0 else { return 0 }

        var projectedAssets = currentNetAssets
        for month in 1...months {
            let projectedExpense = monthlyExpense * pow(1 + annualInflationRate, Double(month) / 12)
            projectedAssets = projectedAssets * (1 + monthlyReturnRate) + monthlySalary - projectedExpense
        }
        return projectedAssets - currentNetAssets
    }

    private static func passiveMonthlyIncome(from assets: Double, annualReturnRate: Double) -> Double {
        assets * annualReturnRate / 12
    }

    private static func monthlyReturnRate(from annualReturnRate: Double) -> Double {
        let boundedAnnualReturnRate = min(max(annualReturnRate, -0.99), 1.0)
        return pow(1 + boundedAnnualReturnRate, 1.0 / 12.0) - 1
    }

    private static func monthlyReturnRateToAnnualRate(_ monthlyReturnRate: Double) -> Double {
        pow(1 + monthlyReturnRate, 12) - 1
    }
}

struct DashboardFreedomSection: View {
    let projection: FinancialFreedomProjection?
    @Binding var monthlySalary: Double
    @Binding var annualReturnRate: Double
    @Binding var monthlyExpense: Double
    @Binding var inflationRate: Double

    @State private var isEditingMonthlyExpense = false
    @State private var isEditingInflationRate = false
    @State private var isEditingMonthlySalary = false
    @State private var isEditingAnnualReturnRate = false
    @State private var showsAlgorithmExplanation = false
    @State private var monthlyExpenseDraft = ""
    @State private var inflationRateDraft = ""
    @State private var monthlySalaryDraft = ""
    @State private var annualReturnRateDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                Text(statusText)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(statusColor)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)

                Spacer(minLength: 8)

                Button {
                    showsAlgorithmExplanation = true
                } label: {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(AssetTheme.textSecondary)
                        .frame(width: 36, height: 36)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AppLocalization.string("查看财富自由算法说明"))
            }

            if let reasonText {
                Text(reasonText)
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(AssetTheme.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    parameterButton(title: AppLocalization.string("月开销"), value: monthlyExpense.currencyString(), action: openMonthlyExpenseEditor)
                    parameterButton(title: AppLocalization.string("月薪"), value: monthlySalary.currencyString(), action: openMonthlySalaryEditor)
                }

                HStack(spacing: 8) {
                    parameterButton(title: AppLocalization.string("通胀率"), value: inflationRate.formatted(.percent.precision(.fractionLength(1))), action: openInflationRateEditor)
                    parameterButton(title: AppLocalization.string("年化收益"), value: annualReturnRate.formatted(.percent.precision(.fractionLength(1))), action: openAnnualReturnRateEditor)
                }
            }

            Text(annualSurplusRequirementText)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(AssetTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let projection, !projection.projectionPoints.isEmpty {
                DashboardFreedomProjectionChart(projection: projection)
                    .padding(.top, 2)
            }
        }
        .padding(.top, 2)
        .alert(AppLocalization.string("修改月开销"), isPresented: $isEditingMonthlyExpense) {
            TextField(AppLocalization.string("例如 8000"), text: $monthlyExpenseDraft)
                .keyboardType(.decimalPad)
            Button(AppLocalization.string("取消"), role: .cancel) {}
            Button(AppLocalization.string("确定")) {
                applyMonthlyExpenseDraft()
            }
        } message: {
            Text(AppLocalization.string("用于设置财富自由测算的月开销。"))
        }
        .alert(AppLocalization.string("修改通胀率"), isPresented: $isEditingInflationRate) {
            TextField(AppLocalization.string("例如 3.0"), text: $inflationRateDraft)
                .keyboardType(.decimalPad)
            Button(AppLocalization.string("取消"), role: .cancel) {}
            Button(AppLocalization.string("确定")) {
                applyInflationRateDraft()
            }
        } message: {
            Text(AppLocalization.string("请输入百分比数值，例如 3 表示 3%。"))
        }
        .alert(AppLocalization.string("修改月薪"), isPresented: $isEditingMonthlySalary) {
            TextField(AppLocalization.string("例如 10000"), text: $monthlySalaryDraft)
                .keyboardType(.decimalPad)
            Button(AppLocalization.string("取消"), role: .cancel) {}
            Button(AppLocalization.string("确定")) {
                applyMonthlySalaryDraft()
            }
        } message: {
            Text(AppLocalization.string("每月收入会先扣除当月开销，剩余结余再与月复利一起影响净资产。"))
        }
        .alert(AppLocalization.string("修改年化收益"), isPresented: $isEditingAnnualReturnRate) {
            TextField(AppLocalization.string("例如 3.0"), text: $annualReturnRateDraft)
                .keyboardType(.decimalPad)
            Button(AppLocalization.string("取消"), role: .cancel) {}
            Button(AppLocalization.string("确定")) {
                applyAnnualReturnRateDraft()
            }
        } message: {
            Text(AppLocalization.string("请输入百分比数值，例如 3 表示 3%。"))
        }
        .alert(AppLocalization.string("财富自由算法"), isPresented: $showsAlgorithmExplanation) {
            Button(AppLocalization.string("知道了"), role: .cancel) {}
        } message: {
            Text(AppLocalization.string("当前净资产作为起始本金；每个月先按年化收益换算出的月复利增长，再加入当月结余（月薪 - 通胀后的月开销）；被动收入按你填写的年化收益折算为每月：净资产 × 年化收益 ÷ 12；目标是被动收入覆盖考虑通胀后的月开销。"))
        }
    }

    private func parameterButton(title: String, value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(AssetTheme.textSecondary)
                    .lineLimit(1)

                Text(value)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(AssetTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(AssetTheme.overlaySubtle.opacity(0.72), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(AssetTheme.border.opacity(0.24), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func openMonthlyExpenseEditor() {
        monthlyExpenseDraft = String(Int(monthlyExpense.rounded()))
        isEditingMonthlyExpense = true
    }

    private func openInflationRateEditor() {
        inflationRateDraft = String(format: "%.1f", inflationRate * 100)
        isEditingInflationRate = true
    }

    private func openMonthlySalaryEditor() {
        monthlySalaryDraft = String(Int(monthlySalary.rounded()))
        isEditingMonthlySalary = true
    }

    private func openAnnualReturnRateEditor() {
        annualReturnRateDraft = String(format: "%.1f", annualReturnRate * 100)
        isEditingAnnualReturnRate = true
    }

    private func applyMonthlyExpenseDraft() {
        let sanitized = monthlyExpenseDraft
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let value = Double(sanitized), value.isFinite else { return }
        monthlyExpense = max(1000, value)
    }

    private func applyInflationRateDraft() {
        let sanitized = inflationRateDraft
            .replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let percent = Double(sanitized), percent.isFinite else { return }
        inflationRate = min(max(percent / 100, 0), 0.2)
    }

    private func applyMonthlySalaryDraft() {
        let sanitized = monthlySalaryDraft
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let value = Double(sanitized), value.isFinite else { return }
        monthlySalary = max(0, value)
    }

    private func applyAnnualReturnRateDraft() {
        let sanitized = annualReturnRateDraft
            .replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let percent = Double(sanitized), percent.isFinite else { return }
        annualReturnRate = min(max(percent / 100, -0.99), 1.0)
    }

    private var annualSurplusRequirementText: String {
        guard let projection else {
            return AppLocalization.string("今年需要年结余：记录资产快照后可估算")
        }

        let averageMonthlySurplus = projection.projectedAnnualSurplus / 12
        return AppLocalization.format(
            AppLocalization.string("今年需要年结余 %@ · 平均月需结余 %@"),
            projection.projectedAnnualSurplus.currencyString(),
            averageMonthlySurplus.currencyString()
        )
    }

    private var statusText: String {
        guard let projection else { return AppLocalization.string("财富自由时间估算") }

        switch projection.status {
        case .alreadyFree:
            return AppLocalization.string("已达到财富自由")
        case let .projected(months):
            let years = months / 12
            let remainingMonths = months % 12
            if years > 0, remainingMonths > 0 {
                return AppLocalization.format("预计还需 %d 年 %d 月", years, remainingMonths)
            } else if years > 0 {
                return AppLocalization.format("预计还需 %d 年", years)
            } else {
                return AppLocalization.format("预计还需 %d 月", remainingMonths)
            }
        case .unreachable:
            return AppLocalization.string("当前无法财富自由")
        }
    }

    private var reasonText: String? {
        guard let projection else {
            return AppLocalization.string("记录资产快照后可开始估算")
        }

        switch projection.status {
        case .alreadyFree, .projected:
            return nil
        case .unreachable:
            if let requiredSalary = projection.requiredMonthlySalaryToReachFreedom {
                return AppLocalization.format(
                    AppLocalization.string("按当前参数，需控制月开销在 %@ 以内，或收入涨到 %@/月。"),
                    projection.maximumReachableMonthlyExpense.currencyString(),
                    requiredSalary.currencyString()
                )
            } else {
                return AppLocalization.format(
                    AppLocalization.string("按当前参数，需控制月开销在 %@ 以内。"),
                    projection.maximumReachableMonthlyExpense.currencyString()
                )
            }
        }
    }

    private var statusColor: Color {
        guard let projection else { return AssetTheme.textPrimary }
        switch projection.status {
        case .alreadyFree:
            return AssetTheme.goldSoft
        case .projected:
            return AssetTheme.textPrimary
        case .unreachable:
            return AssetTheme.accentOrange
        }
    }
}

struct DashboardFreedomProjectionChart: View {
    let projection: FinancialFreedomProjection

    private struct IncomeCoveragePoint: Identifiable {
        let id: String
        let monthOffset: Double
        let date: Date
        let passiveIncome: Double
    }

    private struct IncomeCoverageSegment: Identifiable {
        enum State {
            case aboveExpense
            case belowExpense
        }

        let id: String
        let state: State
        let points: [IncomeCoveragePoint]
    }

    private struct CrossingMarker {
        let monthOffset: Double
        let date: Date
        let passiveIncome: Double
    }

    private struct ChartAnalysis {
        let segments: [IncomeCoverageSegment]
        let crossingMarker: CrossingMarker?
    }

    private var points: [FinancialFreedomProjectionPoint] {
        projection.projectionPoints
    }

    private var chartAnalysis: ChartAnalysis {
        buildChartAnalysis()
    }

    private var valueDomain: ClosedRange<Double> {
        paddedDomain(values: points.flatMap { [$0.projectedPassiveIncome, $0.projectedMonthlyExpense] })
    }


    private var xDomain: ClosedRange<Date> {
        guard let first = points.first?.date,
              let last = points.last?.date else {
            let now = Date()
            return now...now
        }
        return first...last
    }

    private var xAxisDates: [Date] {
        chartAxisDates(points.map(\.date))
    }

    private var horizonText: String {
        let months = max(points.count - 1, 0)
        if months >= 12 {
            let years = months / 12
            let remainingMonths = months % 12
            if remainingMonths > 0 {
                return AppLocalization.format("未来 %d 年 %d 月", years, remainingMonths)
            }
            return AppLocalization.format("未来 %d 年", years)
        }
        return AppLocalization.format("未来 %d 月", months)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Spacer(minLength: 12)
                Text(horizonText)
                    .font(AppTypography.meta)
                    .foregroundStyle(AssetTheme.textSecondary)
            }

            HStack(spacing: 12) {
                projectionLegendChip(title: AppLocalization.string("被动收入"), color: AssetTheme.goldSoft)
                projectionLegendChip(title: AppLocalization.string("通胀开销"), color: AssetTheme.accentOrange, dashed: true)
            }

            HStack(alignment: .top, spacing: 8) {
                TimeMachineAxisStrip(
                    topLabel: TimeMachineAxisValueStyle.currency(code: "CNY").compactLabel(for: valueDomain.upperBound),
                    middleLabel: TimeMachineAxisValueStyle.currency(code: "CNY").compactLabel(for: (valueDomain.lowerBound + valueDomain.upperBound) / 2),
                    bottomLabel: TimeMachineAxisValueStyle.currency(code: "CNY").compactLabel(for: valueDomain.lowerBound),
                    alignment: .leading,
                    color: AssetTheme.goldSoft
                )
                .frame(width: 42, height: 154)
                .padding(.top, 10)

                VStack(alignment: .leading, spacing: 8) {
                    Chart {
                        ForEach(chartAnalysis.segments) { segment in
                            ForEach(segment.points) { point in
                                LineMark(
                                    x: .value(AppLocalization.string("日期"), point.date),
                                    y: .value(AppLocalization.string("预计被动收入"), point.passiveIncome),
                                    series: .value(AppLocalization.string("系列"), segment.id)
                                )
                                .interpolationMethod(.monotone)
                                .lineStyle(StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
                                .foregroundStyle(segment.state == .aboveExpense ? AssetTheme.positive : AssetTheme.negative)
                            }
                        }

                        ForEach(points) { point in
                            LineMark(
                                x: .value(AppLocalization.string("日期"), point.date),
                                y: .value(AppLocalization.string("通胀后月开销"), point.projectedMonthlyExpense),
                                series: .value(AppLocalization.string("系列"), AppLocalization.string("通胀后月开销"))
                            )
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round, dash: [6, 4]))
                            .foregroundStyle(AssetTheme.accentOrange.opacity(0.9))
                        }


                        if let crossingMarker = chartAnalysis.crossingMarker {
                            RuleMark(x: .value(AppLocalization.string("追平时间"), crossingMarker.date))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                                .foregroundStyle(AssetTheme.positive.opacity(0.8))
                                .annotation(position: .top, spacing: 6) {
                                    crossingBadge(for: crossingMarker.monthOffset)
                                }

                            PointMark(
                                x: .value(AppLocalization.string("追平时间"), crossingMarker.date),
                                y: .value(AppLocalization.string("追平值"), crossingMarker.passiveIncome)
                            )
                            .foregroundStyle(AssetTheme.positive)
                            .symbolSize(40)
                        }

                        if let latestPoint = points.last {
                            PointMark(
                                x: .value(AppLocalization.string("日期"), latestPoint.date),
                                y: .value(AppLocalization.string("预计被动收入"), latestPoint.projectedPassiveIncome)
                            )
                            .foregroundStyle(latestPoint.projectedPassiveIncome >= latestPoint.projectedMonthlyExpense ? AssetTheme.positive : AssetTheme.negative)
                            .symbolSize(36)

                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 188)
                    .chartXScale(domain: xDomain)
                    .chartYScale(domain: valueDomain)
                    .chartXAxis {
                        AxisMarks(values: xAxisDates) { _ in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.75, dash: [2, 5]))
                                .foregroundStyle(AssetTheme.chartGrid.opacity(0.68))
                            AxisTick(stroke: StrokeStyle(lineWidth: 0.8))
                                .foregroundStyle(AssetTheme.chartTick.opacity(0.7))
                            AxisValueLabel {
                                EmptyView()
                            }
                        }
                    }
                    .chartYAxis {
                        AxisMarks(values: .automatic(desiredCount: 4)) { value in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.75, dash: [2, 5]))
                                .foregroundStyle(AssetTheme.chartGrid.opacity(0.68))
                            AxisTick(stroke: StrokeStyle(lineWidth: 0.8))
                                .foregroundStyle(.clear)
                            AxisValueLabel {
                                EmptyView()
                            }
                        }
                    }
                    .chartLegend(.hidden)
                    .chartPlotStyle { plotArea in
                        plotArea
                            .background(
                                LinearGradient(
                                    colors: [
                                        AssetTheme.overlayFaint.opacity(0.45),
                                        AssetTheme.overlaySubtle.opacity(0.10)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .overlay(alignment: .topLeading) {
                        Text(AppLocalization.string("收入覆盖趋势"))
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(AssetTheme.textSecondary.opacity(0.72))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                    }

                    freedomProjectionBottomLabels
                        .padding(.horizontal, 4)
                }
            }

            if let latestPoint = points.last {
                VStack(spacing: 0) {
                    HStack(spacing: 14) {
                        projectionMetric(title: AppLocalization.string("当前被动收入"), value: projection.currentPassiveIncome.currencyString())
                        projectionMetric(title: AppLocalization.string("当前月开销"), value: projection.currentMonthlyExpense.currencyString())
                        projectionMetric(title: AppLocalization.string("终点被动收入"), value: latestPoint.projectedPassiveIncome.currencyString())
                    }

                    Rectangle()
                        .fill(AssetTheme.border.opacity(0.28))
                        .frame(height: 1)
                        .padding(.vertical, 8)

                    HStack(spacing: 14) {
                        projectionMetric(title: AppLocalization.string("当前总资产"), value: projection.currentTotalAssets.currencyString())
                        projectionMetric(title: AppLocalization.string("终点总资产"), value: latestPoint.projectedTotalAssets.currencyString())
                    }
                }
            }
        }
    }

    private func axisLabelPosition(for date: Date, in axisDates: [Date]) -> TimeMachineAxisDateLabel.Position {
        guard let first = axisDates.first, let last = axisDates.last else { return .middle }
        if Calendar.current.isDate(date, inSameDayAs: first) {
            return .leading
        }
        if Calendar.current.isDate(date, inSameDayAs: last) {
            return .trailing
        }
        return .middle
    }

    @ViewBuilder
    private func freedomProjectionAxisLabel(for date: Date, position: TimeMachineAxisDateLabel.Position) -> some View {
        Text(date.dashboardAxisDateString)
            .font(.system(size: 9, weight: .medium, design: .rounded))
            .foregroundStyle(AssetTheme.textSecondary)
            .lineLimit(1)
            .fixedSize()
            .frame(minWidth: 34, alignment: freedomProjectionAxisAlignment(for: position))
    }

    private var freedomProjectionBottomLabels: some View {
        HStack(alignment: .top, spacing: 0) {
            if let first = xAxisDates.first {
                freedomProjectionAxisLabel(for: first, position: .leading)
            }

            Spacer(minLength: 12)

            if xAxisDates.count > 2 {
                let middle = xAxisDates[xAxisDates.count / 2]
                freedomProjectionAxisLabel(for: middle, position: .middle)
                Spacer(minLength: 12)
            }

            if xAxisDates.count > 1, let last = xAxisDates.last {
                freedomProjectionAxisLabel(for: last, position: .trailing)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func freedomProjectionAxisAlignment(for position: TimeMachineAxisDateLabel.Position) -> Alignment {
        switch position {
        case .leading:
            return .leading
        case .middle:
            return .center
        case .trailing:
            return .trailing
        }
    }

    private func buildChartAnalysis() -> ChartAnalysis {
        guard let firstPoint = points.first else {
            return ChartAnalysis(segments: [], crossingMarker: nil)
        }

        func coverageState(for point: FinancialFreedomProjectionPoint) -> IncomeCoverageSegment.State {
            point.projectedPassiveIncome >= point.projectedMonthlyExpense ? .aboveExpense : .belowExpense
        }

        func makeCoveragePoint(from point: FinancialFreedomProjectionPoint, suffix: String = "") -> IncomeCoveragePoint {
            IncomeCoveragePoint(
                id: "\(point.monthOffset)\(suffix)",
                monthOffset: Double(point.monthOffset),
                date: point.date,
                passiveIncome: point.projectedPassiveIncome
            )
        }

        var segments: [IncomeCoverageSegment] = []
        var currentSegmentState = coverageState(for: firstPoint)
        var currentPoints: [IncomeCoveragePoint] = [makeCoveragePoint(from: firstPoint)]
        var crossingMarker: CrossingMarker?
        var segmentIndex = 0

        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            let previousGap = previous.projectedPassiveIncome - previous.projectedMonthlyExpense
            let currentGap = current.projectedPassiveIncome - current.projectedMonthlyExpense

            let previousState = coverageState(for: previous)
            let currentState = coverageState(for: current)
            let hasCrossing = previousState != currentState && abs(previousGap - currentGap) > .ulpOfOne

            if hasCrossing {
                let progress = previousGap / (previousGap - currentGap)
                let clampedProgress = min(max(progress, 0), 1)
                let crossingMonthOffset = Double(previous.monthOffset) + (Double(current.monthOffset - previous.monthOffset) * clampedProgress)
                let crossingDate = previous.date.addingTimeInterval(current.date.timeIntervalSince(previous.date) * clampedProgress)
                let crossingIncome = previous.projectedPassiveIncome + ((current.projectedPassiveIncome - previous.projectedPassiveIncome) * clampedProgress)
                let crossingPoint = IncomeCoveragePoint(
                    id: "crossing-\(index)",
                    monthOffset: crossingMonthOffset,
                    date: crossingDate,
                    passiveIncome: crossingIncome
                )

                currentPoints.append(crossingPoint)
                segments.append(
                    IncomeCoverageSegment(
                        id: "income-segment-\(segmentIndex)",
                        state: currentSegmentState,
                        points: currentPoints
                    )
                )

                if crossingMarker == nil {
                    crossingMarker = CrossingMarker(
                        monthOffset: crossingMonthOffset,
                        date: crossingDate,
                        passiveIncome: crossingIncome
                    )
                }

                segmentIndex += 1
                currentSegmentState = currentState
                currentPoints = [crossingPoint, makeCoveragePoint(from: current)]
            } else {
                currentPoints.append(makeCoveragePoint(from: current))
            }
        }

        segments.append(
            IncomeCoverageSegment(
                id: "income-segment-\(segmentIndex)",
                state: currentSegmentState,
                points: currentPoints
            )
        )

        return ChartAnalysis(segments: segments, crossingMarker: crossingMarker)
    }

    private func crossingBadge(for monthOffset: Double) -> some View {
        Text(AppLocalization.format(AppLocalization.string("约 %@ 追平"), crossingLabel(for: monthOffset)))
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .foregroundStyle(AssetTheme.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(AssetTheme.surfaceRaised.opacity(0.96), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(AssetTheme.positive.opacity(0.35), lineWidth: 1)
            )
    }

    private func crossingLabel(for monthOffset: Double) -> String {
        let roundedMonths = max(Int(monthOffset.rounded()), 0)
        if roundedMonths >= 12 {
            let years = roundedMonths / 12
            let months = roundedMonths % 12
            if months > 0 {
                return AppLocalization.format(AppLocalization.string("%d 年 %d 月"), years, months)
            }
            return AppLocalization.format(AppLocalization.string("%d 年"), years)
        }
        return AppLocalization.format(AppLocalization.string("%d 月"), max(roundedMonths, 1))
    }


    private func paddedDomain(values: [Double]) -> ClosedRange<Double> {
        let filtered = values.filter { $0.isFinite }
        guard let minValue = filtered.min(), let maxValue = filtered.max() else {
            return 0...1
        }
        if abs(maxValue - minValue) < .ulpOfOne {
            let padding = max(abs(maxValue) * 0.08, 1)
            return (minValue - padding)...(maxValue + padding)
        }
        let padding = max((maxValue - minValue) * 0.12, abs(maxValue) * 0.02)
        return (minValue - padding)...(maxValue + padding)
    }

    private func projectionLegendChip(title: String, color: Color, dashed: Bool = false) -> some View {
        HStack(spacing: 6) {
            Group {
                if dashed {
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

            Text(title)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(AssetTheme.textSecondary.opacity(0.88))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.vertical, 4)
    }

    private func projectionMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(AssetTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            Text(value)
                .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                .foregroundStyle(AssetTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DashboardTrendCard: View {
    let points: [TimeMachineTrendPoint]
    let latestPoint: TimeMachineTrendPoint
    @State private var selectedDate: Date?

    private var displayPoints: [TimeMachineTrendPoint] {
        evenlySampledItems(points, maxCount: 120)
    }

    private var selectedPoint: TimeMachineTrendPoint {
        guard let selectedDate else { return latestPoint }
        return nearestChartPoint(displayPoints, to: selectedDate, date: \.date) ?? latestPoint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                ForEach(TimeMachineAssetSeries.allCases) { series in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 999, style: .continuous)
                            .fill(series.color)
                            .frame(width: 16, height: 3)
                            .overlay {
                                if series == .liabilities {
                                    HStack(spacing: 3) {
                                        ForEach(0..<3, id: \.self) { _ in
                                            Capsule()
                                                .fill(series.color)
                                                .frame(width: 4, height: 3)
                                        }
                                    }
                                }
                            }

                        Text(series.title)
                            .font(AppTypography.meta)
                            .foregroundStyle(AssetTheme.textSecondary)
                    }
                }
            }

            Chart {
                ForEach(TimeMachineAssetSeries.allCases) { series in
                    ForEach(displayPoints) { point in
                        LineMark(
                            x: .value(AppLocalization.string("日期"), point.date),
                            y: .value(series.title, series.value(from: point))
                        )
                        .foregroundStyle(by: .value(AppLocalization.string("序列"), series.title))
                        .lineStyle(series.strokeStyle)
                        .interpolationMethod(.catmullRom)
                    }

                    PointMark(
                        x: .value(AppLocalization.string("日期"), selectedPoint.date),
                        y: .value(series.title, series.value(from: selectedPoint))
                    )
                    .foregroundStyle(series.color)
                    .symbolSize(44)
                }

                if selectedDate != nil {
                    RuleMark(x: .value(AppLocalization.string("选中日期"), selectedPoint.date))
                        .foregroundStyle(AssetTheme.textSecondary.opacity(0.45))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
            }
            .chartForegroundStyleScale([
                TimeMachineAssetSeries.mainAssets.title: TimeMachineAssetSeries.mainAssets.color,
                TimeMachineAssetSeries.netAssets.title: TimeMachineAssetSeries.netAssets.color,
                TimeMachineAssetSeries.liabilities.title: TimeMachineAssetSeries.liabilities.color,
            ])
            .frame(height: 236)
            .chartXAxis {
                let axisDates = chartAxisDates(displayPoints.map(\.date))
                AxisMarks(values: axisDates) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                        .foregroundStyle(AssetTheme.chartGrid)
                    AxisTick().foregroundStyle(AssetTheme.chartTick)
                    AxisValueLabel(anchor: axisLabelAnchor(for: value.as(Date.self), in: axisDates), verticalSpacing: 6) {
                        if let date = value.as(Date.self) {
                            Text(date.dashboardAxisDateString)
                                .font(.system(size: 8.5, weight: .medium, design: .rounded))
                                .foregroundStyle(AssetTheme.textSecondary)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                        .foregroundStyle(AssetTheme.chartGrid)
                    AxisValueLabel(format: FloatingPointFormatStyle<Double>.number.notation(.compactName))
                        .foregroundStyle(AssetTheme.textSecondary)
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
            .padding(.top, 2)

            Text(selectedDate == nil ? dateRangeLabel : selectedPoint.date.chartAxisDateString)
                .font(AppTypography.meta)
                .foregroundStyle(AssetTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.top, 8)
    }

    private var dateRangeLabel: String {
        guard let first = points.first?.date else { return AppLocalization.string("暂无范围") }
        return "\(first.chartAxisDateString) - \(latestPoint.date.chartAxisDateString)"
    }

    private func axisLabelPosition(for date: Date, in axisDates: [Date]) -> TimeMachineAxisDateLabel.Position {
        guard let first = axisDates.first, let last = axisDates.last else { return .middle }
        if Calendar.current.isDate(date, inSameDayAs: first) {
            return .leading
        }
        if Calendar.current.isDate(date, inSameDayAs: last) {
            return .trailing
        }
        return .middle
    }

    private func axisLabelAnchor(for date: Date?, in axisDates: [Date]) -> UnitPoint {
        guard let date else { return .top }
        switch axisLabelPosition(for: date, in: axisDates) {
        case .leading:
            return .topLeading
        case .middle:
            return .top
        case .trailing:
            return .topTrailing
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
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
            }
            .foregroundStyle(AssetTheme.textPrimary)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(AssetTheme.overlayFaint.opacity(0.55), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct TimeMachineInlineMetric: View {
    let title: String
    let value: String
    let accent: Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(accent.opacity(0.92))
                .frame(width: 7, height: 7)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 4) {
                Text(AppLocalization.string(title))
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(AssetTheme.textSecondary.opacity(0.82))
                    .lineLimit(1)

                Text(value)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(AssetTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
    }
}

struct TimeMachineCurrentAnchorItem: Identifiable {
    let title: String
    let value: String
    let detail: String
    let accent: Color

    var id: String { title }
}

struct TimeMachineHeroTrendCard: View {
    let points: [TimeMachineTrendPoint]
    let latestPoint: TimeMachineTrendPoint
    @Binding var selectedRange: TimeMachineRange
    @State private var selectedDate: Date?
    private let cardCornerRadius: CGFloat = 26
    private let plotCornerRadius: CGFloat = 20
    private let displayPoints: [TimeMachineTrendPoint]
    private let valueDomain: ClosedRange<Double>
    private let dateDomain: ClosedRange<Date>
    private let axisDates: [Date]
    private let dateAxisKey = AppLocalization.string("日期")
    private let seriesAxisKey = AppLocalization.string("序列")
    private let selectedDateAxisKey = AppLocalization.string("选中日期")

    init(points: [TimeMachineTrendPoint], latestPoint: TimeMachineTrendPoint, selectedRange: Binding<TimeMachineRange>) {
        self.points = points
        self.latestPoint = latestPoint
        self._selectedRange = selectedRange

        let sampledPoints = evenlySampledItems(points, maxCount: 60)
        self.displayPoints = sampledPoints
        self.valueDomain = Self.paddedDomain(values: sampledPoints.flatMap { point in
            TimeMachineAssetSeries.allCases.map { $0.value(from: point) }
        })
        self.dateDomain = Self.makeDateDomain(from: sampledPoints)
        self.axisDates = chartAxisDates(sampledPoints.map(\.date))
    }

    private var selectedPoint: TimeMachineTrendPoint {
        guard let selectedDate else { return latestPoint }
        return nearestChartPoint(displayPoints, to: selectedDate, date: \.date) ?? latestPoint
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
        VStack(alignment: .leading, spacing: 13) {
            heroHeader
            metricGrid
            legendRow

            Chart {
                ForEach(TimeMachineAssetSeries.allCases) { series in
                    ForEach(displayPoints) { point in
                        LineMark(
                            x: .value(dateAxisKey, point.date),
                            y: .value(series.title, series.value(from: point))
                        )
                        .foregroundStyle(by: .value(seriesAxisKey, series.title))
                        .lineStyle(series.strokeStyle)
                        .interpolationMethod(.catmullRom)
                    }

                    PointMark(
                        x: .value(dateAxisKey, selectedPoint.date),
                        y: .value(series.title, series.value(from: selectedPoint))
                    )
                    .foregroundStyle(series.color)
                    .symbolSize(selectedDate == nil ? 36 : 58)
                }

                if selectedDate != nil {
                    RuleMark(x: .value(selectedDateAxisKey, selectedPoint.date))
                        .foregroundStyle(AssetTheme.textSecondary.opacity(0.38))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 5]))
                }
            }
            .chartForegroundStyleScale([
                TimeMachineAssetSeries.mainAssets.title: TimeMachineAssetSeries.mainAssets.color,
                TimeMachineAssetSeries.netAssets.title: TimeMachineAssetSeries.netAssets.color,
                TimeMachineAssetSeries.liabilities.title: TimeMachineAssetSeries.liabilities.color,
            ])
            .frame(height: 226)
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
                            TimeMachineAxisDateLabel(date: date, position: axisLabelPosition(for: date, in: axisDates))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.75, dash: [2, 5]))
                        .foregroundStyle(AssetTheme.chartGrid.opacity(0.72))
                    AxisValueLabel {
                        if let y = value.as(Double.self) {
                            Text(y, format: .number.notation(.compactName))
                                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                                .foregroundStyle(AssetTheme.textSecondary.opacity(0.72))
                        }
                    }
                }
            }
            .chartLegend(.hidden)
            .chartPlotStyle { plotArea in
                plotArea
                    .background(AssetTheme.surface.opacity(0.42))
                    .clipShape(RoundedRectangle(cornerRadius: plotCornerRadius, style: .continuous))
            }
            .chartOverlay { proxy in
                TimeMachineDragOverlay(proxy: proxy) { date in
                    selectedDate = date
                } onEnded: {
                    selectedDate = nil
                }
            }
            .padding(.horizontal, 3)
            .padding(.top, 2)
            .padding(.bottom, 6)
            .onboardingAnchor(.timeMachineChart)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .fill(AssetTheme.cardGradient)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .stroke(AssetTheme.border.opacity(0.5), lineWidth: 1)
        )
        .shadow(color: AssetTheme.cardShadow.opacity(0.78), radius: 18, x: 0, y: 10)
    }

    private var heroHeader: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .center, spacing: 10) {
                Text(AppLocalization.string("总资产"))
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(AssetTheme.textPrimary)

                Spacer(minLength: 10)

                TimeMachineRangeSelector(selectedRange: $selectedRange)
            }
            .onboardingAnchor(.timeMachineRange)

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(selectedPoint.mainAssets.currencyString())
                    .font(.system(size: 31, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(AssetTheme.goldSoft)
                    .lineLimit(1)
                    .minimumScaleFactor(0.66)

                Spacer(minLength: 8)

                Text(selectedDate == nil ? dateRangeLabel : selectedPoint.date.chartAxisDateString)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(AssetTheme.textSecondary.opacity(0.84))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(AssetTheme.surface.opacity(0.72), in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(AssetTheme.border.opacity(selectedDate == nil ? 0.28 : 0.58), lineWidth: 1)
                    )
            }
        }
    }

    private var metricGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
            spacing: 8
        ) {
            TimeMachineInlineMetric(
                title: "净资产",
                value: selectedPoint.netAssets.currencyString(),
                accent: AssetTheme.positive
            )
            TimeMachineInlineMetric(
                title: "负债",
                value: selectedPoint.liabilities.currencyString(),
                accent: AssetTheme.negative
            )
            TimeMachineInlineMetric(
                title: "黄金折算",
                value: selectedPoint.goldEquivalent?.plainNumberString() ?? "--",
                accent: AssetTheme.gold
            )
            TimeMachineInlineMetric(
                title: "纳指折算",
                value: selectedPoint.nasdaqEquivalent?.plainNumberString() ?? "--",
                accent: AssetTheme.accentBlue
            )
        }
    }

    private var legendRow: some View {
        HStack(spacing: 7) {
            ForEach(TimeMachineAssetSeries.allCases) { series in
                TimeMachineHeroLegendItem(series: series)
            }
            Spacer(minLength: 0)
        }
    }

    private var dateRangeLabel: String {
        guard let first = points.first?.date, let last = points.last?.date else { return AppLocalization.string("暂无范围") }
        return "\(first.chartAxisDateString) - \(last.chartAxisDateString)"
    }

    private func axisLabelPosition(for date: Date, in axisDates: [Date]) -> TimeMachineAxisDateLabel.Position {
        guard let first = axisDates.first, let last = axisDates.last else { return .middle }
        if Calendar.current.isDate(date, inSameDayAs: first) {
            return .leading
        }
        if Calendar.current.isDate(date, inSameDayAs: last) {
            return .trailing
        }
        return .middle
    }

    private static func paddedDomain(values: [Double]) -> ClosedRange<Double> {
        let filtered = values.filter { $0.isFinite }
        guard let minValue = filtered.min(), let maxValue = filtered.max() else {
            return 0...1
        }
        if abs(maxValue - minValue) < .ulpOfOne {
            let padding = max(abs(maxValue) * 0.08, 1)
            return (minValue - padding)...(maxValue + padding)
        }
        let padding = max((maxValue - minValue) * 0.12, abs(maxValue) * 0.02)
        return (minValue - padding)...(maxValue + padding)
    }
}

struct TimeMachineHeroLegendItem: View {
    let series: TimeMachineAssetSeries

    var body: some View {
        HStack(spacing: 5) {
            legendMark

            Text(series.title)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(AssetTheme.textSecondary.opacity(0.88))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var legendMark: some View {
        if series == .liabilities {
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { _ in
                    Capsule()
                        .fill(series.color)
                        .frame(width: 4, height: 3)
                }
            }
            .frame(width: 16, alignment: .leading)
        } else {
            Capsule()
                .fill(series.color)
                .frame(width: 16, height: 3)
        }
    }
}

func nearestChartPoint<T>(_ points: [T], to date: Date, date keyPath: KeyPath<T, Date>) -> T? {
    points.min { abs($0[keyPath: keyPath].timeIntervalSince(date)) < abs($1[keyPath: keyPath].timeIntervalSince(date)) }
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
            .font(.system(size: 9.5, weight: .medium, design: .rounded))
            .foregroundStyle(AssetTheme.textSecondary)
            .lineLimit(1)
            .fixedSize()
            .offset(x: xOffset)
    }
}

struct TimeMachineMonthlySurplusCard: View {
    let points: [TimeMachineMonthlySurplusPoint]
    let annualPoints: [TimeMachineAnnualSurplusPoint]
    @State private var selectedDate: Date?
    @State private var selectedGranularity: SurplusGranularity = .monthly
    private let cardCornerRadius: CGFloat = 22
    private let chartCornerRadius: CGFloat = 18

    private enum SurplusGranularity: String, CaseIterable, Identifiable {
        case monthly
        case annual

        var id: String { rawValue }

        var title: String {
            switch self {
            case .monthly: return AppLocalization.string("月结余")
            case .annual: return AppLocalization.string("年结余")
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

    private var displayPoints: [TimeMachineMonthlySurplusPoint] {
        evenlySampledItems(points, maxCount: 48)
    }

    private var latestPoint: TimeMachineMonthlySurplusPoint? {
        displayPoints.last ?? points.last
    }

    private var selectedPoint: TimeMachineMonthlySurplusPoint? {
        guard let latestPoint else { return nil }
        guard let selectedDate else { return latestPoint }
        return nearestChartPoint(displayPoints, to: selectedDate, date: \.monthStart) ?? latestPoint
    }

    private var latestAnnualPoint: TimeMachineAnnualSurplusPoint? {
        annualPoints.last
    }

    private var leftDomain: ClosedRange<Double> {
        TimeMachineSurplusFormatting.paddedDomain(values: displayPoints.map(\.surplus))
    }

    private var averageSurplus: Double {
        guard !points.isEmpty else { return 0 }
        return points.reduce(0) { $0 + $1.surplus } / Double(points.count)
    }

    private var positiveMonthCount: Int {
        points.filter { $0.surplus >= 0 }.count
    }

    private var bestMonthPoint: TimeMachineMonthlySurplusPoint? {
        points.max { $0.surplus < $1.surplus }
    }

    private var currentDateLabel: String {
        switch activeGranularity {
        case .monthly:
            return selectedDate == nil ? dateRangeLabel : (selectedPoint?.monthStart.dashboardAxisDateString ?? dateRangeLabel)
        case .annual:
            guard let first = annualPoints.first?.yearStart, let last = annualPoints.last?.yearStart else {
                return AppLocalization.string("暂无范围")
            }
            return "\(first.yearAxisDateString) - \(last.yearAxisDateString)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if activeGranularity == .monthly, !displayPoints.isEmpty {
                chartSection
            } else if activeGranularity == .annual, !annualPoints.isEmpty {
                TimeMachineAnnualSurplusCard(points: annualPoints)
            }

            if activeGranularity == .monthly {
                summaryRow
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .fill(AssetTheme.cardGradient)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .stroke(AssetTheme.border.opacity(0.42), lineWidth: 1)
        )
        .shadow(color: AssetTheme.cardShadow.opacity(0.46), radius: 14, x: 0, y: 8)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Text(AppLocalization.string("结余"))
                    .font(.system(size: 16.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(AssetTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Spacer(minLength: 8)

                Picker(AppLocalization.string("结余周期"), selection: $selectedGranularity) {
                    ForEach(SurplusGranularity.allCases) { granularity in
                        Text(granularity.title).tag(granularity)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 132)
                .disabled(points.isEmpty || annualPoints.isEmpty)
            }

            if activeGranularity == .monthly {
                HStack(alignment: .center, spacing: 8) {
                    Text(currentDateLabel)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(AssetTheme.textSecondary.opacity(0.84))
                        .lineLimit(1)
                        .minimumScaleFactor(0.74)

                    Spacer(minLength: 8)

                    if let selectedPoint {
                        TimeMachineCompactLegendMetric(
                            title: AppLocalization.string("结余"),
                            value: TimeMachineSurplusFormatting.formatted(selectedPoint.surplus),
                            color: TimeMachineSurplusFormatting.color(for: selectedPoint.surplus),
                            dashed: false
                        )
                    }
                }
            }
        }
    }

    private var chartSection: some View {
        GeometryReader { geometry in
            let leftWidth: CGFloat = 46
            let chartWidth = max(geometry.size.width - leftWidth - 18, 120)

            HStack(spacing: 6) {
                TimeMachineAxisStrip(
                    topLabel: TimeMachineAxisValueStyle.currency(code: "CNY").compactLabel(for: leftDomain.upperBound),
                    middleLabel: TimeMachineAxisValueStyle.currency(code: "CNY").compactLabel(for: (leftDomain.lowerBound + leftDomain.upperBound) / 2),
                    bottomLabel: TimeMachineAxisValueStyle.currency(code: "CNY").compactLabel(for: leftDomain.lowerBound),
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
                        .foregroundStyle(TimeMachineSurplusFormatting.color(for: point.surplus).opacity(selectedPoint?.id == point.id ? 0.96 : 0.82))
                    }

                    if selectedDate != nil, let selectedPoint {
                        RuleMark(x: .value(AppLocalization.string("选中月份"), selectedPoint.monthStart))
                            .foregroundStyle(AssetTheme.textSecondary.opacity(0.45))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                }
                .frame(width: chartWidth, height: 168)
                .chartYScale(domain: 0...1)
                .chartYAxis(.hidden)
                .chartXAxis { bottomAxisMarks }
                .chartLegend(.hidden)
                .chartOverlay { proxy in
                    TimeMachineDragOverlay(proxy: proxy) { date in
                        selectedDate = date
                    } onEnded: {
                        selectedDate = nil
                    }
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 9)
            .background(chartBackground)
        }
        .frame(height: 186)
    }

    private var summaryRow: some View {
        HStack(spacing: 8) {
            TimeMachineLegendMetric(
                title: AppLocalization.string("月均结余"),
                value: TimeMachineSurplusFormatting.formatted(averageSurplus),
                color: TimeMachineSurplusFormatting.color(for: averageSurplus),
                dashed: false
            )

            TimeMachineLegendMetric(
                title: AppLocalization.string("正结余月份"),
                value: "\(positiveMonthCount)/\(points.count)",
                color: AssetTheme.positive,
                dashed: false
            )

            TimeMachineLegendMetric(
                title: AppLocalization.string("最好单月"),
                value: bestMonthPoint.map { TimeMachineSurplusFormatting.formatted($0.surplus) } ?? "--",
                color: AssetTheme.goldSoft,
                dashed: true
            )
        }
    }

    private var bottomAxisMarks: some AxisContent {
        let axisDates = chartAxisDates(displayPoints.map(\.monthStart))
        return AxisMarks(values: axisDates) { value in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.7, dash: [2, 4]))
                .foregroundStyle(AssetTheme.border.opacity(0.28))
            AxisTick(stroke: StrokeStyle(lineWidth: 0.8))
                .foregroundStyle(AssetTheme.border.opacity(0.5))
            AxisValueLabel(anchor: .top, verticalSpacing: 8) {
                if let date = value.as(Date.self) {
                    Text(date.dashboardAxisDateString)
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(AssetTheme.textSecondary)
                }
            }
        }
    }

    private var chartBackground: some View {
        RoundedRectangle(cornerRadius: chartCornerRadius, style: .continuous)
            .fill(AssetTheme.surface.opacity(0.46))
    }

    private var dateRangeLabel: String {
        guard let first = points.first?.monthStart, let last = points.last?.monthStart else { return AppLocalization.string("暂无范围") }
        return "\(first.dashboardAxisDateString) - \(last.dashboardAxisDateString)"
    }

    private func normalized(_ value: Double, in domain: ClosedRange<Double>) -> Double {
        let span = domain.upperBound - domain.lowerBound
        guard span.isFinite, span > 0 else { return 0.5 }
        return (value - domain.lowerBound) / span
    }
}

struct TimeMachineAnnualSurplusCard: View {
    let points: [TimeMachineAnnualSurplusPoint]
    @State private var selectedDate: Date?
    private let cardCornerRadius: CGFloat = 22
    private let chartCornerRadius: CGFloat = 18

    private var displayPoints: [TimeMachineAnnualSurplusPoint] {
        Array(points.suffix(12))
    }

    private var latestPoint: TimeMachineAnnualSurplusPoint? {
        points.last
    }

    private var selectedPoint: TimeMachineAnnualSurplusPoint? {
        guard let latestPoint else { return nil }
        guard let selectedDate else { return latestPoint }
        return nearestChartPoint(displayPoints, to: selectedDate, date: \.yearStart) ?? latestPoint
    }

    private var averageSurplus: Double {
        guard !points.isEmpty else { return 0 }
        return points.reduce(0) { $0 + $1.surplus } / Double(points.count)
    }

    private var positiveYearCount: Int {
        points.filter { $0.surplus >= 0 }.count
    }

    private var bestYearPoint: TimeMachineAnnualSurplusPoint? {
        points.max { $0.surplus < $1.surplus }
    }

    private var domain: ClosedRange<Double> {
        TimeMachineSurplusFormatting.paddedDomain(values: displayPoints.map(\.surplus))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                Text(AppLocalization.string("按每年最后一条快照，和上一年年末净资产对比"))
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(AssetTheme.textSecondary.opacity(0.84))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Spacer(minLength: 8)

                if let selectedPoint {
                    TimeMachineCompactLegendMetric(
                        title: selectedPoint.isCurrentYear ? AppLocalization.string("今年至今") : selectedPoint.yearStart.yearAxisDateString,
                        value: TimeMachineSurplusFormatting.formatted(selectedPoint.surplus),
                        color: TimeMachineSurplusFormatting.color(for: selectedPoint.surplus),
                        dashed: false
                    )
                }
            }

            if !displayPoints.isEmpty {
                chartSection
            }

            summaryRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(AppLocalization.string("年结余"))
                    .font(.system(size: 15.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(AssetTheme.textPrimary)
                    .lineLimit(1)

                Text(AppLocalization.string("按每年最后一条快照，和上一年年末净资产对比"))
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(AssetTheme.textSecondary.opacity(0.84))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            Spacer(minLength: 8)

            if let latestPoint {
                TimeMachineCompactLegendMetric(
                    title: latestPoint.isCurrentYear ? AppLocalization.string("今年至今") : AppLocalization.string("最近一年"),
                    value: TimeMachineSurplusFormatting.formatted(latestPoint.surplus),
                    color: TimeMachineSurplusFormatting.color(for: latestPoint.surplus),
                    dashed: false
                )
            }
        }
    }

    private var chartSection: some View {
        GeometryReader { geometry in
            let leftWidth: CGFloat = 46
            let chartWidth = max(geometry.size.width - leftWidth - 18, 120)

            HStack(spacing: 6) {
                TimeMachineAxisStrip(
                    topLabel: TimeMachineAxisValueStyle.currency(code: "CNY").compactLabel(for: domain.upperBound),
                    middleLabel: TimeMachineAxisValueStyle.currency(code: "CNY").compactLabel(for: (domain.lowerBound + domain.upperBound) / 2),
                    bottomLabel: TimeMachineAxisValueStyle.currency(code: "CNY").compactLabel(for: domain.lowerBound),
                    alignment: .leading,
                    color: AssetTheme.gold
                )
                .frame(width: leftWidth)

                Chart {
                    RuleMark(y: .value(AppLocalization.string("零线"), normalized(0, in: domain)))
                        .foregroundStyle(AssetTheme.border.opacity(0.42))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))

                    ForEach(displayPoints) { point in
                        BarMark(
                            x: .value(AppLocalization.string("年份"), point.yearStart),
                            yStart: .value(AppLocalization.string("零线"), normalized(0, in: domain)),
                            yEnd: .value(AppLocalization.string("年结余"), normalized(point.surplus, in: domain))
                        )
                        .foregroundStyle(TimeMachineSurplusFormatting.color(for: point.surplus).opacity(selectedPoint?.id == point.id ? 0.96 : 0.82))
                    }

                    if selectedDate != nil, let selectedPoint {
                        RuleMark(x: .value(AppLocalization.string("选中年份"), selectedPoint.yearStart))
                            .foregroundStyle(AssetTheme.textSecondary.opacity(0.45))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                }
                .frame(width: chartWidth, height: 138)
                .chartYScale(domain: 0...1)
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks(values: displayPoints.map(\.yearStart)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.7, dash: [2, 4]))
                            .foregroundStyle(AssetTheme.border.opacity(0.24))
                        AxisTick(stroke: StrokeStyle(lineWidth: 0.8))
                            .foregroundStyle(AssetTheme.border.opacity(0.44))
                        AxisValueLabel(anchor: .top, verticalSpacing: 8) {
                            if let date = value.as(Date.self) {
                                Text(date.yearAxisDateString)
                                    .font(.system(size: 9, weight: .medium, design: .rounded))
                                    .foregroundStyle(AssetTheme.textSecondary)
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
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 9)
            .background(chartBackground)
        }
        .frame(height: 156)
    }

    private var summaryRow: some View {
        HStack(spacing: 8) {
            TimeMachineLegendMetric(
                title: AppLocalization.string("年均结余"),
                value: TimeMachineSurplusFormatting.formatted(averageSurplus),
                color: TimeMachineSurplusFormatting.color(for: averageSurplus),
                dashed: false
            )

            TimeMachineLegendMetric(
                title: AppLocalization.string("正结余年份"),
                value: "\(positiveYearCount)/\(points.count)",
                color: AssetTheme.positive,
                dashed: false
            )

            TimeMachineLegendMetric(
                title: AppLocalization.string("最好年份"),
                value: bestYearPoint.map { TimeMachineSurplusFormatting.formatted($0.surplus) } ?? "--",
                color: AssetTheme.goldSoft,
                dashed: true
            )
        }
    }

    private var chartBackground: some View {
        RoundedRectangle(cornerRadius: chartCornerRadius, style: .continuous)
            .fill(AssetTheme.surface.opacity(0.46))
    }

    private func normalized(_ value: Double, in domain: ClosedRange<Double>) -> Double {
        let span = domain.upperBound - domain.lowerBound
        guard span.isFinite, span > 0 else { return 0.5 }
        return (value - domain.lowerBound) / span
    }
}

struct TimeMachineCurrentAnchorCard: View {
    let items: [TimeMachineCurrentAnchorItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppLocalization.string("最新快照锚点"))
                .font(.subheadline.weight(.bold))
                .foregroundStyle(AssetTheme.textPrimary)

            ForEach(items) { item in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 999, style: .continuous)
                        .fill(item.accent)
                        .frame(width: 12, height: 3)

                    Text(AppLocalization.string(item.title))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AssetTheme.textSecondary)

                    Text(item.value)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(item.accent)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(item.detail)
                        .font(.caption)
                        .foregroundStyle(AssetTheme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
            }
        }
        .atmCardStyle()
        .onboardingAnchor(.timeMachineAnchors)
    }
}

struct TimeMachineComparisonRevealButtons: View {
    let options: [TimeMachineDetailComparisonOption]
    let onReveal: (TimeMachineDetailComparisonOption) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 118), spacing: 8, alignment: .leading)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppLocalization.string("更多对照"))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(AssetTheme.textSecondary)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(options) { option in
                    Button {
                        onReveal(option)
                    } label: {
                        HStack(spacing: 7) {
                            Circle()
                                .fill(option.color)
                                .frame(width: 7, height: 7)
                            Text(AppLocalization.format("显示%@", option.title))
                                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                                .lineLimit(1)
                                .minimumScaleFactor(0.76)
                        }
                        .foregroundStyle(AssetTheme.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                        .padding(.horizontal, 12)
                        .background(AssetTheme.surface.opacity(0.62), in: Capsule())
                        .overlay(
                            Capsule()
                                .stroke(AssetTheme.border.opacity(0.42), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(AssetTheme.surface.opacity(0.36))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AssetTheme.border.opacity(0.28), lineWidth: 1)
        )
    }
}

struct TimeMachineDualAxisTrendCard: View {
    let descriptor: TimeMachineCombinedTrendDescriptor
    var onTapHistory: ((TimeMachineHistoryDrilldown) -> Void)?
    @State private var selectedDate: Date?
    private let cardCornerRadius: CGFloat = 22
    private let chartCornerRadius: CGFloat = 18
    private let displayPoints: [TimeMachineDualAxisPoint]
    private let displayLeftOnlyPoints: [TimeMachineSingleAxisPoint]
    private let rangeFilteredCandlesticks: [TimeMachineCandlestickPoint]
    private let displayCandlesticks: [TimeMachineCandlestickPoint]
    private let leftDomain: ClosedRange<Double>
    private let rightDomain: ClosedRange<Double>
    private let canShowCandlestickChart: Bool
    private let canShowDualAxisChart: Bool
    private let canShowLeftOnlyChart: Bool
    private let bottomAxisDates: [Date]
    private let dateRangeLabel: String

    init(
        descriptor: TimeMachineCombinedTrendDescriptor,
        onTapHistory: ((TimeMachineHistoryDrilldown) -> Void)? = nil
    ) {
        self.descriptor = descriptor
        self.onTapHistory = onTapHistory

        self.displayPoints = descriptor.displayPoints
        self.displayLeftOnlyPoints = descriptor.displayLeftOnlyPoints
        self.rangeFilteredCandlesticks = descriptor.rangeFilteredCandlesticks
        self.displayCandlesticks = descriptor.displayCandlesticks
        self.canShowCandlestickChart = descriptor.canShowCandlestickChart
        self.canShowDualAxisChart = descriptor.canShowDualAxisChart
        self.canShowLeftOnlyChart = descriptor.canShowLeftOnlyChart
        self.leftDomain = descriptor.leftDomain
        self.rightDomain = descriptor.rightDomain
        self.bottomAxisDates = descriptor.bottomAxisDates
        self.dateRangeLabel = descriptor.dateRangeLabel
    }

    private var latestPoint: TimeMachineDualAxisPoint? {
        displayPoints.last ?? descriptor.points.last
    }

    private var selectedDualPoint: TimeMachineDualAxisPoint? {
        guard let selectedDate else { return latestPoint }
        return nearestChartPoint(displayPoints, to: selectedDate, date: \.date) ?? latestPoint
    }

    private var latestLeftOnlyPoint: TimeMachineSingleAxisPoint? {
        displayLeftOnlyPoints.last ?? descriptor.leftOnlyPoints.last
    }

    private var selectedLeftOnlyPoint: TimeMachineSingleAxisPoint? {
        guard let selectedDate else { return latestLeftOnlyPoint }
        return nearestChartPoint(displayLeftOnlyPoints, to: selectedDate, date: \.date) ?? latestLeftOnlyPoint
    }

    private var latestCandlestick: TimeMachineCandlestickPoint? {
        displayCandlesticks.last ?? rangeFilteredCandlesticks.last
    }

    private var selectedCandlestick: TimeMachineCandlestickPoint? {
        guard let selectedDate else { return latestCandlestick }
        return nearestChartPoint(displayCandlesticks, to: selectedDate, date: \.date) ?? latestCandlestick
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if canShowDualAxisChart {
                dualAxisChart
            } else if canShowLeftOnlyChart {
                leftOnlyChart
            } else {
                Text(AppLocalization.string("记录不足"))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(AssetTheme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 112, alignment: .center)
                    .background(chartBackground)
            }

            Text(selectedDate == nil ? dateRangeLabel : selectedAxisDateLabel)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(AssetTheme.textSecondary.opacity(0.84))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .fill(AssetTheme.cardGradient)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .stroke(AssetTheme.border.opacity(0.38), lineWidth: 1)
        )
        .shadow(color: AssetTheme.cardShadow.opacity(0.38), radius: 12, x: 0, y: 7)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 7) {
                Text(AppLocalization.string(descriptor.title))
                    .font(.system(size: 15.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(AssetTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                historyButton

                Spacer(minLength: 2)

                TimeMachineCompactLegendMetric(
                    title: descriptor.leftTitle,
                    value: selectedLeftLabel,
                    color: descriptor.leftColor,
                    dashed: false
                )

                if descriptor.showsComparisonLine {
                    TimeMachineCompactLegendMetric(
                        title: descriptor.rightTitle,
                        value: selectedRightLabel,
                        color: descriptor.rightColor,
                        dashed: true
                    )
                }
            }

            if let subtitle = descriptor.subtitle {
                Text(AppLocalization.string(subtitle))
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(AssetTheme.textSecondary.opacity(0.84))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
        }
    }

    private var historyButton: some View {
        let historyDrilldown = descriptor.historyDrilldown
        let isEnabled = historyDrilldown != nil

        return Button {
            guard let historyDrilldown else { return }
            onTapHistory?(historyDrilldown)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(isEnabled ? AssetTheme.goldSoft : AssetTheme.textSecondary.opacity(0.5))
                Text(AppLocalization.string("历史"))
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(isEnabled ? AssetTheme.textPrimary : AssetTheme.textSecondary.opacity(0.68))
            }
            .frame(width: 58, height: 26)
            .background(
                LinearGradient(
                    colors: isEnabled
                        ? [AssetTheme.overlayMedium.opacity(0.92), AssetTheme.overlaySubtle.opacity(0.82)]
                        : [AssetTheme.overlaySoft.opacity(0.72), AssetTheme.overlayFaint.opacity(0.8)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .stroke(isEnabled ? AssetTheme.border.opacity(0.66) : AssetTheme.border.opacity(0.32), lineWidth: 1)
            )
            .shadow(color: isEnabled ? AssetTheme.gold.opacity(0.08) : .clear, radius: 8, x: 0, y: 3)
            .opacity(isEnabled ? 1 : 0.78)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    private var dualAxisChart: some View {
        GeometryReader { geometry in
            let leftWidth: CGFloat = descriptor.showsComparisonLine ? 42 : 36
            let rightWidth: CGFloat = descriptor.showsComparisonLine ? 46 : 0
            let chartWidth = max(geometry.size.width - leftWidth - rightWidth - 30, 120)

            HStack(spacing: 6) {
                TimeMachineAxisStrip(
                    topLabel: descriptor.leftAxisStyle.compactLabel(for: leftDomain.upperBound),
                    middleLabel: descriptor.leftAxisStyle.compactLabel(for: (leftDomain.lowerBound + leftDomain.upperBound) / 2),
                    bottomLabel: descriptor.leftAxisStyle.compactLabel(for: leftDomain.lowerBound),
                    alignment: .leading,
                    color: descriptor.leftColor
                )
                .frame(width: leftWidth)

                Chart {
                    leftSeriesMarks
                    if descriptor.showsComparisonLine {
                        rightSeriesMarksNormalized
                    }
                    latestPointMarksNormalized
                    if selectedDate != nil, let selectedDualPoint {
                        RuleMark(x: .value(AppLocalization.string("选中日期"), selectedDualPoint.date))
                            .foregroundStyle(AssetTheme.textSecondary.opacity(0.45))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                }
                .frame(width: chartWidth, height: 150)
                .chartYScale(domain: 0...1)
                .chartYAxis(.hidden)
                .chartXAxis { bottomAxisMarks }
                .chartLegend(.hidden)
                .chartOverlay { proxy in
                    TimeMachineDragOverlay(proxy: proxy) { date in
                        selectedDate = date
                    } onEnded: {
                        selectedDate = nil
                    }
                }

                if descriptor.showsComparisonLine {
                    TimeMachineAxisStrip(
                        topLabel: descriptor.rightAxisStyle.compactLabel(for: rightDomain.upperBound),
                        middleLabel: descriptor.rightAxisStyle.compactLabel(for: (rightDomain.lowerBound + rightDomain.upperBound) / 2),
                        bottomLabel: descriptor.rightAxisStyle.compactLabel(for: rightDomain.lowerBound),
                        alignment: .trailing,
                        color: descriptor.rightColor
                    )
                    .frame(width: rightWidth)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 9)
            .background(chartBackground)
        }
        .frame(height: 168)
    }

    private var leftOnlyChart: some View {
        GeometryReader { geometry in
            let leftWidth: CGFloat = 36
            let chartWidth = max(geometry.size.width - leftWidth - 24, 120)

            HStack(spacing: 6) {
                TimeMachineAxisStrip(
                    topLabel: descriptor.leftAxisStyle.compactLabel(for: leftDomain.upperBound),
                    middleLabel: descriptor.leftAxisStyle.compactLabel(for: (leftDomain.lowerBound + leftDomain.upperBound) / 2),
                    bottomLabel: descriptor.leftAxisStyle.compactLabel(for: leftDomain.lowerBound),
                    alignment: .leading,
                    color: descriptor.leftColor
                )
                .frame(width: leftWidth)

                Chart {
                    leftOnlySeriesMarks
                    leftOnlyLatestPointMarks
                    if selectedDate != nil, let selectedLeftOnlyPoint {
                        RuleMark(x: .value(AppLocalization.string("选中日期"), selectedLeftOnlyPoint.date))
                            .foregroundStyle(AssetTheme.textSecondary.opacity(0.45))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                }
                .frame(width: chartWidth, height: 150)
                .chartYScale(domain: 0...1)
                .chartYAxis(.hidden)
                .chartXAxis { bottomAxisMarks }
                .chartLegend(.hidden)
                .chartOverlay { proxy in
                    TimeMachineDragOverlay(proxy: proxy) { date in
                        selectedDate = date
                    } onEnded: {
                        selectedDate = nil
                    }
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 9)
            .background(chartBackground)
        }
        .frame(height: 168)
    }

    @ChartContentBuilder
    private var leftSeriesMarks: some ChartContent {
        if canShowCandlestickChart {
            candlestickSeriesMarks
        } else {
            ForEach(displayLeftOnlyPoints) { point in
                LineMark(
                    x: .value(AppLocalization.string("日期"), point.date),
                    y: .value(descriptor.leftTitle, normalized(point.value, in: leftDomain)),
                    series: .value(AppLocalization.string("系列"), descriptor.leftTitle)
                )
                .foregroundStyle(descriptor.leftColor)
                .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.linear)
            }
        }
    }

    @ChartContentBuilder
    private var candlestickSeriesMarks: some ChartContent {
        ForEach(displayCandlesticks) { bar in
            RuleMark(
                x: .value(AppLocalization.string("日期"), bar.date),
                yStart: .value(AppLocalization.string("最低"), normalized(bar.low, in: leftDomain)),
                yEnd: .value(AppLocalization.string("最高"), normalized(bar.high, in: leftDomain))
            )
            .foregroundStyle(candlestickColor(for: bar).opacity(0.82))
            .lineStyle(StrokeStyle(lineWidth: 1, lineCap: .round))

            RectangleMark(
                x: .value(AppLocalization.string("日期"), bar.date),
                yStart: .value(AppLocalization.string("实体低"), normalized(bar.bodyLow, in: leftDomain)),
                yEnd: .value(AppLocalization.string("实体高"), normalized(bar.bodyHigh, in: leftDomain)),
                width: .fixed(compactCandlestickBodyWidth)
            )
            .foregroundStyle(candlestickColor(for: bar).opacity(0.92))
        }
    }

    @ChartContentBuilder
    private var rightSeriesMarksNormalized: some ChartContent {
        ForEach(displayPoints) { point in
            LineMark(
                x: .value(AppLocalization.string("日期"), point.date),
                y: .value(descriptor.rightTitle, normalized(point.rightValue, in: rightDomain)),
                series: .value(AppLocalization.string("系列"), descriptor.rightTitle)
            )
            .foregroundStyle(descriptor.rightColor)
            .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round, dash: [6, 5]))
            .interpolationMethod(.linear)
        }
    }

    @ChartContentBuilder
    private var leftOnlySeriesMarks: some ChartContent {
        if canShowCandlestickChart {
            candlestickSeriesMarks
        } else {
            ForEach(displayLeftOnlyPoints) { point in
                LineMark(
                    x: .value(AppLocalization.string("日期"), point.date),
                    y: .value(descriptor.leftTitle, normalized(point.value, in: leftDomain)),
                    series: .value(AppLocalization.string("系列"), descriptor.leftTitle)
                )
                .foregroundStyle(descriptor.leftColor)
                .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.linear)
            }
        }
    }

    @ChartContentBuilder
    private var latestPointMarksNormalized: some ChartContent {
        if canShowCandlestickChart, let selectedCandlestick {
            PointMark(
                x: .value(AppLocalization.string("日期"), selectedCandlestick.date),
                y: .value(descriptor.leftTitle, normalized(selectedCandlestick.close, in: leftDomain))
            )
            .foregroundStyle(descriptor.leftColor)
            .symbolSize(34)
        } else if let selectedDualPoint {
            PointMark(
                x: .value(AppLocalization.string("日期"), selectedDualPoint.date),
                y: .value(descriptor.leftTitle, normalized(selectedDualPoint.leftValue, in: leftDomain))
            )
            .foregroundStyle(descriptor.leftColor)
            .symbolSize(46)
        }

        if descriptor.showsComparisonLine, let selectedDualPoint {
            PointMark(
                x: .value(AppLocalization.string("日期"), selectedDualPoint.date),
                y: .value(descriptor.rightTitle, normalized(selectedDualPoint.rightValue, in: rightDomain))
            )
            .foregroundStyle(descriptor.rightColor)
            .symbolSize(40)
        }
    }

    @ChartContentBuilder
    private var leftOnlyLatestPointMarks: some ChartContent {
        if canShowCandlestickChart, let selectedCandlestick {
            PointMark(
                x: .value(AppLocalization.string("日期"), selectedCandlestick.date),
                y: .value(descriptor.leftTitle, normalized(selectedCandlestick.close, in: leftDomain))
            )
            .foregroundStyle(descriptor.leftColor)
            .symbolSize(34)
        } else if let selectedLeftOnlyPoint {
            PointMark(
                x: .value(AppLocalization.string("日期"), selectedLeftOnlyPoint.date),
                y: .value(descriptor.leftTitle, normalized(selectedLeftOnlyPoint.value, in: leftDomain))
            )
            .foregroundStyle(descriptor.leftColor)
            .symbolSize(46)
        }
    }

    private var bottomAxisMarks: some AxisContent {
        AxisMarks(values: bottomAxisDates) { _ in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.7, dash: [2, 4]))
                .foregroundStyle(AssetTheme.border.opacity(0.28))
            AxisTick(stroke: StrokeStyle(lineWidth: 0.8))
                .foregroundStyle(AssetTheme.border.opacity(0.5))
        }
    }

    private var chartBackground: some View {
        RoundedRectangle(cornerRadius: chartCornerRadius, style: .continuous)
            .fill(AssetTheme.surface.opacity(0.46))
    }

    private var selectedAxisDateLabel: String {
        if canShowCandlestickChart, let selectedCandlestick {
            return selectedCandlestick.date.chartAxisDateString
        }
        if let selectedDualPoint {
            return selectedDualPoint.date.chartAxisDateString
        }
        if let selectedLeftOnlyPoint {
            return selectedLeftOnlyPoint.date.chartAxisDateString
        }
        return dateRangeLabel
    }

    private func normalized(_ value: Double, in domain: ClosedRange<Double>) -> Double {
        let span = domain.upperBound - domain.lowerBound
        guard span.isFinite, span > 0 else { return 0.5 }
        return (value - domain.lowerBound) / span
    }

    private var compactCandlestickBodyWidth: CGFloat {
        switch displayCandlesticks.count {
        case 0...48:
            return 5
        case 49...96:
            return 3.4
        default:
            return 2.4
        }
    }

    private func candlestickColor(for point: TimeMachineCandlestickPoint) -> Color {
        point.isRising ? AssetTheme.positive : AssetTheme.negative
    }

    private var selectedLeftLabel: String {
        if canShowCandlestickChart, let selectedCandlestick {
            return descriptor.leftAxisStyle.compactLabel(for: selectedCandlestick.close)
        }
        if let selectedDualPoint {
            return descriptor.leftAxisStyle.compactLabel(for: selectedDualPoint.leftValue)
        }
        if let selectedLeftOnlyPoint {
            return descriptor.leftAxisStyle.compactLabel(for: selectedLeftOnlyPoint.value)
        }
        return descriptor.leftLatestLabel
    }

    private var selectedRightLabel: String {
        if let selectedDualPoint {
            return descriptor.rightAxisStyle.compactLabel(for: selectedDualPoint.rightValue)
        }
        return descriptor.rightLatestLabel
    }

    private func axisTickValues(for domain: ClosedRange<Double>) -> [Double] {
        let step = (domain.upperBound - domain.lowerBound) / 2
        guard step.isFinite, step > 0 else { return [domain.lowerBound] }
        return [domain.lowerBound, domain.lowerBound + step, domain.upperBound]
    }
}

struct TimeMachineHistoryDrilldownSheet: View {
    let descriptor: TimeMachineHistoryDrilldown
    @Environment(\.dismiss) private var dismiss
    @State private var selectedRange: TimeMachineRange = .all
    @State private var selectedDate: Date?

    private var filteredPoints: [TimeMachineSingleAxisPoint] {
        selectedRange.filter(descriptor.points)
    }

    private var displayPoints: [TimeMachineSingleAxisPoint] {
        evenlySampledItems(filteredPoints, maxCount: 220)
    }

    private var filteredCandlesticks: [TimeMachineCandlestickPoint] {
        selectedRange.filter(descriptor.candlesticks)
    }

    private var displayCandlesticks: [TimeMachineCandlestickPoint] {
        evenlySampledItems(filteredCandlesticks, maxCount: 180)
    }

    private var canShowCandlestickChart: Bool {
        displayCandlesticks.count >= 2
    }

    private var latestCandlestick: TimeMachineCandlestickPoint? {
        filteredCandlesticks.last ?? descriptor.candlesticks.last
    }

    private var selectedCandlestick: TimeMachineCandlestickPoint? {
        guard let selectedDate else { return latestCandlestick }
        return nearestChartPoint(displayCandlesticks, to: selectedDate, date: \.date) ?? latestCandlestick
    }

    private var latestPoint: TimeMachineSingleAxisPoint? {
        filteredPoints.last ?? descriptor.points.last
    }

    private var selectedPoint: TimeMachineSingleAxisPoint? {
        guard let latestPoint else { return nil }
        guard let selectedDate else { return latestPoint }
        return nearestChartPoint(displayPoints, to: selectedDate, date: \.date) ?? latestPoint
    }

    private var valueDomain: ClosedRange<Double> {
        if canShowCandlestickChart {
            return paddedDomain(values: displayCandlesticks.flatMap { [$0.low, $0.high] })
        }
        return paddedDomain(values: displayPoints.map(\.value))
    }

    private var selectedDisplayValue: Double? {
        if canShowCandlestickChart {
            return selectedCandlestick?.close
        }
        return selectedPoint?.value
    }

    private var selectedDisplayDate: Date? {
        if canShowCandlestickChart {
            return selectedCandlestick?.date
        }
        return selectedPoint?.date
    }

    private var chartModeLabel: String {
        canShowCandlestickChart ? AppLocalization.string("历史 K 线") : AppLocalization.string("历史走势")
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(AppLocalization.string(descriptor.title))
                                    .font(.title3.weight(.bold))
                                    .foregroundStyle(AssetTheme.textPrimary)

                                Text(chartModeLabel)
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(AssetTheme.goldSoft)

                                if let subtitle = descriptor.subtitle {
                                    Text(AppLocalization.string(subtitle))
                                        .font(.caption)
                                        .foregroundStyle(AssetTheme.textSecondary)
                                }
                            }

                            Spacer(minLength: 12)

                            if let selectedDisplayValue, let selectedDisplayDate {
                                VStack(alignment: .trailing, spacing: 4) {
                                    Text(descriptor.axisStyle.compactLabel(for: selectedDisplayValue))
                                        .font(.title3.weight(.bold))
                                        .foregroundStyle(descriptor.color)
                                    Text(selectedDisplayDate.chartAxisDateString)
                                        .font(.caption)
                                        .foregroundStyle(AssetTheme.textSecondary)
                                }
                            }
                        }

                        TimeMachineRangeSelector(selectedRange: $selectedRange)

                        if displayPoints.count >= 2 {
                            historyChart
                        } else if let latestPoint {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(descriptor.axisStyle.compactLabel(for: latestPoint.value))
                                    .font(.title3.weight(.bold))
                                    .foregroundStyle(descriptor.color)
                                Text(latestPoint.date.chartAxisDateString)
                                    .font(.caption)
                                    .foregroundStyle(AssetTheme.textSecondary)
                            }
                            .padding(18)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(AssetTheme.overlayFaint, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 24, style: .continuous)
                                    .stroke(AssetTheme.border.opacity(0.75), lineWidth: 1)
                            )
                        } else {
                            Text(AppLocalization.string("暂无历史数据"))
                                .font(.subheadline)
                                .foregroundStyle(AssetTheme.textSecondary)
                                .frame(maxWidth: .infinity, minHeight: 180, alignment: .center)
                        }

                        Text(selectedDate == nil ? dateRangeLabel : (selectedDisplayDate?.chartAxisDateString ?? dateRangeLabel))
                            .font(AppTypography.meta)
                            .foregroundStyle(AssetTheme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle(AppLocalization.string("指数走势"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalization.string("关闭")) {
                        dismiss()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var historyChart: some View {
        if canShowCandlestickChart {
            candlestickHistoryChart
        } else {
            lineHistoryChart
        }
    }

    private var candlestickHistoryChart: some View {
        Chart {
            ForEach(displayCandlesticks) { bar in
                RuleMark(
                    x: .value(AppLocalization.string("日期"), bar.date),
                    yStart: .value(AppLocalization.string("最低"), bar.low),
                    yEnd: .value(AppLocalization.string("最高"), bar.high)
                )
                .foregroundStyle(candlestickColor(for: bar).opacity(0.82))
                .lineStyle(StrokeStyle(lineWidth: 1, lineCap: .round))

                RectangleMark(
                    x: .value(AppLocalization.string("日期"), bar.date),
                    yStart: .value(AppLocalization.string("实体低"), bar.bodyLow),
                    yEnd: .value(AppLocalization.string("实体高"), bar.bodyHigh),
                    width: .fixed(candlestickBodyWidth)
                )
                .foregroundStyle(candlestickColor(for: bar).opacity(0.92))
            }

            if let selectedCandlestick {
                PointMark(
                    x: .value(AppLocalization.string("日期"), selectedCandlestick.date),
                    y: .value(descriptor.title, selectedCandlestick.close)
                )
                .foregroundStyle(descriptor.color)
                .symbolSize(34)
            }

            if selectedDate != nil, let selectedCandlestick {
                RuleMark(x: .value(AppLocalization.string("选中日期"), selectedCandlestick.date))
                    .foregroundStyle(AssetTheme.textSecondary.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
        }
        .frame(height: 280)
        .chartYScale(domain: valueDomain)
        .chartXAxis { historyXAxisMarks(dates: displayCandlesticks.map(\.date)) }
        .chartYAxis { historyYAxisMarks }
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            TimeMachineDragOverlay(proxy: proxy) { date in
                selectedDate = date
            } onEnded: {
                selectedDate = nil
            }
        }
        .padding(18)
        .background(AssetTheme.overlayFaint, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(AssetTheme.border.opacity(0.75), lineWidth: 1)
        )
    }

    private var lineHistoryChart: some View {
        Chart {
            ForEach(displayPoints) { point in
                LineMark(
                    x: .value(AppLocalization.string("日期"), point.date),
                    y: .value(descriptor.title, point.value)
                )
                .foregroundStyle(descriptor.color)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.linear)
            }

            if let selectedPoint {
                PointMark(
                    x: .value(AppLocalization.string("日期"), selectedPoint.date),
                    y: .value(descriptor.title, selectedPoint.value)
                )
                .foregroundStyle(descriptor.color)
                .symbolSize(42)
            }

            if selectedDate != nil, let selectedPoint {
                RuleMark(x: .value(AppLocalization.string("选中日期"), selectedPoint.date))
                    .foregroundStyle(AssetTheme.textSecondary.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
        }
        .frame(height: 280)
        .chartYScale(domain: valueDomain)
        .chartXAxis { historyXAxisMarks(dates: displayPoints.map(\.date)) }
        .chartYAxis { historyYAxisMarks }
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            TimeMachineDragOverlay(proxy: proxy) { date in
                selectedDate = date
            } onEnded: {
                selectedDate = nil
            }
        }
        .padding(18)
        .background(AssetTheme.overlayFaint, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(AssetTheme.border.opacity(0.75), lineWidth: 1)
        )
    }

    private func historyXAxisMarks(dates: [Date]) -> some AxisContent {
        let axisDates = chartAxisDates(dates)
        return AxisMarks(values: axisDates) { value in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                .foregroundStyle(AssetTheme.chartGrid)
            AxisTick().foregroundStyle(AssetTheme.chartTick)
            AxisValueLabel(anchor: .top, verticalSpacing: 8) {
                if let date = value.as(Date.self) {
                    TimeMachineAxisDateLabel(date: date, position: axisLabelPosition(for: date, in: axisDates))
                }
            }
        }
    }

    private var historyYAxisMarks: some AxisContent {
        AxisMarks(values: axisTickValues(for: valueDomain)) { value in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                .foregroundStyle(AssetTheme.chartGrid)
            AxisValueLabel {
                if let y = value.as(Double.self) {
                    Text(descriptor.axisStyle.compactLabel(for: y))
                        .font(.caption2)
                        .foregroundStyle(AssetTheme.textSecondary)
                }
            }
        }
    }

    private var candlestickBodyWidth: CGFloat {
        switch displayCandlesticks.count {
        case 0...45:
            return 7
        case 46...90:
            return 5
        default:
            return 3
        }
    }

    private func candlestickColor(for point: TimeMachineCandlestickPoint) -> Color {
        point.isRising ? AssetTheme.positive : AssetTheme.negative
    }

    private var dateRangeLabel: String {
        if canShowCandlestickChart {
            guard let first = filteredCandlesticks.first?.date ?? descriptor.candlesticks.first?.date,
                  let last = filteredCandlesticks.last?.date ?? descriptor.candlesticks.last?.date else {
                return AppLocalization.string("暂无范围")
            }
            return "\(first.chartAxisDateString) - \(last.chartAxisDateString)"
        }
        guard let first = filteredPoints.first?.date ?? descriptor.points.first?.date,
              let last = filteredPoints.last?.date ?? descriptor.points.last?.date else {
            return AppLocalization.string("暂无范围")
        }
        return "\(first.chartAxisDateString) - \(last.chartAxisDateString)"
    }

    private func axisLabelPosition(for date: Date, in axisDates: [Date]) -> TimeMachineAxisDateLabel.Position {
        guard let first = axisDates.first, let last = axisDates.last else { return .middle }
        if Calendar.current.isDate(date, inSameDayAs: first) {
            return .leading
        }
        if Calendar.current.isDate(date, inSameDayAs: last) {
            return .trailing
        }
        return .middle
    }

    private func axisTickValues(for domain: ClosedRange<Double>) -> [Double] {
        let step = (domain.upperBound - domain.lowerBound) / 2
        guard step.isFinite, step > 0 else { return [domain.lowerBound] }
        return [domain.lowerBound, domain.lowerBound + step, domain.upperBound]
    }

    private func paddedDomain(values: [Double]) -> ClosedRange<Double> {
        let filtered = values.filter { $0.isFinite }
        guard let minValue = filtered.min(), let maxValue = filtered.max() else {
            return 0...1
        }
        if abs(maxValue - minValue) < .ulpOfOne {
            let padding = max(abs(maxValue) * 0.08, 1)
            return (minValue - padding)...(maxValue + padding)
        }
        let padding = max((maxValue - minValue) * 0.12, abs(maxValue) * 0.02)
        return (minValue - padding)...(maxValue + padding)
    }
}

struct TimeMachineDragOverlay: View {
    let proxy: ChartProxy
    let onChanged: (Date) -> Void
    let onEnded: () -> Void

    var body: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard let plotFrame = proxy.plotFrame else { return }
                            let frame = geometry[plotFrame]
                            let locationX = min(max(value.location.x - frame.origin.x, 0), frame.size.width)
                            if let date: Date = proxy.value(atX: locationX) {
                                onChanged(date)
                            }
                        }
                        .onEnded { _ in
                            onEnded()
                        }
                )
        }
    }
}

struct TimeMachineCompactLegendMetric: View {
    let title: String
    let value: String
    let color: Color
    let dashed: Bool

    var body: some View {
        HStack(spacing: 4.5) {
            legendMark

            Text(AppLocalization.string(title))
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .foregroundStyle(AssetTheme.textSecondary.opacity(0.84))
                .lineLimit(1)

            Text(value)
                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.66)
        }
        .padding(.vertical, 4)
        .frame(minWidth: 68, alignment: .leading)
    }

    @ViewBuilder
    private var legendMark: some View {
        if dashed {
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { _ in
                    Capsule()
                        .fill(color)
                        .frame(width: 3.2, height: 2.4)
                }
            }
            .frame(width: 12, alignment: .leading)
        } else {
            Capsule()
                .fill(color)
                .frame(width: 12, height: 2.4)
        }
    }
}

struct TimeMachineLegendMetric: View {
    let title: String
    let value: String
    let color: Color
    let dashed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                legendMark

                Text(AppLocalization.string(title))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(AssetTheme.textSecondary)
            }

            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private var legendMark: some View {
        if dashed {
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in
                    Capsule()
                        .fill(color)
                        .frame(width: 4, height: 2.5)
                }
            }
            .frame(width: 14, alignment: .leading)
        } else {
            Capsule()
                .fill(color)
                .frame(width: 14, height: 2.5)
        }
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
                .font(.system(size: 8.8, weight: .semibold, design: .rounded))
                .foregroundStyle(color.opacity(0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            Spacer(minLength: 10)
            Text(middleLabel)
                .font(.system(size: 8.8, weight: .medium, design: .rounded))
                .foregroundStyle(AssetTheme.textSecondary.opacity(0.84))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            Spacer(minLength: 10)
            Text(bottomLabel)
                .font(.system(size: 8.8, weight: .semibold, design: .rounded))
                .foregroundStyle(color.opacity(0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }
}

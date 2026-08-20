import SwiftUI
import Charts
import UIKit

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

struct DashboardAssetHero: View {
    let totalAmount: Double
    let recentPoints: [TimeMachineTrendPoint]
    let thirtyDayChange: Double?
    @Binding var amountsVisible: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("\(AppLocalization.string("总资产")) (CNY)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AssetTheme.textSecondary)

                Button {
                    amountsVisible.toggle()
                } label: {
                    Image(systemName: amountsVisible ? "eye" : "eye.slash")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AssetTheme.textSecondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AppLocalization.string(amountsVisible ? "隐藏资产金额" : "显示资产金额"))

                Spacer(minLength: 0)
            }

            HStack(alignment: .bottom, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(amountsVisible ? totalAmount.currencyString() : "••••••")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(AssetTheme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.64)

                    HStack(spacing: 8) {
                        Text(AppLocalization.string("近30日"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(AssetTheme.textSecondary)

                        Text(changeText)
                            .font(.system(size: 13, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(changeColor)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if recentPoints.count >= 2 {
                    recentTrendChart
                        .frame(width: 176, height: 78)
                }
            }
        }
    }

    private var recentTrendChart: some View {
        Chart {
            ForEach(recentPoints) { point in
                AreaMark(
                    x: .value(AppLocalization.string("日期"), point.date),
                    yStart: .value(AppLocalization.string("总资产"), recentValueDomain.lowerBound),
                    yEnd: .value(AppLocalization.string("总资产"), point.mainAssets)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(
                    LinearGradient(
                        colors: [AssetTheme.gold.opacity(0.24), AssetTheme.gold.opacity(0.015)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                LineMark(
                    x: .value(AppLocalization.string("日期"), point.date),
                    y: .value(AppLocalization.string("总资产"), point.mainAssets)
                )
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .foregroundStyle(AssetTheme.goldSoft)
            }

            if let latest = recentPoints.last {
                PointMark(
                    x: .value(AppLocalization.string("日期"), latest.date),
                    y: .value(AppLocalization.string("总资产"), latest.mainAssets)
                )
                .foregroundStyle(AssetTheme.goldSoft)
                .symbolSize(28)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: recentValueDomain)
        .chartLegend(.hidden)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var changeText: String {
        guard let thirtyDayChange, thirtyDayChange.isFinite else { return "--" }
        return thirtyDayChange.formatted(
            .percent
                .sign(strategy: .always())
                .precision(.fractionLength(2))
        )
    }

    private var changeColor: Color {
        guard let thirtyDayChange else { return AssetTheme.textSecondary }
        return thirtyDayChange >= 0 ? AssetTheme.goldSoft : AssetTheme.negative
    }

    private var recentValueDomain: ClosedRange<Double> {
        ChartLayoutSupport.paddedValueDomain(values: recentPoints.map(\.mainAssets))
    }
}

struct DashboardAllocationChart: View {
    let slices: [DashboardAllocationSlice]
    let totalAmount: Double
    let amountsVisible: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 20) {
                ZStack {
                    Chart(slices) { slice in
                        SectorMark(
                            angle: .value(AppLocalization.string("占比"), slice.amount),
                            innerRadius: .ratio(0.69),
                            angularInset: 1.25
                        )
                        .foregroundStyle(slice.color)
                    }
                    .chartLegend(.hidden)
                    .allowsHitTesting(false)
                    .accessibilityHidden(!amountsVisible)

                    VStack(spacing: 4) {
                        Text(AppLocalization.string("总资产"))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(AssetTheme.textSecondary)

                        Text(amountsVisible ? totalAmount.dashboardCompactCurrencyString() : "••••")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(AssetTheme.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
                .frame(width: 140, height: 140)

                VStack(spacing: 9) {
                    ForEach(slices) { slice in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(slice.color)
                                .frame(width: 7, height: 7)

                            Text(AppLocalization.string(slice.title))
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(AssetTheme.textPrimary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Text(amountsVisible ? slice.amount.dashboardCompactCurrencyString() : "••••")
                                .font(.system(size: 10.5, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(AssetTheme.textPrimary)
                                .lineLimit(1)

                            Text(percentageText(for: slice))
                                .font(.system(size: 10.5, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(AssetTheme.textSecondary)
                                .frame(width: 35, alignment: .trailing)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func percentageText(for slice: DashboardAllocationSlice) -> String {
        guard totalAmount > 0 else { return "0%" }
        return (slice.amount / totalAmount).formatted(.percent.precision(.fractionLength(0)))
    }

}

private extension Double {
    func dashboardCompactCurrencyString() -> String {
        let formatter = AppFormatterCache.compactNumberFormatter(maxFractionDigits: 1)
        let absoluteValue = abs(self)
        let sign = self < 0 ? "-" : ""
        let isChinese = AppLocalization.currentLocale.identifier.lowercased().hasPrefix("zh")

        func value(_ divisor: Double, suffix: String) -> String {
            let number = formatter.string(from: NSNumber(value: absoluteValue / divisor)) ?? "0"
            return "\(sign)¥\(number)\(suffix)"
        }

        if isChinese {
            if absoluteValue >= 100_000_000 {
                return value(100_000_000, suffix: AppLocalization.string("亿"))
            }
            if absoluteValue >= 10_000 {
                return value(10_000, suffix: AppLocalization.string("万"))
            }
        } else {
            if absoluteValue >= 1_000_000_000 {
                return value(1_000_000_000, suffix: "B")
            }
            if absoluteValue >= 1_000_000 {
                return value(1_000_000, suffix: "M")
            }
            if absoluteValue >= 1_000 {
                return value(1_000, suffix: "K")
            }
        }

        let number = formatter.string(from: NSNumber(value: self)) ?? "0"
        return "¥\(number)"
    }
}

nonisolated struct FinancialFreedomProjection {
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
    let yearToDateAnnualSurplus: Double?
    let yearToDateMonthlyAverageSurplus: Double?
    let yearToDateStartNetAssets: Double?
    let yearToDateEndNetAssets: Double?
    let yearToDateStartDate: Date?
    let yearToDateEndDate: Date?
    let yearToDateMonthsCounted: Int?
    let projectionPoints: [FinancialFreedomProjectionPoint]
}

nonisolated struct FinancialFreedomProjectionPoint: Identifiable {
    let monthOffset: Int
    let date: Date
    let projectedPassiveIncome: Double
    let projectedMonthlyExpense: Double
    let projectedTotalAssets: Double

    var id: Int { monthOffset }
}

nonisolated enum FreedomChartHorizon: Int, CaseIterable, Identifiable {
    case three = 3
    case five = 5
    case ten = 10
    case twenty = 20
    case thirty = 30
    case fifty = 50
    case seventyFive = 75
    case hundred = 100
    case hundredFifty = 150
    case twoHundred = 200

    var id: Int { rawValue }

    var months: Int { rawValue * 12 }

    @MainActor
    var menuTitle: String {
        AppLocalization.format("未来 %d 年", rawValue)
    }

    static let baseMaximum = FreedomChartHorizon.twenty
    static let maximum = FreedomChartHorizon.twoHundred

    static func recommended(for status: FinancialFreedomProjection.Status) -> FreedomChartHorizon {
        let requiredMonths: Int
        switch status {
        case .alreadyFree:
            requiredMonths = FreedomChartHorizon.five.months
        case .projected(let months):
            requiredMonths = max(FreedomChartHorizon.ten.months, months * 2)
        case .unreachable:
            requiredMonths = FreedomChartHorizon.five.months
        }

        return allCases.first(where: { $0.months >= requiredMonths }) ?? maximum
    }

    static func available(for status: FinancialFreedomProjection.Status) -> [FreedomChartHorizon] {
        let upperBound = max(baseMaximum.rawValue, recommended(for: status).rawValue)
        return allCases.filter { $0.rawValue <= upperBound }
    }
}

nonisolated struct FinancialFreedomHistoryPoint: Sendable {
    let date: Date
    let mainAssets: Double
    let netAssets: Double
    let liabilities: Double
}

nonisolated enum FinancialFreedomEstimator {
    private static let maxProjectionMonths = 100 * 12
    private static let fallbackChartProjectionMonths = FreedomChartHorizon.baseMaximum.months

    static func estimate(
        points: [FinancialFreedomHistoryPoint],
        monthlySalary: Double,
        annualReturnRate: Double,
        monthlyExpense: Double,
        annualInflationRate: Double,
        usesCurrentAssets: Bool = true
    ) -> FinancialFreedomProjection? {
        guard let currentPoint = points.last,
              currentPoint.netAssets.isFinite,
              currentPoint.mainAssets.isFinite else { return nil }
        let currentNetAssets = usesCurrentAssets ? currentPoint.netAssets : 0
        let currentTotalAssets = usesCurrentAssets ? currentPoint.mainAssets : 0
        let currentLiabilities = usesCurrentAssets ? max(currentPoint.liabilities, 0) : 0
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
        let yearToDateSurplus = yearToDateSurplusMetrics(from: points)

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
            yearToDateAnnualSurplus: yearToDateSurplus?.annual,
            yearToDateMonthlyAverageSurplus: yearToDateSurplus?.monthlyAverage,
            yearToDateStartNetAssets: yearToDateSurplus?.startNetAssets,
            yearToDateEndNetAssets: yearToDateSurplus?.endNetAssets,
            yearToDateStartDate: yearToDateSurplus?.startDate,
            yearToDateEndDate: yearToDateSurplus?.endDate,
            yearToDateMonthsCounted: yearToDateSurplus?.monthsCounted,
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
        _ = monthlySalary
        _ = monthlyReturnRate
        switch status {
        case .projected:
            return max(
                fallbackChartProjectionMonths,
                FreedomChartHorizon.recommended(for: status).months
            )
        case .alreadyFree, .unreachable:
            return fallbackChartProjectionMonths
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

    private struct YearToDateSurplusMetrics {
        let annual: Double
        let monthlyAverage: Double
        let startNetAssets: Double
        let endNetAssets: Double
        let startDate: Date
        let endDate: Date
        let monthsCounted: Int
    }

    private static func yearToDateSurplusMetrics(
        from points: [FinancialFreedomHistoryPoint],
        calendar: Calendar = .current
    ) -> YearToDateSurplusMetrics? {
        guard !points.isEmpty else { return nil }

        let sortedPoints = points.sorted { $0.date < $1.date }
        guard let yearStart = calendar.date(from: calendar.dateComponents([.year], from: Date())) else { return nil }

        let yearPoints = sortedPoints.filter { $0.date >= yearStart }
        guard let lastPoint = yearPoints.last else { return nil }

        let baselinePoint = sortedPoints.last(where: { $0.date < yearStart }) ?? yearPoints.first ?? lastPoint
        let annualSurplus = lastPoint.netAssets - baselinePoint.netAssets

        let monthStarts = Set(
            yearPoints.compactMap { point in
                calendar.dateInterval(of: .month, for: point.date)?.start
            }
        )
        let monthsCounted = max(monthStarts.count, 1)
        let monthlyAverage = annualSurplus / Double(monthsCounted)

        return YearToDateSurplusMetrics(
            annual: annualSurplus,
            monthlyAverage: monthlyAverage,
            startNetAssets: baselinePoint.netAssets,
            endNetAssets: lastPoint.netAssets,
            startDate: baselinePoint.date,
            endDate: lastPoint.date,
            monthsCounted: monthsCounted
        )
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
    @Binding var usesCurrentAssets: Bool
    @Binding var keyboardDismissSignal: Int
    let amountsVisible: Bool

    @FocusState private var focusedField: FreedomParameterField?
    @State private var showsAlgorithmExplanation = false
    @State private var showsYearToDateSurplusDetails = false
    @State private var monthlyExpenseText = ""
    @State private var inflationRateText = ""
    @State private var monthlySalaryText = ""
    @State private var annualReturnRateText = ""

    private enum FreedomParameterField: Hashable {
        case monthlyExpense
        case monthlySalary
        case inflationRate
        case annualReturnRate
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Text(AppLocalization.string("财务自由进度"))
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(AssetTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Button {
                    showsAlgorithmExplanation = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AssetTheme.textSecondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AppLocalization.string("查看财富自由算法说明"))

                Spacer(minLength: 8)

                Text(statusText)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .padding(.horizontal, 11)
                    .frame(height: 30)
                    .background(statusColor.opacity(0.1), in: Capsule())
            }
            .padding(.top, 20)
            .padding(.bottom, 14)

            HStack(alignment: .center, spacing: 12) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(AssetTheme.border.opacity(0.42))

                        Capsule()
                            .fill(AssetTheme.goldSoft)
                            .frame(width: max(geometry.size.width * CGFloat(freedomProgress), freedomProgress > 0 ? 5 : 0))
                    }
                }
                .frame(height: 6)

                Text(freedomProgress.formatted(.percent.precision(.fractionLength(0))))
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(AssetTheme.goldSoft)
                    .frame(minWidth: 44, alignment: .trailing)
            }
            .padding(.bottom, 20)

            HStack(alignment: .top, spacing: 0) {
                parameterInputField(
                    title: AppLocalization.string("月开销"),
                    systemImage: "wallet.bifold",
                    text: $monthlyExpenseText,
                    field: .monthlyExpense
                )
                parameterDivider
                parameterInputField(
                    title: AppLocalization.string("月薪"),
                    systemImage: "banknote",
                    text: $monthlySalaryText,
                    field: .monthlySalary
                )
                parameterDivider
                parameterInputField(
                    title: AppLocalization.string("通胀率"),
                    systemImage: "chart.line.uptrend.xyaxis",
                    text: $inflationRateText,
                    field: .inflationRate,
                    suffix: "%"
                )
                parameterDivider
                parameterInputField(
                    title: AppLocalization.string("年化收益"),
                    systemImage: "target",
                    text: $annualReturnRateText,
                    field: .annualReturnRate,
                    suffix: "%"
                )
            }
            .padding(.bottom, 18)

            Button {
                dismissKeyboard()
                withAnimation(.easeInOut(duration: 0.18)) {
                    usesCurrentAssets.toggle()
                }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: usesCurrentAssets ? "checkmark.square.fill" : "square")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(usesCurrentAssets ? AssetTheme.goldSoft : AssetTheme.textSecondary)

                    Text(AppLocalization.string("根据当前资产计算"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AssetTheme.textSecondary)

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 14)
            .accessibilityValue(AppLocalization.string(usesCurrentAssets ? "已开启" : "已关闭"))

            Rectangle()
                .fill(AssetTheme.border.opacity(0.5))
                .frame(height: 1)

            yearToDateSurplusRow
                .padding(.vertical, 14)

            Rectangle()
                .fill(AssetTheme.border.opacity(0.5))
                .frame(height: 1)

            if let projection, !projection.projectionPoints.isEmpty {
                DashboardFreedomProjectionChart(
                    projection: projection,
                    amountsVisible: amountsVisible
                )
                .id("dashboard-freedom-projection")
                .padding(.top, 22)
                .contentShape(Rectangle())
                .onTapGesture {
                    dismissKeyboard()
                }
            }
        }
        .onAppear {
            syncParameterTexts()
        }
        .onChange(of: focusedField) { oldValue, _ in
            if let oldValue {
                commitField(oldValue)
            }
        }
        .onChange(of: keyboardDismissSignal) { _, _ in
            dismissKeyboard()
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(AppLocalization.string("完成")) {
                    dismissKeyboard()
                }
                .font(AppTypography.rowTitle)
                .foregroundStyle(AssetTheme.gold)
            }
        }
        .sheet(isPresented: $showsAlgorithmExplanation) {
            DashboardFreedomAlgorithmSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showsYearToDateSurplusDetails) {
            DashboardYearToDateSurplusDetailSheet(
                projection: projection,
                amountsVisible: amountsVisible
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        #if DEBUG
        .task {
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("-openFreedomAlgorithm") {
                showsAlgorithmExplanation = true
            } else if arguments.contains("-openFreedomSurplusDetails") {
                showsYearToDateSurplusDetails = true
            }
        }
        #endif
    }

    private func parameterInputField(
        title: String,
        systemImage: String,
        text: Binding<String>,
        field: FreedomParameterField,
        suffix: String? = nil
    ) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(AssetTheme.textSecondary)
                .frame(height: 24)

            Text(title)
                .font(.system(size: 10.5, weight: .medium, design: .default))
                .foregroundStyle(AssetTheme.textSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.74)
                .frame(height: 26, alignment: .top)
                .contentShape(Rectangle())
                .onTapGesture {
                    dismissKeyboard()
                }

            HStack(spacing: 3) {
                TextField(AppLocalization.string("输入"), text: text)
                    .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(AssetTheme.textPrimary)
                    .multilineTextAlignment(.center)
                    .keyboardType(.decimalPad)
                    .focused($focusedField, equals: field)
                    .submitLabel(.done)
                    .frame(maxWidth: 62)
                    .onSubmit {
                        commitField(field)
                        focusedField = nil
                    }

                if let suffix {
                    Text(suffix)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AssetTheme.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            if focusedField == field {
                Capsule()
                    .fill(AssetTheme.gold)
                    .frame(width: 34, height: 2)
                    .offset(y: 7)
            }
        }
    }

    private var parameterDivider: some View {
        Rectangle()
            .fill(AssetTheme.border.opacity(0.42))
            .frame(width: 1, height: 72)
            .padding(.top, 18)
    }

    private func dismissKeyboard() {
        if let field = focusedField {
            commitField(field)
            focusedField = nil
        }
        dismissActiveKeyboard()
    }

    private func syncParameterTexts() {
        monthlyExpenseText = formatCurrencyInput(monthlyExpense)
        monthlySalaryText = formatCurrencyInput(monthlySalary)
        inflationRateText = formatPercentInput(inflationRate)
        annualReturnRateText = formatPercentInput(annualReturnRate)
    }

    private func formatCurrencyInput(_ value: Double) -> String {
        String(Int(value.rounded()))
    }

    private func formatPercentInput(_ value: Double) -> String {
        String(format: "%.1f", value * 100)
    }

    private func commitField(_ field: FreedomParameterField) {
        switch field {
        case .monthlyExpense:
            applyMonthlyExpenseText()
        case .monthlySalary:
            applyMonthlySalaryText()
        case .inflationRate:
            applyInflationRateText()
        case .annualReturnRate:
            applyAnnualReturnRateText()
        }
        syncParameterTexts()
    }

    private func applyMonthlyExpenseText() {
        let sanitized = monthlyExpenseText
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let value = Double(sanitized), value.isFinite else { return }
        monthlyExpense = max(1000, value)
    }

    private func applyInflationRateText() {
        let sanitized = inflationRateText
            .replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let percent = Double(sanitized), percent.isFinite else { return }
        inflationRate = min(max(percent / 100, 0), 0.2)
    }

    private func applyMonthlySalaryText() {
        let sanitized = monthlySalaryText
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let value = Double(sanitized), value.isFinite else { return }
        monthlySalary = max(0, value)
    }

    private func applyAnnualReturnRateText() {
        let sanitized = annualReturnRateText
            .replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let percent = Double(sanitized), percent.isFinite else { return }
        annualReturnRate = min(max(percent / 100, -0.99), 1.0)
    }

    private var freedomProgress: Double {
        guard let projection,
              projection.currentMonthlyExpense.isFinite,
              projection.currentMonthlyExpense > 0,
              projection.currentPassiveIncome.isFinite else {
            return 0
        }
        return min(max(projection.currentPassiveIncome / projection.currentMonthlyExpense, 0), 1)
    }

    private var yearToDateSurplusRow: some View {
        Button {
            dismissKeyboard()
            showsYearToDateSurplusDetails = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AssetTheme.textSecondary)
                    .frame(width: 24)

                Text(AppLocalization.string("年初至今结余"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AssetTheme.textPrimary)

                Spacer(minLength: 8)

                Text(yearToDateSurplusText)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(yearToDateSurplusColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(AssetTheme.textSecondary)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityHint(AppLocalization.string("查看结余计算详情"))
    }

    private var yearToDateSurplusText: String {
        guard amountsVisible else { return "••••••" }
        return projection?.yearToDateAnnualSurplus?.currencyString() ?? "--"
    }

    private var yearToDateSurplusColor: Color {
        guard amountsVisible, let value = projection?.yearToDateAnnualSurplus else {
            return AssetTheme.textSecondary
        }
        return value >= 0 ? AssetTheme.goldSoft : AssetTheme.negative
    }

    private var statusText: String {
        guard let projection else { return AppLocalization.string("等待估算") }

        switch projection.status {
        case .alreadyFree:
            return AppLocalization.string("已实现")
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
            return AppLocalization.string("当前参数不可达")
        }
    }

    private var statusColor: Color {
        guard let projection else { return AssetTheme.textPrimary }
        switch projection.status {
        case .alreadyFree:
            return AssetTheme.positive
        case .projected:
            return AssetTheme.goldSoft
        case .unreachable:
            return AssetTheme.accentOrange
        }
    }
}

private struct DashboardFreedomAlgorithmSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "function")
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(AssetTheme.goldSoft)
                            .frame(width: 42, height: 42)
                            .background(AssetTheme.goldSoft.opacity(0.10), in: Circle())

                        Text(AppLocalization.string("财富自由算法"))
                            .font(.system(size: 27, weight: .bold, design: .rounded))
                            .foregroundStyle(AssetTheme.textPrimary)

                        Text(AppLocalization.string("用起始本金与四项参数，逐月推演被动收入覆盖生活开销的时间。"))
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(AssetTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Rectangle()
                        .fill(AssetTheme.border.opacity(0.5))
                        .frame(height: 1)
                        .padding(.vertical, 20)

                    VStack(alignment: .leading, spacing: 18) {
                        algorithmStep(
                            number: "01",
                            title: AppLocalization.string("确定起点"),
                            detail: AppLocalization.string("起始本金可选择当前净资产或零，并读取月薪、月开销、通胀率和年化收益。")
                        )
                        algorithmStep(
                            number: "02",
                            title: AppLocalization.string("逐月复利"),
                            detail: AppLocalization.string("每月先计算资产收益，再加入月薪减去通胀后月开销形成的结余。")
                        )
                        algorithmStep(
                            number: "03",
                            title: AppLocalization.string("判断追平"),
                            detail: AppLocalization.string("当每月被动收入覆盖通胀后的月开销，即视为实现财务自由。")
                        )
                    }

                    Rectangle()
                        .fill(AssetTheme.border.opacity(0.5))
                        .frame(height: 1)
                        .padding(.vertical, 20)

                    Text(AppLocalization.string("核心公式"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AssetTheme.textSecondary)
                        .padding(.bottom, 12)

                    formulaRow(
                        title: AppLocalization.string("被动收入"),
                        formula: AppLocalization.string("起始本金 × 年化收益 ÷ 12")
                    )

                    formulaRow(
                        title: AppLocalization.string("月结余"),
                        formula: AppLocalization.string("月薪 − 通胀后月开销")
                    )
                    .padding(.top, 10)
                }
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 30)
            }
            .background(AssetTheme.pageGradient.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalization.string("完成")) {
                        dismiss()
                    }
                }
            }
        }
    }

    private func algorithmStep(number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Text(number)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(AssetTheme.goldSoft)
                .frame(width: 30, height: 30)
                .background(AssetTheme.goldSoft.opacity(0.10), in: Circle())

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AssetTheme.textPrimary)

                Text(detail)
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(AssetTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func formulaRow(title: String, formula: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AssetTheme.textSecondary)

            Spacer(minLength: 12)

            Text(formula)
                .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                .foregroundStyle(AssetTheme.textPrimary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 10)
    }
}

private struct DashboardYearToDateSurplusDetailSheet: View {
    @Environment(\.dismiss) private var dismiss

    let projection: FinancialFreedomProjection?
    let amountsVisible: Bool

    var body: some View {
        NavigationStack {
            Group {
                if let projection,
                   let surplus = projection.yearToDateAnnualSurplus,
                   let startAssets = projection.yearToDateStartNetAssets,
                   let endAssets = projection.yearToDateEndNetAssets {
                    detailContent(
                        projection: projection,
                        surplus: surplus,
                        startAssets: startAssets,
                        endAssets: endAssets
                    )
                } else {
                    ContentUnavailableView(
                        AppLocalization.string("暂无本年度结余数据"),
                        systemImage: "chart.line.uptrend.xyaxis",
                        description: Text(AppLocalization.string("添加今年的资产记录后即可查看"))
                    )
                }
            }
            .navigationTitle(AppLocalization.string("结余详情"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalization.string("完成")) {
                        dismiss()
                    }
                }
            }
        }
    }

    private func detailContent(
        projection: FinancialFreedomProjection,
        surplus: Double,
        startAssets: Double,
        endAssets: Double
    ) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                Text(AppLocalization.string("年初至今结余"))
                    .font(AppTypography.meta)
                    .foregroundStyle(AssetTheme.textSecondary)

                Text(privateAmount(surplus))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(surplus >= 0 ? AssetTheme.goldSoft : AssetTheme.negative)
                    .padding(.top, 5)

                if let startDate = projection.yearToDateStartDate,
                   let endDate = projection.yearToDateEndDate {
                    Text("\(startDate.longDateString) – \(endDate.longDateString)")
                        .font(AppTypography.meta)
                        .monospacedDigit()
                        .foregroundStyle(AssetTheme.textSecondary)
                        .padding(.top, 5)
                }

                VStack(alignment: .leading, spacing: 16) {
                    surplusProgressRow(
                        title: AppLocalization.string("今年年结余"),
                        actual: projection.yearToDateAnnualSurplus,
                        required: projection.projectedAnnualSurplus
                    )
                    surplusProgressRow(
                        title: AppLocalization.string("今年月均结余"),
                        actual: projection.yearToDateMonthlyAverageSurplus,
                        required: projection.projectedAnnualSurplus / 12
                    )
                }
                .padding(.top, 22)

                Divider()
                    .overlay(AssetTheme.border.opacity(0.55))
                    .padding(.vertical, 20)

                detailRow(
                    AppLocalization.string("起点净资产"),
                    value: privateAmount(startAssets)
                )
                detailRow(
                    AppLocalization.string("当前净资产"),
                    value: privateAmount(endAssets)
                )
                detailRow(
                    AppLocalization.string("月均结余"),
                    value: projection.yearToDateMonthlyAverageSurplus.map(privateAmount) ?? "--"
                )

                if let monthsCounted = projection.yearToDateMonthsCounted {
                    Text(AppLocalization.format("按 %d 个月记录计算", monthsCounted))
                        .font(AppTypography.meta)
                        .foregroundStyle(AssetTheme.textSecondary)
                        .padding(.top, 6)
                }

                Divider()
                    .overlay(AssetTheme.border.opacity(0.55))
                    .padding(.vertical, 18)

                Label {
                    Text(AppLocalization.string("结余按记录区间内的净资产变化计算，包含资产投入、取出、投资盈亏和负债变化，并不等同于收入减去支出。"))
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(AssetTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AssetTheme.goldSoft)
                }
                .labelStyle(.titleAndIcon)
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 28)
        }
        .background(AssetTheme.pageGradient.ignoresSafeArea())
    }

    private func detailRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AssetTheme.textSecondary)

            Spacer(minLength: 12)

            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(AssetTheme.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 9)
    }

    private func surplusProgressRow(title: String, actual: Double?, required: Double?) -> some View {
        let progress = amountsVisible ? surplusProgress(actual: actual, required: required) : 0
        let color = surplusProgressColor(actual: actual, required: required)

        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AssetTheme.textPrimary)

                Spacer(minLength: 8)

                Text(AppLocalization.format(
                    "%@ / %@",
                    actual.map(privateAmount) ?? "--",
                    required.map(privateAmount) ?? "--"
                ))
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(AssetTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(AssetTheme.border.opacity(0.34))
                    Capsule()
                        .fill(color)
                        .frame(width: max(geometry.size.width * progress, progress > 0 ? 4 : 0))
                }
            }
            .frame(height: 7)
        }
    }

    private func surplusProgress(actual: Double?, required: Double?) -> CGFloat {
        guard let actual, let required,
              actual.isFinite, required.isFinite,
              abs(required) > .ulpOfOne else { return 0 }
        if required < 0 {
            return actual >= required ? 1 : 0
        }
        return CGFloat(min(max(actual / required, 0), 1))
    }

    private func surplusProgressColor(actual: Double?, required: Double?) -> Color {
        guard let actual, let required,
              actual.isFinite, required.isFinite,
              abs(required) > .ulpOfOne else {
            return AssetTheme.textSecondary.opacity(0.45)
        }
        if actual >= required { return AssetTheme.positive }
        if actual >= 0 { return AssetTheme.goldSoft }
        return AssetTheme.negative
    }

    private func privateAmount(_ value: Double) -> String {
        amountsVisible ? value.currencyString() : "••••••"
    }
}

struct DashboardFreedomProjectionChart: View {
    let projection: FinancialFreedomProjection
    let amountsVisible: Bool

    @State private var selectedHorizonYears = FreedomChartHorizon.five.rawValue

    private struct CrossingMarker {
        let monthOffset: Double
        let date: Date
        let passiveIncome: Double
    }

    private var allPoints: [FinancialFreedomProjectionPoint] {
        projection.projectionPoints
    }

    private var recommendedHorizon: FreedomChartHorizon {
        FreedomChartHorizon.recommended(for: projection.status)
    }

    private var selectedHorizon: FreedomChartHorizon {
        FreedomChartHorizon(rawValue: selectedHorizonYears) ?? recommendedHorizon
    }

    private var availableHorizons: [FreedomChartHorizon] {
        FreedomChartHorizon.available(for: projection.status)
    }

    private var displayPoints: [FinancialFreedomProjectionPoint] {
        let horizonMonths = selectedHorizon.months
        return allPoints.filter { $0.monthOffset <= horizonMonths }
    }

    private var horizonDefaultKey: String {
        switch projection.status {
        case .alreadyFree:
            return "already-free"
        case .projected(let months):
            return "projected-\(months)"
        case .unreachable:
            return "unreachable"
        }
    }

    private var crossingMarker: CrossingMarker? {
        firstCrossingMarker(in: displayPoints)
    }

    private var isUnreachable: Bool {
        if case .unreachable = projection.status {
            return true
        }
        return false
    }

    private var valueDomain: ClosedRange<Double> {
        ChartLayoutSupport.paddedValueDomain(values: displayPoints.flatMap { [$0.projectedPassiveIncome, $0.projectedMonthlyExpense] })
    }


    private var xDomain: ClosedRange<Date> {
        guard let first = displayPoints.first?.date,
              let last = displayPoints.last?.date else {
            let now = Date()
            return now...now
        }
        return first...last
    }

    private var xAxisDates: [Date] {
        chartAxisDates(displayPoints.map(\.date))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                projectionLegendChip(title: AppLocalization.string("被动收入"), color: AssetTheme.positive)
                projectionLegendChip(title: AppLocalization.string("通胀开销"), color: AssetTheme.negative, dashed: true)

                Spacer(minLength: 8)

                horizonPicker
            }

            VStack(alignment: .leading, spacing: 8) {
                freedomProjectionChart
                freedomProjectionBottomLabels
                    .padding(.horizontal, 4)
            }

            if let latestPoint = displayPoints.last {
                HStack(alignment: .top, spacing: 22) {
                    projectionFlowMetric(
                        title: AppLocalization.string("被动收入"),
                        currentValue: privateCompactAmount(projection.currentPassiveIncome),
                        futureValue: privateCompactAmount(latestPoint.projectedPassiveIncome)
                    )

                    projectionFlowMetric(
                        title: AppLocalization.string("总资产"),
                        currentValue: privateCompactAmount(projection.currentTotalAssets),
                        futureValue: privateCompactAmount(latestPoint.projectedTotalAssets)
                    )
                }
                .padding(.top, 2)
            }
        }
        .onAppear {
            selectedHorizonYears = recommendedHorizon.rawValue
        }
        .onChange(of: horizonDefaultKey) { _, _ in
            selectedHorizonYears = recommendedHorizon.rawValue
        }
    }

    private func privateCompactAmount(_ value: Double) -> String {
        amountsVisible ? value.dashboardCompactCurrencyString() : "••••"
    }

    private var freedomProjectionChart: some View {
        ZStack {
            Chart {
                ForEach(displayPoints) { point in
                    AreaMark(
                        x: .value(AppLocalization.string("日期"), point.date),
                        yStart: .value(AppLocalization.string("预计被动收入"), valueDomain.lowerBound),
                        yEnd: .value(AppLocalization.string("预计被动收入"), point.projectedPassiveIncome)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                AssetTheme.positive.opacity(0.20),
                                AssetTheme.positive.opacity(0.012)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }

                ForEach(displayPoints) { point in
                    LineMark(
                        x: .value(AppLocalization.string("日期"), point.date),
                        y: .value(AppLocalization.string("预计被动收入"), point.projectedPassiveIncome)
                    )
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(AssetTheme.positive)
                }

                ForEach(displayPoints) { point in
                    LineMark(
                        x: .value(AppLocalization.string("日期"), point.date),
                        y: .value(AppLocalization.string("通胀后月开销"), point.projectedMonthlyExpense),
                        series: .value(AppLocalization.string("系列"), AppLocalization.string("通胀后月开销"))
                    )
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round, dash: [6, 4]))
                    .foregroundStyle(AssetTheme.negative.opacity(0.92))
                }

                if let crossingMarker {
                    RuleMark(x: .value(AppLocalization.string("追平时间"), crossingMarker.date))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                        .foregroundStyle(AssetTheme.positive.opacity(0.8))

                    PointMark(
                        x: .value(AppLocalization.string("追平时间"), crossingMarker.date),
                        y: .value(AppLocalization.string("追平值"), crossingMarker.passiveIncome)
                    )
                    .foregroundStyle(AssetTheme.positive)
                    .symbolSize(40)
                    .annotation(position: .top, spacing: 7) {
                        crossingBadge(for: crossingMarker.monthOffset)
                    }
                }

                if let latestPoint = displayPoints.last {
                    PointMark(
                        x: .value(AppLocalization.string("日期"), latestPoint.date),
                        y: .value(AppLocalization.string("预计被动收入"), latestPoint.projectedPassiveIncome)
                    )
                    .foregroundStyle(AssetTheme.positive)
                    .symbolSize(30)
                }
            }
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
                AxisMarks(position: .leading, values: ChartLayoutSupport.threeTickValues(for: valueDomain)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.75, dash: [2, 5]))
                        .foregroundStyle(AssetTheme.chartGrid.opacity(0.52))
                    AxisValueLabel {
                        if amountsVisible, let amount = value.as(Double.self) {
                            Text(amount.dashboardCompactCurrencyString())
                                .font(.system(size: 8.5, weight: .medium, design: .rounded))
                                .foregroundStyle(AssetTheme.textSecondary.opacity(0.72))
                        }
                    }
                }
            }
            .chartLegend(.hidden)
            .chartPlotStyle { plotArea in
                plotArea
                    .background(AssetTheme.overlayFaint.opacity(0.08))
            }
            .accessibilityHidden(!amountsVisible)

            if isUnreachable {
                unreachableWarning
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 174)
    }

    private var unreachableWarning: some View {
        VStack(spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(AssetTheme.negative)

            Text(AppLocalization.string("按当前参数无法达到财富自由"))
                .font(.system(size: 11, weight: .semibold, design: .default))
                .foregroundStyle(AssetTheme.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AssetTheme.negative.opacity(0.24), lineWidth: 1)
        )
        .padding(.horizontal, 48)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    private var horizonPicker: some View {
        Menu {
            ForEach(availableHorizons) { horizon in
                Button {
                    selectedHorizonYears = horizon.rawValue
                } label: {
                    if selectedHorizon == horizon {
                        Label(horizon.menuTitle, systemImage: "checkmark")
                    } else {
                        Text(horizon.menuTitle)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selectedHorizon.menuTitle)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .font(AppTypography.meta)
            .foregroundStyle(AssetTheme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(AssetTheme.overlaySoft.opacity(0.72), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(AssetTheme.border.opacity(0.28), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func freedomProjectionAxisLabel(for date: Date, position: TimeMachineAxisDateLabel.Position) -> some View {
        Text(date.dashboardAxisDateString)
            .font(.system(size: 9, weight: .medium, design: .default))
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

    private func firstCrossingMarker(in points: [FinancialFreedomProjectionPoint]) -> CrossingMarker? {
        guard points.count > 1 else { return nil }
        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            let previousGap = previous.projectedPassiveIncome - previous.projectedMonthlyExpense
            let currentGap = current.projectedPassiveIncome - current.projectedMonthlyExpense
            let changesCoverageState = (previousGap < 0 && currentGap >= 0) || (previousGap > 0 && currentGap <= 0)
            guard changesCoverageState, abs(previousGap - currentGap) > .ulpOfOne else { continue }

            let progress = min(max(previousGap / (previousGap - currentGap), 0), 1)
            return CrossingMarker(
                monthOffset: Double(previous.monthOffset) + (Double(current.monthOffset - previous.monthOffset) * progress),
                date: previous.date.addingTimeInterval(current.date.timeIntervalSince(previous.date) * progress),
                passiveIncome: previous.projectedPassiveIncome + ((current.projectedPassiveIncome - previous.projectedPassiveIncome) * progress)
            )
        }
        return nil
    }

    private func crossingBadge(for monthOffset: Double) -> some View {
        Text(AppLocalization.format("约 %@ 追平", crossingLabel(for: monthOffset)))
            .font(.system(size: 10.5, weight: .semibold, design: .default))
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
                return AppLocalization.format("%d 年 %d 月", years, months)
            }
            return AppLocalization.format("%d 年", years)
        }
        return AppLocalization.format("%d 月", max(roundedMonths, 1))
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
                .font(.system(size: 10.5, weight: .semibold, design: .default))
                .foregroundStyle(AssetTheme.textSecondary.opacity(0.88))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.vertical, 4)
    }

    private func projectionFlowMetric(title: String, currentValue: String, futureValue: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium, design: .default))
                .foregroundStyle(AssetTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)

            HStack(spacing: 5) {
                Text(currentValue)
                    .foregroundStyle(AssetTheme.textPrimary)

                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(AssetTheme.textSecondary.opacity(0.62))

                Text(futureValue)
                    .foregroundStyle(AssetTheme.goldSoft)
            }
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DashboardTrendCard: View {
    let points: [TimeMachineTrendPoint]
    let latestPoint: TimeMachineTrendPoint
    @State private var selectedDate: Date?
    private let displayPoints: [TimeMachineTrendPoint]
    private let axisDates: [Date]

    init(points: [TimeMachineTrendPoint], latestPoint: TimeMachineTrendPoint) {
        self.points = points
        self.latestPoint = latestPoint

        let displayPoints = evenlySampledItems(points, maxCount: 120)
        self.displayPoints = displayPoints
        self.axisDates = chartAxisDates(displayPoints.map(\.date))
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
                AxisMarks(values: axisDates) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                        .foregroundStyle(AssetTheme.chartGrid)
                    AxisTick().foregroundStyle(AssetTheme.chartTick)
                    AxisValueLabel(anchor: ChartLayoutSupport.axisLabelAnchor(for: value.as(Date.self), in: axisDates), verticalSpacing: 6) {
                        if let date = value.as(Date.self) {
                            Text(date.dashboardAxisDateString)
                                .font(.system(size: 8.5, weight: .medium, design: .default))
                                .foregroundStyle(AssetTheme.textSecondary)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                        .foregroundStyle(AssetTheme.chartGrid)
                    AxisValueLabel {
                        if let amount = value.as(Double.self) {
                            Text(amount.chartAxisCurrencyLabel(code: "CNY"))
                                .foregroundStyle(AssetTheme.textSecondary)
                        }
                    }
                }
            }
            .chartLegend(.hidden)
            .chartOverlay { proxy in
                TimeMachineDragOverlay(
                    proxy: proxy,
                    selectableValues: displayPoints,
                    selectionDate: \.date
                ) { date in
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
}

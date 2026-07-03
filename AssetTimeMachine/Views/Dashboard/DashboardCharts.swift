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
    let yearToDateAnnualSurplus: Double?
    let yearToDateMonthlyAverageSurplus: Double?
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

enum FreedomChartHorizon: Int, CaseIterable, Identifiable {
    case three = 3
    case five = 5
    case ten = 10
    case twenty = 20

    var id: Int { rawValue }

    var months: Int { rawValue * 12 }

    var menuTitle: String {
        AppLocalization.format("未来 %d 年", rawValue)
    }

    static let maxMonths = FreedomChartHorizon.twenty.months

    static func recommended(for status: FinancialFreedomProjection.Status) -> FreedomChartHorizon {
        let targetMonths: Int
        switch status {
        case .alreadyFree:
            targetMonths = 0
        case .projected(let months):
            targetMonths = months
        case .unreachable:
            targetMonths = 60
        }

        return allCases.min {
            abs($0.months - targetMonths) < abs($1.months - targetMonths)
        } ?? .five
    }
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
        _ = status
        _ = monthlySalary
        _ = monthlyReturnRate
        return FreedomChartHorizon.maxMonths
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

    private static func yearToDateSurplusMetrics(
        from points: [TimeMachineTrendPoint],
        calendar: Calendar = .current
    ) -> (annual: Double, monthlyAverage: Double)? {
        guard !points.isEmpty else { return nil }

        let sortedPoints = points.sorted { $0.date < $1.date }
        guard let yearStart = calendar.date(from: calendar.dateComponents([.year], from: Date())) else { return nil }

        let yearPoints = sortedPoints.filter { $0.date >= yearStart }
        guard let lastPoint = yearPoints.last else { return nil }

        let baseline = sortedPoints.last(where: { $0.date < yearStart })?.netAssets ?? yearPoints.first?.netAssets ?? lastPoint.netAssets
        let annualSurplus = lastPoint.netAssets - baseline

        let monthStarts = Set(
            yearPoints.compactMap { point in
                calendar.dateInterval(of: .month, for: point.date)?.start
            }
        )
        let monthsCounted = max(monthStarts.count, 1)
        let monthlyAverage = annualSurplus / Double(monthsCounted)

        return (annualSurplus, monthlyAverage)
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
    @Binding var keyboardDismissSignal: Int

    @FocusState private var focusedField: FreedomParameterField?
    @State private var showsAlgorithmExplanation = false
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
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                Text(statusText)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(statusColor)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissKeyboard()
                    }

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
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissKeyboard()
                    }
            }

            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    parameterInputField(
                        title: AppLocalization.string("月开销"),
                        text: $monthlyExpenseText,
                        field: .monthlyExpense
                    )
                    parameterInputField(
                        title: AppLocalization.string("月薪"),
                        text: $monthlySalaryText,
                        field: .monthlySalary
                    )
                }

                HStack(spacing: 8) {
                    parameterInputField(
                        title: AppLocalization.string("通胀率"),
                        text: $inflationRateText,
                        field: .inflationRate,
                        suffix: "%"
                    )
                    parameterInputField(
                        title: AppLocalization.string("年化收益"),
                        text: $annualReturnRateText,
                        field: .annualReturnRate,
                        suffix: "%"
                    )
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                TapGesture().onEnded {
                    dismissKeyboard()
                }
            )

            annualSurplusProgressSection
                .contentShape(Rectangle())
                .onTapGesture {
                    dismissKeyboard()
                }

            if let projection, !projection.projectionPoints.isEmpty {
                DashboardFreedomProjectionChart(projection: projection)
                    .padding(.top, 2)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissKeyboard()
                    }
            }
        }
        .padding(.top, 2)
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
        .alert(AppLocalization.string("财富自由算法"), isPresented: $showsAlgorithmExplanation) {
            Button(AppLocalization.string("知道了"), role: .cancel) {}
        } message: {
            Text(AppLocalization.string("当前净资产作为起始本金；每个月先按年化收益换算出的月复利增长，再加入当月结余（月薪 - 通胀后的月开销）；被动收入按你填写的年化收益折算为每月：净资产 × 年化收益 ÷ 12；目标是被动收入覆盖考虑通胀后的月开销。"))
        }
    }

    private func parameterInputField(
        title: String,
        text: Binding<String>,
        field: FreedomParameterField,
        suffix: String? = nil
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(AssetTheme.textSecondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .contentShape(Rectangle())
                .onTapGesture {
                    dismissKeyboard()
                }

            TextField(AppLocalization.string("输入"), text: text)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(AssetTheme.textPrimary)
                .multilineTextAlignment(.trailing)
                .keyboardType(.decimalPad)
                .focused($focusedField, equals: field)
                .submitLabel(.done)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .onSubmit {
                    commitField(field)
                    focusedField = nil
                }

            if let suffix {
                Text(suffix)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(AssetTheme.textSecondary)
                    .fixedSize(horizontal: true, vertical: false)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissKeyboard()
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(AssetTheme.overlaySubtle.opacity(0.72), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    focusedField == field ? AssetTheme.gold.opacity(0.42) : AssetTheme.border.opacity(0.24),
                    lineWidth: 1
                )
        )
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

    private var annualSurplusProgressSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            surplusProgressRow(
                title: AppLocalization.string("今年年结余"),
                actual: projection?.yearToDateAnnualSurplus,
                required: projection?.projectedAnnualSurplus
            )
            surplusProgressRow(
                title: AppLocalization.string("今年月均结余"),
                actual: projection?.yearToDateMonthlyAverageSurplus,
                required: projection.map { $0.projectedAnnualSurplus / 12 }
            )
        }
    }

    private func surplusProgressRow(title: String, actual: Double?, required: Double?) -> some View {
        let actualText = actual.map { $0.currencyString() } ?? "--"
        let requiredText = required.map { $0.currencyString() } ?? "--"
        let progress = surplusProgress(actual: actual, required: required)
        let progressColor = surplusProgressColor(actual: actual, required: required)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(AssetTheme.textPrimary)

                Spacer(minLength: 8)

                Text(AppLocalization.format("%@ / %@", actualText, requiredText))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(AssetTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(AssetTheme.border.opacity(0.34))

                    Capsule()
                        .fill(progressColor)
                        .frame(width: max(geometry.size.width * progress, progress > 0 ? 4 : 0))
                }
            }
            .frame(height: 6)
        }
    }

    private func surplusProgress(actual: Double?, required: Double?) -> CGFloat {
        guard let actual, let required, required.isFinite, abs(required) > .ulpOfOne else { return 0 }
        guard actual.isFinite else { return 0 }
        let ratio = actual / required
        guard ratio.isFinite else { return 0 }
        return CGFloat(min(max(ratio, 0), 1))
    }

    private func surplusProgressColor(actual: Double?, required: Double?) -> Color {
        guard let actual, let required, required.isFinite, abs(required) > .ulpOfOne else {
            return AssetTheme.textSecondary.opacity(0.45)
        }
        if actual >= required {
            return AssetTheme.positive
        }
        if actual >= 0 {
            return AssetTheme.goldSoft
        }
        return AssetTheme.negative
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
                return AppLocalization.format("还需 %d 年 %d 月财富自由", years, remainingMonths)
            } else if years > 0 {
                return AppLocalization.format("还需 %d 年财富自由", years)
            } else {
                return AppLocalization.format("还需 %d 月财富自由", remainingMonths)
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

    @State private var selectedHorizonYears = FreedomChartHorizon.five.rawValue

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

    private var allPoints: [FinancialFreedomProjectionPoint] {
        projection.projectionPoints
    }

    private var recommendedHorizon: FreedomChartHorizon {
        FreedomChartHorizon.recommended(for: projection.status)
    }

    private var selectedHorizon: FreedomChartHorizon {
        FreedomChartHorizon(rawValue: selectedHorizonYears) ?? recommendedHorizon
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

    private var chartAnalysis: ChartAnalysis {
        buildChartAnalysis(from: displayPoints)
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                projectionLegendChip(title: AppLocalization.string("被动收入"), color: AssetTheme.goldSoft)
                projectionLegendChip(title: AppLocalization.string("通胀开销"), color: AssetTheme.accentOrange, dashed: true)

                Spacer(minLength: 8)

                horizonPicker
            }

            VStack(alignment: .leading, spacing: 8) {
                freedomProjectionChart
                freedomProjectionBottomLabels
                    .padding(.horizontal, 4)
            }

            if let latestPoint = displayPoints.last {
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
        .onAppear {
            selectedHorizonYears = recommendedHorizon.rawValue
        }
        .onChange(of: horizonDefaultKey) { _, _ in
            selectedHorizonYears = recommendedHorizon.rawValue
        }
    }

    private var freedomProjectionChart: some View {
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

            ForEach(displayPoints) { point in
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

            if let latestPoint = displayPoints.last {
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
            AxisMarks(values: ChartLayoutSupport.threeTickValues(for: valueDomain)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.75, dash: [2, 5]))
                    .foregroundStyle(AssetTheme.chartGrid.opacity(0.68))
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
        .overlay(alignment: .leading) {
            TimeMachineAxisStrip(
                topLabel: TimeMachineAxisValueStyle.currency(code: "CNY").compactLabel(for: valueDomain.upperBound),
                middleLabel: TimeMachineAxisValueStyle.currency(code: "CNY").compactLabel(for: (valueDomain.lowerBound + valueDomain.upperBound) / 2),
                bottomLabel: TimeMachineAxisValueStyle.currency(code: "CNY").compactLabel(for: valueDomain.lowerBound),
                alignment: .leading,
                color: AssetTheme.goldSoft
            )
            .frame(width: 42)
            .padding(.leading, 10)
            .padding(.vertical, 14)
            .allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) {
            Text(AppLocalization.string("收入覆盖趋势"))
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(AssetTheme.textSecondary.opacity(0.72))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
        }
    }

    private var horizonPicker: some View {
        Menu {
            ForEach(FreedomChartHorizon.allCases) { horizon in
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

    private func buildChartAnalysis(from points: [FinancialFreedomProjectionPoint]) -> ChartAnalysis {
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
                    AxisValueLabel(anchor: ChartLayoutSupport.axisLabelAnchor(for: value.as(Date.self), in: axisDates), verticalSpacing: 6) {
                        if let date = value.as(Date.self) {
                            Text(date.dashboardAxisDateString)
                                .font(.system(size: 8.5, weight: .medium, design: .rounded))
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
}

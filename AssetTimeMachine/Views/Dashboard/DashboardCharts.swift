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

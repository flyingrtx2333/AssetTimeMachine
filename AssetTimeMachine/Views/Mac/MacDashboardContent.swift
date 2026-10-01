#if targetEnvironment(macCatalyst)
import SwiftUI
import SwiftData
import Charts

/// Desktop presentation of the same dashboard projection used on iPhone.
struct MacDashboardContent: View {
    @Environment(\.colorScheme) private var colorScheme
    let totalAssets: Double
    let points: [TimeMachineTrendPoint]
    let slices: [DashboardAllocationSlice]
    let projection: FinancialFreedomProjection?
    @Binding var amountsVisible: Bool
    @ObservedObject var cloudStore: AssetTimeMachineCloudStore
    let onRecord: () -> Void
    let onHistory: () -> Void
    let onCloud: () -> Void
    let onFreedom: () -> Void
    @AppStorage("dashboard.inflationRate") private var inflationRate = 0.05
    @State private var period = 365
    @State private var selectedDate: Date?
    @Query private var recentSnapshots: [AssetSnapshot]

    init(totalAssets: Double, points: [TimeMachineTrendPoint], slices: [DashboardAllocationSlice],
         projection: FinancialFreedomProjection?, amountsVisible: Binding<Bool>,
         cloudStore: AssetTimeMachineCloudStore, onRecord: @escaping () -> Void,
         onHistory: @escaping () -> Void, onCloud: @escaping () -> Void, onFreedom: @escaping () -> Void) {
        self.totalAssets = totalAssets
        self.points = points
        self.slices = slices
        self.projection = projection
        self._amountsVisible = amountsVisible
        self.cloudStore = cloudStore
        self.onRecord = onRecord
        self.onHistory = onHistory
        self.onCloud = onCloud
        self.onFreedom = onFreedom
        var descriptor = FetchDescriptor<AssetSnapshot>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        descriptor.fetchLimit = 3
        _recentSnapshots = Query(descriptor)
    }

    private func label(_ key: String) -> String { AppLocalization.string(key) }
    private func money(_ value: Double?) -> String {
        guard amountsVisible else { return "••••••" }
        return value?.currencyString() ?? "—"
    }
    private var chartPoints: [TimeMachineTrendPoint] {
        guard let latest = points.last,
              let cutoff = Calendar.current.date(byAdding: .day, value: -period, to: latest.date) else { return [] }
        return points.filter { $0.date >= cutoff }
    }
    private var plotPoints: [TimeMachineTrendPoint] {
        MacTimeMachineSampling.extremaPreserving(chartPoints, maxCount: 120)
    }
    private var chartDomain: ClosedRange<Date> {
        let end = chartPoints.last?.date ?? .now
        let start = chartPoints.first?.date ?? end
        return start < end ? start...end : end.addingTimeInterval(-86400)...end.addingTimeInterval(86400)
    }
    private var selectedPoint: TimeMachineTrendPoint? {
        guard let selectedDate else { return nil }
        let values = chartPoints
        var lower = 0
        var upper = values.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if values[middle].date < selectedDate { lower = middle + 1 }
            else { upper = middle }
        }
        if lower == 0 { return values.first }
        if lower == values.count { return values.last }
        return selectedDate.timeIntervalSince(values[lower - 1].date)
            <= values[lower].date.timeIntervalSince(selectedDate)
            ? values[lower - 1] : values[lower]
    }
    private var progress: Double {
        guard let projection, projection.currentMonthlyExpense > 0,
              projection.currentPassiveIncome.isFinite else { return 0 }
        return min(1, max(0, projection.currentPassiveIncome / projection.currentMonthlyExpense))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            summary
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    trend.frame(minWidth: 320, maxWidth: .infinity)
                    allocation.frame(minWidth: 285, idealWidth: 320, maxWidth: 350)
                }
                VStack(spacing: 12) { trend; allocation }
            }
            freedom
            recentRecords
        }
        .padding(.horizontal, 0)
        .padding(.top, 0)
        .font(.system(size: 12))
        #if DEBUG
        .task(id: points.count) {
            if AppPreviewSession.isActive {
                NSLog("[MacPreview] trend points=\(points.count), displayed=\(chartPoints.count), first=\(String(describing: points.first?.date)), last=\(String(describing: points.last?.date))")
                precondition(MacTimeMachineSampling.preservesExtrema(
                    full: chartPoints, sampled: plotPoints, maxCount: 120
                ))
            }
        }
        #endif
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text(label("资产总览")).font(.system(size: 24, weight: .semibold))
            Spacer()
            Button(action: onCloud) { DashboardCloudStatusButton(store: cloudStore) }
                .buttonStyle(.plain)
            Button { amountsVisible.toggle() } label: {
                Image(systemName: amountsVisible ? "eye" : "eye.slash").font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label(amountsVisible ? "隐藏资产金额" : "显示资产金额"))
        }
        .padding(.vertical, 2)
    }

    private var summary: some View {
        HStack(spacing: 16) {
            metric("总资产", value: points.isEmpty ? nil : totalAssets)
            Divider().frame(height: 42)
            metric("净资产", value: points.last?.netAssets)
            Divider().frame(height: 42)
            metric("总负债", value: points.last?.liabilities)
            Button(action: onRecord) {
                Label(label("记录今日资产"), systemImage: "plus.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12).padding(.vertical, 11)
                    .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                    .background(AssetTheme.goldSoft.gradient, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("n", modifiers: .command)
        }
        .padding(16).macDashboardPanel()
    }

    private func metric(_ title: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("\(label(title)) (CNY)").foregroundStyle(AssetTheme.textSecondary)
            Text(money(value)).font(.system(size: 22, weight: .semibold))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var trend: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(label("资产走势")).font(.system(size: 14, weight: .semibold))
                Spacer()
                Picker(label("资产走势"), selection: $period) {
                    Text(label("近7天")).tag(7)
                    Text(label("近30日")).tag(30)
                    Text(label("1年")).tag(365)
                }
                .pickerStyle(.segmented).frame(maxWidth: 190)
            }
            if points.isEmpty {
                ContentUnavailableView(label("暂无资产记录"), systemImage: "chart.xyaxis.line",
                                       description: Text(label("记录今日资产")))
                    .frame(height: 175)
            } else if !amountsVisible {
                ContentUnavailableView(label("资产金额已隐藏"), systemImage: "eye.slash")
                    .frame(height: 175)
            } else {
                Chart {
                    ForEach(plotPoints) { point in
                        AreaMark(x: .value(label("日期"), point.date), y: .value(label("总资产"), point.mainAssets))
                            .foregroundStyle(LinearGradient(colors: [AssetTheme.gold.opacity(0.22), .clear],
                                                            startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value(label("日期"), point.date), y: .value(label("总资产"), point.mainAssets))
                            .foregroundStyle(AssetTheme.gold).lineStyle(StrokeStyle(lineWidth: 2.5))
                    }
                    if let point = selectedPoint ?? (chartPoints.count == 1 ? chartPoints.first : nil) {
                        RuleMark(x: .value(label("日期"), point.date))
                            .foregroundStyle(AssetTheme.gold.opacity(0.4))
                        PointMark(x: .value(label("日期"), point.date), y: .value(label("总资产"), point.mainAssets))
                            .foregroundStyle(AssetTheme.gold)
                    }
                }
                .chartXScale(domain: chartDomain)
                .chartXSelection(value: $selectedDate)
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let amount = value.as(Double.self) {
                                Text(amount.formatted(.number.notation(.compactName)))
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine()
                        AxisValueLabel(anchor: .top) {
                            if let date = value.as(Date.self) {
                                Text(date, format: .dateTime.month(.abbreviated))
                            }
                        }
                    }
                }
                .frame(height: 153)
                HStack {
                    if let point = selectedPoint ?? chartPoints.last {
                        Text(point.date, format: .dateTime.year().month().day())
                        Spacer()
                        Text(money(point.mainAssets)).monospacedDigit()
                    }
                }
                .font(.caption).foregroundStyle(AssetTheme.textSecondary)
            }
        }
        .padding(14).frame(height: 240).macDashboardPanel()
        .onChange(of: period) { _, _ in selectedDate = nil }
    }

    private var allocation: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(label("资产构成")).font(.system(size: 14, weight: .semibold))
            if slices.isEmpty {
                ContentUnavailableView(label("暂无资产分布"), systemImage: "chart.pie")
            } else if !amountsVisible {
                ContentUnavailableView(label("资产金额已隐藏"), systemImage: "eye.slash")
            } else {
                HStack(spacing: 14) {
                    ZStack {
                        Chart(slices) { slice in
                            SectorMark(angle: .value(label("占比"), max(0, slice.amount)),
                                       innerRadius: .ratio(0.72), angularInset: 1.2)
                                .foregroundStyle(slice.color)
                        }.chartLegend(.hidden)
                        Text(label("总资产")).font(.caption).foregroundStyle(AssetTheme.textSecondary)
                    }
                    .frame(width: 112, height: 142)
                    .accessibilityHidden(true)
                    VStack(spacing: 12) {
                        ForEach(slices) { slice in
                            HStack(spacing: 6) {
                                Circle().fill(slice.color).frame(width: 6, height: 6)
                                Text(slice.title).font(.system(size: 11)).lineLimit(1)
                                Spacer(minLength: 2)
                                Text("¥" + slice.amount.formatted(.number.notation(.compactName).precision(.fractionLength(1))))
                                    .font(.system(size: 10)).foregroundStyle(AssetTheme.textSecondary)
                                    .lineLimit(1).minimumScaleFactor(0.8)
                                Text((totalAssets > 0 ? slice.amount / totalAssets : 0)
                                    .formatted(.percent.precision(.fractionLength(0))))
                                    .monospacedDigit().foregroundStyle(AssetTheme.textSecondary)
                            }
                            .font(.system(size: 12))
                            .accessibilityLabel("\(slice.title), \(money(slice.amount))")
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14).frame(height: 240).macDashboardPanel()
    }

    private var freedom: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Text(label("财务自由进度")).font(.system(size: 14, weight: .semibold))
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(AssetTheme.gold.opacity(0.12))
                        Capsule().fill(AssetTheme.gold.gradient)
                            .frame(width: geometry.size.width * (amountsVisible ? progress : 0))
                    }
                }.frame(height: 6)
                    .accessibilityLabel(label("财务自由进度"))
                    .accessibilityValue(amountsVisible ? progress.formatted(.percent) : "—")
                Text(amountsVisible && projection != nil ? progress.formatted(.percent.precision(.fractionLength(0))) : "—")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(AssetTheme.gold)
                Button(action: onFreedom) { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(.plain).accessibilityLabel(label("调整财务自由假设"))
            }
            HStack(spacing: 14) {
                assumption("月开销", icon: "wallet.pass", value: projection?.currentMonthlyExpense)
                assumption("月薪", icon: "banknote", value: projection?.monthlySalary)
                VStack(alignment: .leading, spacing: 6) {
                    Label(label("年化收益"), systemImage: "target").foregroundStyle(AssetTheme.textSecondary)
                    Text(projection?.annualReturnRate.formatted(.percent.precision(.fractionLength(1))) ?? "—")
                        .font(.system(size: 14, weight: .semibold)).monospacedDigit()
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 6) {
                    Label(label("通胀率"), systemImage: "chart.line.uptrend.xyaxis").foregroundStyle(AssetTheme.textSecondary)
                    Text(inflationRate.formatted(.percent.precision(.fractionLength(1))))
                        .font(.system(size: 14, weight: .semibold)).monospacedDigit()
                }.frame(maxWidth: .infinity, alignment: .leading)
                Divider().frame(height: 38)
                assumption("年初至今结余", icon: "chart.line.uptrend.xyaxis", value: projection?.yearToDateAnnualSurplus)
            }
        }
        .padding(14).macDashboardPanel()
    }

    private func assumption(_ title: String, icon: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(label(title), systemImage: icon).foregroundStyle(AssetTheme.textSecondary)
            Text(money(value)).font(.system(size: 14, weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var recentRecords: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(label("最近的资产记录")).font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(action: onHistory) { Label(label("查看全部"), systemImage: "chevron.right") }
                    .buttonStyle(.plain).foregroundStyle(AssetTheme.textSecondary)
            }
            HStack {
                tableCell(label("日期")); tableCell(label("总资产")); tableCell(label("净资产")); tableCell(label("总负债"))
            }
            .foregroundStyle(AssetTheme.textSecondary).font(.caption)
            .padding(7).background(AssetTheme.backgroundSecondary, in: RoundedRectangle(cornerRadius: 6))
            ForEach(recentSnapshots) { snapshot in
                NavigationLink { SnapshotDetailView(snapshot: snapshot) } label: {
                    let assets = snapshot.entries.filter { $0.item?.category?.group != .liability }.reduce(0) { $0 + $1.resolvedAmount }
                    let debts = snapshot.entries.filter { $0.item?.category?.group == .liability }.reduce(0) { $0 + $1.resolvedAmount }
                    HStack {
                        tableCell(snapshot.date.formatted(date: .numeric, time: .omitted))
                        tableCell(money(assets)); tableCell(money(assets - debts)); tableCell(money(debts))
                    }.padding(.horizontal, 0).padding(.vertical, 4).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider()
            }
            if recentSnapshots.isEmpty {
                Button(label("记录今日资产"), action: onRecord).buttonStyle(.bordered)
            }
        }
        .padding(14).macDashboardPanel()
    }
    private func tableCell(_ value: String) -> some View {
        Text(value).monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension View {
    func macDashboardPanel() -> some View {
        self.background(AssetTheme.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(AssetTheme.border.opacity(0.6), lineWidth: 1))
    }
}
#endif

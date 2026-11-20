import AssetTimeMachineBacktestCore
import Charts
import SwiftUI

struct MarketAssetTrendSelection: Identifiable {
    let symbol: String
    let title: String

    var id: String { symbol }
    var historySymbol: String { symbol == "usd_cash" ? "usd_per_cny" : symbol }
}

struct MarketAssetTrendSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    let asset: MarketAssetTrendSelection
    let market: RemoteMarketStore

    @State private var period: Period = .quarter
    @State private var selectedDate: Date?
    @State private var history: [BacktestHistoricalPricePoint] = []
    @State private var unit = ""
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var retry = 0

    private static let calendar = BacktestSeriesAlignment.historicalSeriesCalendar

    private enum Period: Int, CaseIterable {
        case month = 1, quarter = 3, halfYear = 6, year = 12

        var title: String {
            switch self {
            case .month: AppLocalization.string("1个月")
            case .quarter: AppLocalization.string("3个月")
            case .halfYear: AppLocalization.string("6个月")
            case .year: AppLocalization.string("1年")
            }
        }
    }

    private var visibleHistory: ArraySlice<BacktestHistoricalPricePoint> {
        guard let last = history.last,
              let start = Self.calendar.date(byAdding: .month, value: -period.rawValue, to: last.date)
        else { return history[...] }
        return history.drop(while: { $0.date < start })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if let descriptor = market.assetDescriptor(for: asset.symbol) {
                    MarketAssetLogoView(asset: descriptor, size: 30)
                } else {
                    MarketAssetLogoView(symbol: asset.symbol, sectionID: "other", title: asset.title, size: 30)
                }
                Text(asset.title).font(.headline).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Button(AppLocalization.string("关闭")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            #if os(macOS)
            content.padding(20)
            #else
            ScrollView { content.padding(20) }
            #endif
        }
        #if os(macOS)
        .frame(width: 540)
        #endif
        .task(id: retry) { await loadHistory() }
        .accessibilityIdentifier("marketAssetTrendSheet")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let first = visibleHistory.first, let last = visibleHistory.last {
                trend(first: first, last: last)
            } else if isLoading {
                ProgressView(AppLocalization.string("正在加载行情"))
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                VStack(spacing: 12) {
                    Text(AppLocalization.string(loadFailed ? "历史数据加载失败" : "暂无历史数据"))
                        .foregroundStyle(AssetTheme.textSecondary)
                    Button(AppLocalization.string("重试")) { retry += 1 }
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            }
        }
    }

    private func trend(first: BacktestHistoricalPricePoint, last: BacktestHistoricalPricePoint) -> some View {
        let points = visibleHistory
        let selected = selectedDate.flatMap { date in
            points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
        }
        let displayed = selected ?? last
        let change = last.price / first.price - 1
        let dateFormat = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale,
                                          calendar: Self.calendar, timeZone: Self.calendar.timeZone)

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(displayed.price.formatted(.number.precision(.fractionLength(2)).locale(locale)))
                            .font(.title.weight(.semibold).monospacedDigit())
                        Text(unit).font(.caption).foregroundStyle(AssetTheme.textSecondary)
                    }
                    Text(displayed.date, format: dateFormat)
                        .font(.caption).foregroundStyle(AssetTheme.textSecondary)
                }
                Spacer(minLength: 4)
                if points.count > 1, change.isFinite {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(change.formatted(.percent.precision(.fractionLength(2)).sign(strategy: .always(includingZero: false)).locale(locale)))
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(change == 0 ? AssetTheme.textSecondary : change > 0 ? AssetTheme.positive : AssetTheme.negative)
                        Text(AppLocalization.string("区间涨跌"))
                            .font(.caption).foregroundStyle(AssetTheme.textSecondary)
                    }
                }
            }

            Picker(AppLocalization.string("区间"), selection: $period) {
                ForEach(Period.allCases, id: \.self) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: period) { selectedDate = nil }

            Chart {
                ForEach(points, id: \.date) { point in
                    LineMark(x: .value("Date", point.date), y: .value("Price", point.price))
                        .foregroundStyle(AssetTheme.gold)
                }
                if let point = selected ?? (points.count == 1 ? last : nil) {
                    RuleMark(x: .value("Date", point.date))
                        .foregroundStyle(AssetTheme.border)
                    PointMark(x: .value("Date", point.date), y: .value("Price", point.price))
                        .foregroundStyle(AssetTheme.gold)
                }
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
            .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) }
            #if os(macOS)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    if let plot = proxy.plotFrame {
                        Color.clear.contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    let frame = geometry[plot]
                                    selectedDate = frame.contains(location) ? proxy.value(atX: location.x - frame.minX) : nil
                                case .ended:
                                    selectedDate = nil
                                }
                            }
                    }
                }
            }
            #else
            .chartXSelection(value: $selectedDate)
            #endif
            .environment(\.calendar, Self.calendar)
            .environment(\.timeZone, Self.calendar.timeZone)
            .frame(height: 224)
            .accessibilityLabel(AppLocalization.string("历史走势"))
        }
    }

    @MainActor
    private func loadHistory() async {
        isLoading = true
        loadFailed = false
        let symbol = asset.historySymbol

        if retry == 0, let series = market.history(for: symbol), show(series) {
            isLoading = false
            return
        }

        let didRefresh = AppPreviewSession.isActive
            ? true : await market.refreshHistory(for: [symbol], force: retry > 0)
        guard !Task.isCancelled else { return }
        if let series = market.history(for: symbol) {
            _ = show(series)
        }
        loadFailed = history.isEmpty && !didRefresh
        isLoading = false
    }

    private func show(_ series: PublicHistorySeries) -> Bool {
        let isDollarCash = asset.symbol == "usd_cash"
        history = BacktestSeriesAlignment.sanitizedDatePriceMap(from: series).compactMap { day, quote in
            let price = isDollarCash ? 1 / quote : quote
            guard price.isFinite, let date = BacktestSeriesAlignment.historicalSeriesDate(from: day) else { return nil }
            return BacktestHistoricalPricePoint(date: date, price: price)
        }.sorted { $0.date < $1.date }

        let descriptor = MarketAssetDescriptor(series: series)
        let quoteUnit = descriptor.recordUnitTitle
        let currency = series.currency.uppercased()
        if isDollarCash { unit = "CNY/USD" }
        else if series.category == "index" || quoteUnit == AppLocalization.string("点") { unit = AppLocalization.string("点") }
        else if quoteUnit.isEmpty || currency == quoteUnit { unit = currency }
        else { unit = "\(currency)/\(quoteUnit)" }

        return !history.isEmpty
    }
}

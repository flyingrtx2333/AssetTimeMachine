import Charts
import SwiftUI
import UIKit

private struct BacktestPosterCurvePoint: Identifiable {
    let date: Date
    let returnRatio: Double
    let sequence: Int

    var id: Int { sequence }
}

private enum BacktestPosterPalette {
    static let background = Color(red: 0.035, green: 0.043, blue: 0.052)
    static let gold = Color(red: 0.94, green: 0.70, blue: 0.30)
    static let green = Color(red: 0.31, green: 0.84, blue: 0.60)
    static let red = Color(red: 0.96, green: 0.42, blue: 0.42)
    static let benchmark = Color(red: 0.35, green: 0.69, blue: 1.00)
    static let textPrimary = Color.white.opacity(0.96)
    static let textSecondary = Color.white.opacity(0.56)
    static let divider = Color.white.opacity(0.11)
}

struct BacktestSharePosterView: View {
    let title: String
    let report: AdvancedBacktestReport
    let comparisonSeries: [BacktestChartComparisonSeries]

    private var strategyCurve: [BacktestPosterCurvePoint] {
        normalizedCurve(report.points)
    }

    private var benchmark: BacktestChartComparisonSeries? {
        comparisonSeries.first
    }

    private var benchmarkCurve: [BacktestPosterCurvePoint] {
        guard let benchmark else { return [] }
        return normalizedCurve(benchmark.points)
    }

    private var curveDomain: ClosedRange<Double> {
        let values = (strategyCurve + benchmarkCurve).map(\.returnRatio)
        let minimum = min(values.min() ?? 0, 0)
        let maximum = max(values.max() ?? 0, 0)
        let span = max(maximum - minimum, 0.1)
        return (minimum - span * 0.06)...(maximum + span * 0.10)
    }

    private var returnAccent: Color {
        report.totalReturn >= 0 ? BacktestPosterPalette.green : BacktestPosterPalette.red
    }

    private var dateRangeText: String {
        guard let startDate = report.points.first?.date,
              let endDate = report.points.last?.date else { return "--" }
        return "\(startDate.recordDateString) — \(endDate.recordDateString)"
    }

    var body: some View {
        ZStack {
            BacktestPosterPalette.background

            RadialGradient(
                colors: [BacktestPosterPalette.gold.opacity(0.20), .clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 245
            )
            .offset(x: 65, y: -95)

            VStack(alignment: .leading, spacing: 0) {
                brandHeader

                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.system(size: 24, weight: .semibold, design: .default))
                        .foregroundStyle(BacktestPosterPalette.textPrimary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.76)

                    Text(AppLocalization.format("回测区间：%@", dateRangeText))
                        .font(.system(size: 10, weight: .medium, design: .default))
                        .foregroundStyle(BacktestPosterPalette.textSecondary)
                        .monospacedDigit()
                }
                .padding(.top, 18)

                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    Text(signedPercent(report.totalReturn))
                        .font(.system(size: 39, weight: .semibold, design: .default))
                        .foregroundStyle(returnAccent)
                        .monospacedDigit()

                    Text(AppLocalization.string("策略收益"))
                        .font(.system(size: 11, weight: .medium, design: .default))
                        .foregroundStyle(BacktestPosterPalette.textSecondary)
                        .padding(.bottom, 5)
                }
                .padding(.top, 13)

                curveSection
                    .padding(.top, 14)

                Rectangle()
                    .fill(BacktestPosterPalette.divider)
                    .frame(height: 1)
                    .padding(.top, 14)

                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                    alignment: .leading,
                    spacing: 11
                ) {
                    metric(AppLocalization.string("年化收益"), signedOptionalPercent(report.annualizedReturn), accent: report.annualizedReturn.map { $0 >= 0 ? BacktestPosterPalette.green : BacktestPosterPalette.red })
                    metric(AppLocalization.string("最大回撤"), report.maxDrawdown.percentString(maxFractionDigits: 1), accent: BacktestPosterPalette.red)
                    metric(AppLocalization.string("夏普比率"), report.sharpeRatio.map { String(format: "%.2f", $0) } ?? "--")
                    metric(AppLocalization.string("年化波动"), report.annualizedVolatility?.percentString(maxFractionDigits: 1) ?? "--")
                }
                .padding(.top, 13)

                Spacer(minLength: 10)

                HStack(alignment: .center, spacing: 8) {
                    Text(AppLocalization.string("历史回测不代表未来表现"))
                        .font(.system(size: 8.5, weight: .regular, design: .default))
                        .foregroundStyle(Color.white.opacity(0.38))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)

                    Spacer(minLength: 6)

                    Text("ASSET TIME MACHINE")
                        .font(.system(size: 8, weight: .semibold, design: .default))
                        .tracking(1.15)
                        .foregroundStyle(BacktestPosterPalette.gold.opacity(0.86))
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
        }
        .frame(width: 360, height: 480)
        .clipped()
        .environment(\.colorScheme, .dark)
    }

    private var brandHeader: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(BacktestPosterPalette.gold)
                    .frame(width: 28, height: 28)

                Image(systemName: "chart.xyaxis.line")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(BacktestPosterPalette.background)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("ASSET TIME MACHINE")
                    .font(.system(size: 9, weight: .semibold, design: .default))
                    .tracking(1.05)
                    .foregroundStyle(BacktestPosterPalette.textPrimary)
                Text(AppLocalization.string("量化回测"))
                    .font(.system(size: 9, weight: .medium, design: .default))
                    .foregroundStyle(BacktestPosterPalette.textSecondary)
            }

            Spacer(minLength: 8)

            Text(AppLocalization.string("回测报告"))
                .font(.system(size: 9, weight: .semibold, design: .default))
                .tracking(0.7)
                .foregroundStyle(BacktestPosterPalette.gold)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(BacktestPosterPalette.gold.opacity(0.10), in: Capsule())
                .overlay(Capsule().stroke(BacktestPosterPalette.gold.opacity(0.28), lineWidth: 0.8))
        }
    }

    private var curveSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 11) {
                Text(AppLocalization.string("净值走势"))
                    .font(.system(size: 11, weight: .semibold, design: .default))
                    .foregroundStyle(BacktestPosterPalette.textPrimary)

                Spacer(minLength: 6)

                posterLegend(color: returnAccent, title: AppLocalization.string("策略净值"), dashed: false)
                if let benchmark {
                    posterLegend(color: BacktestPosterPalette.benchmark, title: benchmark.title, dashed: true)
                }
            }

            Chart {
                RuleMark(y: .value("Base", 0))
                    .foregroundStyle(BacktestPosterPalette.divider)

                ForEach(strategyCurve) { point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("Return", point.returnRatio)
                    )
                    .foregroundStyle(by: .value("Series", "poster.strategy"))
                    .lineStyle(StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
                }

                ForEach(benchmarkCurve) { point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("Benchmark", point.returnRatio)
                    )
                    .foregroundStyle(by: .value("Series", "poster.benchmark"))
                    .lineStyle(StrokeStyle(lineWidth: 1.25, dash: [4, 3]))
                    .interpolationMethod(.monotone)
                }
            }
            .chartForegroundStyleScale(
                domain: ["poster.strategy", "poster.benchmark"],
                range: [returnAccent, BacktestPosterPalette.benchmark.opacity(0.88)]
            )
            .chartYScale(domain: curveDomain)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.6, dash: [2, 3]))
                        .foregroundStyle(Color.white.opacity(0.09))
                    AxisValueLabel {
                        if let ratio = value.as(Double.self) {
                            Text(ratio.percentString(maxFractionDigits: 0))
                                .font(.system(size: 7.5, weight: .regular, design: .default))
                                .foregroundStyle(Color.white.opacity(0.38))
                        }
                    }
                }
            }
            .frame(height: 116)

            HStack {
                Text(report.points.first?.date.recordDateString ?? "--")
                Spacer()
                Text(report.points.last?.date.recordDateString ?? "--")
            }
            .font(.system(size: 8, weight: .medium, design: .default))
            .foregroundStyle(Color.white.opacity(0.36))
            .monospacedDigit()
        }
    }

    private func posterLegend(color: Color, title: String, dashed: Bool) -> some View {
        HStack(spacing: 4) {
            if dashed {
                Capsule()
                    .stroke(color, style: StrokeStyle(lineWidth: 1.2, dash: [3, 2]))
                    .frame(width: 13, height: 4)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 5, height: 5)
            }
            Text(title)
                .font(.system(size: 7.5, weight: .medium, design: .default))
                .foregroundStyle(BacktestPosterPalette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
    }

    private func metric(_ title: String, _ value: String, accent: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 9, weight: .medium, design: .default))
                .foregroundStyle(BacktestPosterPalette.textSecondary)
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .default))
                .foregroundStyle(accent ?? BacktestPosterPalette.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func normalizedCurve(_ points: [BacktestSeriesPoint]) -> [BacktestPosterCurvePoint] {
        let sampled = BacktestChartData.sampledPoints(from: points, maxCount: 160)
        guard let firstValue = sampled.first?.portfolioValue, firstValue > 0 else { return [] }
        return sampled.enumerated().map { index, point in
            BacktestPosterCurvePoint(
                date: point.date,
                returnRatio: point.portfolioValue / firstValue - 1,
                sequence: index
            )
        }
    }

    private func signedPercent(_ value: Double) -> String {
        String(format: "%+.1f%%", locale: AppLocalization.currentLocale, value * 100)
    }

    private func signedOptionalPercent(_ value: Double?) -> String {
        value.map(signedPercent) ?? "--"
    }
}

@MainActor
enum BacktestSharePosterRenderer {
    static func image(
        title: String,
        report: AdvancedBacktestReport,
        comparisonSeries: [BacktestChartComparisonSeries]
    ) -> UIImage? {
        let content = BacktestSharePosterView(
            title: title,
            report: report,
            comparisonSeries: comparisonSeries
        )
        .environment(\.locale, AppLocalization.currentLocale)
        .frame(width: 360, height: 480)

        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(width: 360, height: 480)
        renderer.scale = 3
        renderer.isOpaque = true
        return renderer.uiImage
    }
}

struct BacktestPosterPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let report: AdvancedBacktestReport
    let comparisonSeries: [BacktestChartComparisonSeries]

    @State private var posterImage: UIImage?
    @State private var isGenerating = false
    @State private var showsShareSheet = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                Group {
                    if let posterImage {
                        GeometryReader { proxy in
                            ScrollView(showsIndicators: false) {
                                Image(uiImage: posterImage)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxWidth: min(proxy.size.width - 40, 520))
                                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                                    .shadow(color: Color.black.opacity(0.30), radius: 24, y: 14)
                                    .frame(maxWidth: .infinity)
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 18)
                            }
                        }
                    } else {
                        VStack(spacing: 13) {
                            ProgressView()
                                .tint(AssetTheme.gold)
                                .controlSize(.large)
                            Text(AppLocalization.string("正在生成海报"))
                                .font(AppTypography.bodyStrong)
                                .foregroundStyle(AssetTheme.textSecondary)
                        }
                    }
                }
            }
            .navigationTitle(AppLocalization.string("分享"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .foregroundStyle(AssetTheme.textSecondary)
                    .accessibilityLabel(AppLocalization.string("关闭"))
                }
            }
            .safeAreaInset(edge: .bottom) {
                if posterImage != nil {
                    Button {
                        showsShareSheet = true
                    } label: {
                        Label(AppLocalization.string("分享海报"), systemImage: "square.and.arrow.up")
                            .font(AppTypography.bodyStrong)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AssetTheme.background)
                    .background(AssetTheme.gold, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                    .background(.ultraThinMaterial)
                }
            }
        }
        .task {
            await generatePosterIfNeeded()
        }
        .sheet(isPresented: $showsShareSheet) {
            if let posterImage {
                ActivityShareSheet(items: [posterImage])
                    .presentationDetents([.medium, .large])
            }
        }
        .alert(AppLocalization.string("海报生成失败"), isPresented: Binding(
            get: { errorMessage != nil },
            set: { isPresented in
                if !isPresented { errorMessage = nil }
            }
        )) {
            Button(AppLocalization.string("知道了"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @MainActor
    private func generatePosterIfNeeded() async {
        guard posterImage == nil, !isGenerating else { return }
        isGenerating = true
        await Task.yield()
        posterImage = BacktestSharePosterRenderer.image(
            title: title,
            report: report,
            comparisonSeries: comparisonSeries
        )
        isGenerating = false

        if posterImage == nil {
            errorMessage = AppLocalization.string("无法生成分享图片，请稍后重试。")
        }
    }
}

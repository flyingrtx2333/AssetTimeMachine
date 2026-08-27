import SwiftUI
import UIKit
import WidgetKit

private struct AssetWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: AssetWidgetSnapshot
}

private struct AssetWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> AssetWidgetEntry {
        AssetWidgetEntry(date: .now, snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (AssetWidgetEntry) -> Void) {
        let snapshot = context.isPreview
            ? AssetWidgetSnapshot.preview
            : AssetWidgetSnapshotStore.load() ?? .empty
        completion(AssetWidgetEntry(date: .now, snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AssetWidgetEntry>) -> Void) {
        let snapshot = AssetWidgetSnapshotStore.load() ?? .empty
        let entry = AssetWidgetEntry(date: snapshot.updatedAt, snapshot: snapshot)
        let nextRefresh = Calendar.current.date(byAdding: .hour, value: 1, to: .now) ?? .now.addingTimeInterval(3600)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }
}

private enum AssetWidgetPalette {
    static let background = adaptive(AssetColorPalette.background)
    static let backgroundRaised = adaptive(AssetColorPalette.surfaceRaised)
    static let textPrimary = adaptive(AssetColorPalette.textPrimary)
    static let textSecondary = adaptive(AssetColorPalette.textSecondary)
    static let gold = adaptive(AssetColorPalette.gold)
    static let goldSoft = adaptive(AssetColorPalette.goldSoft)
    static let positive = adaptive(AssetColorPalette.positive)
    static let negative = adaptive(AssetColorPalette.negative)
    static let track = adaptive(AssetColorPalette.overlayStrong)
    static let divider = adaptive(AssetColorPalette.border)

    static let backgroundGradient = LinearGradient(
        colors: [backgroundRaised, background],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let goldGradient = LinearGradient(
        colors: [gold, goldSoft],
        startPoint: .leading,
        endPoint: .trailing
    )

    private static func adaptive(_ token: AssetAdaptiveColorToken) -> Color {
        Color(uiColor: UIColor { traits in
            uiColor(
                traits.userInterfaceStyle == .dark
                    ? token.darkGold
                    : token.daylightGold
            )
        })
    }

    private static func uiColor(_ components: AssetRGBA) -> UIColor {
        UIColor(
            red: CGFloat(components.red),
            green: CGFloat(components.green),
            blue: CGFloat(components.blue),
            alpha: CGFloat(components.alpha)
        )
    }
}

private extension AssetWidgetTheme {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .darkGold: .dark
        case .daylightGold: .light
        }
    }
}

private enum AssetWidgetLanguage: Equatable {
    case simplifiedChinese
    case traditionalChinese
    case english

    init(identifier: String) {
        let resolved = identifier == "system"
            ? Locale.preferredLanguages.first ?? Locale.current.identifier
            : identifier
        if resolved.lowercased().hasPrefix("zh-hant") {
            self = .traditionalChinese
        } else if resolved.lowercased().hasPrefix("zh") {
            self = .simplifiedChinese
        } else {
            self = .english
        }
    }

    var appName: String {
        switch self {
        case .simplifiedChinese: "资产时光机"
        case .traditionalChinese: "資產時光機"
        case .english: "Asset Time Machine"
        }
    }

    var freedom: String {
        switch self {
        case .simplifiedChinese: "财务自由"
        case .traditionalChinese: "財務自由"
        case .english: "Freedom"
        }
    }

    var surplusProgress: String {
        switch self {
        case .simplifiedChinese: "结余进度"
        case .traditionalChinese: "結餘進度"
        case .english: "Surplus"
        }
    }

    var yearToDateSurplus: String {
        switch self {
        case .simplifiedChinese: "年初至今结余"
        case .traditionalChinese: "年初至今結餘"
        case .english: "YTD surplus"
        }
    }

    var annualTarget: String {
        switch self {
        case .simplifiedChinese: "全年预计"
        case .traditionalChinese: "全年預計"
        case .english: "Annual target"
        }
    }

    var assetTrend: String {
        switch self {
        case .simplifiedChinese: "资产趋势"
        case .traditionalChinese: "資產趨勢"
        case .english: "Asset trend"
        }
    }

    var lastThirtyDays: String {
        switch self {
        case .simplifiedChinese, .traditionalChinese: "近 30 日"
        case .english: "Last 30 days"
        }
    }

    var openAppToUpdate: String {
        switch self {
        case .simplifiedChinese: "打开 App 更新"
        case .traditionalChinese: "打開 App 更新"
        case .english: "Open app to update"
        }
    }

    func freedomStatus(_ snapshot: AssetWidgetSnapshot) -> String {
        switch snapshot.freedomStatus {
        case .alreadyFree:
            switch self {
            case .simplifiedChinese: return "已实现"
            case .traditionalChinese: return "已實現"
            case .english: return "Achieved"
            }
        case .projected:
            guard let months = snapshot.freedomMonths else { return "--" }
            let years = months / 12
            let remainingMonths = months % 12
            switch self {
            case .simplifiedChinese:
                if years > 0, remainingMonths > 0 { return "约 \(years) 年 \(remainingMonths) 月" }
                if years > 0 { return "约 \(years) 年" }
                return "约 \(remainingMonths) 月"
            case .traditionalChinese:
                if years > 0, remainingMonths > 0 { return "約 \(years) 年 \(remainingMonths) 月" }
                if years > 0 { return "約 \(years) 年" }
                return "約 \(remainingMonths) 月"
            case .english:
                if years > 0, remainingMonths > 0 { return "~\(years)y \(remainingMonths)m" }
                if years > 0 { return "~\(years)y" }
                return "~\(remainingMonths)m"
            }
        case .unreachable:
            switch self {
            case .simplifiedChinese: return "当前不可达"
            case .traditionalChinese: return "目前不可達"
            case .english: return "Not projected"
            }
        case .unavailable:
            return "--"
        }
    }
}

private enum AssetWidgetFormat {
    static func percent(_ value: Double, fractionDigits: Int = 0) -> String {
        value.formatted(
            .percent
                .precision(.fractionLength(fractionDigits))
                .rounded(rule: .toNearestOrAwayFromZero)
        )
    }

    static func signedPercent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "--" }
        let valueText = percent(abs(value), fractionDigits: 2)
        return value >= 0 ? "+\(valueText)" : "−\(valueText)"
    }

    static func fullCurrency(_ value: Double?, visible: Bool) -> String {
        guard visible else { return "••••••" }
        guard let value, value.isFinite else { return "--" }
        return value.formatted(
            .currency(code: "CNY")
                .precision(.fractionLength(0))
                .rounded(rule: .toNearestOrAwayFromZero)
        )
    }

    static func compactCurrency(
        _ value: Double?,
        visible: Bool,
        language: AssetWidgetLanguage
    ) -> String {
        guard visible else { return "••••" }
        guard let value, value.isFinite else { return "--" }

        let absoluteValue = abs(value)
        let sign = value < 0 ? "−" : ""
        let formatter = NumberFormatter()
        formatter.maximumFractionDigits = 1
        formatter.minimumFractionDigits = 0
        formatter.numberStyle = .decimal

        func rendered(_ divisor: Double, suffix: String) -> String {
            let number = formatter.string(from: NSNumber(value: absoluteValue / divisor)) ?? "0"
            return "\(sign)¥\(number)\(suffix)"
        }

        switch language {
        case .simplifiedChinese, .traditionalChinese:
            let hundredMillionSuffix = language == .traditionalChinese ? "億" : "亿"
            let tenThousandSuffix = language == .traditionalChinese ? "萬" : "万"
            if absoluteValue >= 100_000_000 { return rendered(100_000_000, suffix: hundredMillionSuffix) }
            if absoluteValue >= 10_000 { return rendered(10_000, suffix: tenThousandSuffix) }
        case .english:
            if absoluteValue >= 1_000_000_000 { return rendered(1_000_000_000, suffix: "B") }
            if absoluteValue >= 1_000_000 { return rendered(1_000_000, suffix: "M") }
            if absoluteValue >= 1_000 { return rendered(1_000, suffix: "K") }
        }
        return fullCurrency(value, visible: visible)
    }
}

private struct AssetWidgetEmptyState: View {
    let language: AssetWidgetLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(AssetWidgetPalette.goldSoft)
            Spacer(minLength: 2)
            Text(language.appName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AssetWidgetPalette.textPrimary)
            Text(language.openAppToUpdate)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AssetWidgetPalette.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

private struct AssetWidgetSurface<Content: View>: View {
    @Environment(\.colorScheme) private var systemColorScheme
    let snapshot: AssetWidgetSnapshot
    let language: AssetWidgetLanguage
    @ViewBuilder let content: Content

    init(
        snapshot: AssetWidgetSnapshot,
        language: AssetWidgetLanguage,
        @ViewBuilder content: () -> Content
    ) {
        self.snapshot = snapshot
        self.language = language
        self.content = content()
    }

    var body: some View {
        Group {
            if snapshot.hasPortfolioData {
                content
            } else {
                AssetWidgetEmptyState(language: language)
            }
        }
        .containerBackground(for: .widget) {
            AssetWidgetPalette.backgroundGradient
        }
        .environment(\.colorScheme, snapshot.theme.colorScheme ?? systemColorScheme)
    }
}

private struct WidgetProgressBar: View {
    let progress: Double
    var height: CGFloat = 7

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(AssetWidgetPalette.track)
                Capsule()
                    .fill(AssetWidgetPalette.goldGradient)
                    .frame(width: max(geometry.size.width * min(max(progress, 0), 1), progress > 0 ? 4 : 0))
            }
        }
        .frame(height: height)
    }
}

private struct WidgetRing: View {
    let progress: Double
    let percentageSize: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(AssetWidgetPalette.track, style: StrokeStyle(lineWidth: 10, lineCap: .round))
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(
                    AssetWidgetPalette.goldGradient,
                    style: StrokeStyle(lineWidth: 10, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            Text(AssetWidgetFormat.percent(progress))
                .font(.system(size: percentageSize, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(AssetWidgetPalette.textPrimary)
                .minimumScaleFactor(0.7)
        }
    }
}

private struct FreedomRingsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: AssetWidgetEntry

    private var language: AssetWidgetLanguage {
        AssetWidgetLanguage(identifier: entry.snapshot.languageIdentifier)
    }

    var body: some View {
        AssetWidgetSurface(snapshot: entry.snapshot, language: language) {
            if family == .systemMedium {
                mediumContent
            } else {
                smallContent
            }
        }
    }

    private var smallContent: some View {
        VStack(spacing: 7) {
            Text(language.freedom)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AssetWidgetPalette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

            WidgetRing(progress: entry.snapshot.freedomProgress, percentageSize: 30)
                .frame(width: 88, height: 88)

            Text(language.freedomStatus(entry.snapshot))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AssetWidgetPalette.goldSoft)
                .lineLimit(1)
        }
    }

    private var mediumContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(language.appName, systemImage: "clock.arrow.circlepath")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AssetWidgetPalette.goldSoft)

            HStack(spacing: 16) {
                ringMetric(
                    title: language.surplusProgress,
                    progress: entry.snapshot.surplusProgress,
                    footer: surplusFooter
                )

                Rectangle()
                    .fill(AssetWidgetPalette.divider)
                    .frame(width: 1, height: 96)

                ringMetric(
                    title: language.freedom,
                    progress: entry.snapshot.freedomProgress,
                    footer: language.freedomStatus(entry.snapshot)
                )
            }
        }
    }

    private var surplusFooter: String {
        let actual = AssetWidgetFormat.compactCurrency(
            entry.snapshot.surplusActual,
            visible: entry.snapshot.amountsVisible,
            language: language
        )
        let target = AssetWidgetFormat.compactCurrency(
            entry.snapshot.surplusTarget,
            visible: entry.snapshot.amountsVisible,
            language: language
        )
        return "\(actual) / \(target)"
    }

    private func ringMetric(title: String, progress: Double, footer: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AssetWidgetPalette.textPrimary)
                .lineLimit(1)
            WidgetRing(progress: progress, percentageSize: 24)
                .frame(width: 78, height: 78)
            Text(footer)
                .font(.system(size: 9.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(AssetWidgetPalette.goldSoft)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .privacySensitive()
        }
        .frame(maxWidth: .infinity)
    }
}

private struct FinancialProgressWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: AssetWidgetEntry

    private var language: AssetWidgetLanguage {
        AssetWidgetLanguage(identifier: entry.snapshot.languageIdentifier)
    }

    var body: some View {
        AssetWidgetSurface(snapshot: entry.snapshot, language: language) {
            if family == .systemMedium { mediumContent } else { smallContent }
        }
    }

    private var smallContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(language.surplusProgress)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AssetWidgetPalette.textPrimary)
            Text(AssetWidgetFormat.percent(entry.snapshot.surplusProgress))
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(AssetWidgetPalette.goldSoft)
            WidgetProgressBar(progress: entry.snapshot.surplusProgress, height: 8)
            Text(surplusComparison)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(AssetWidgetPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
                .privacySensitive()
            Spacer(minLength: 0)
            HStack {
                Text(language.freedom)
                    .foregroundStyle(AssetWidgetPalette.textSecondary)
                Spacer(minLength: 4)
                Text(AssetWidgetFormat.percent(entry.snapshot.freedomProgress))
                    .foregroundStyle(AssetWidgetPalette.textPrimary)
            }
            .font(.system(size: 11, weight: .semibold))
        }
    }

    private var mediumContent: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(language.appName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AssetWidgetPalette.textPrimary)
                Spacer()
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AssetWidgetPalette.goldSoft)
            }

            HStack(alignment: .lastTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(language.yearToDateSurplus)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(AssetWidgetPalette.textSecondary)
                    Text(AssetWidgetFormat.fullCurrency(
                        entry.snapshot.surplusActual,
                        visible: entry.snapshot.amountsVisible
                    ))
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(AssetWidgetPalette.goldSoft)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .privacySensitive()
                }
                Spacer(minLength: 6)
                Text(AssetWidgetFormat.percent(entry.snapshot.surplusProgress))
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(AssetWidgetPalette.goldSoft)
            }

            WidgetProgressBar(progress: entry.snapshot.surplusProgress, height: 7)

            Text("\(language.annualTarget)  \(AssetWidgetFormat.fullCurrency(entry.snapshot.surplusTarget, visible: entry.snapshot.amountsVisible))")
                .font(.system(size: 9.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(AssetWidgetPalette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .privacySensitive()

            Rectangle()
                .fill(AssetWidgetPalette.divider)
                .frame(height: 1)

            HStack(spacing: 9) {
                Text(language.freedom)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AssetWidgetPalette.textSecondary)
                WidgetProgressBar(progress: entry.snapshot.freedomProgress, height: 6)
                Text(AssetWidgetFormat.percent(entry.snapshot.freedomProgress))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(AssetWidgetPalette.goldSoft)
                Text(language.freedomStatus(entry.snapshot))
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(AssetWidgetPalette.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    private var surplusComparison: String {
        let actual = AssetWidgetFormat.compactCurrency(
            entry.snapshot.surplusActual,
            visible: entry.snapshot.amountsVisible,
            language: language
        )
        let target = AssetWidgetFormat.compactCurrency(
            entry.snapshot.surplusTarget,
            visible: entry.snapshot.amountsVisible,
            language: language
        )
        return "\(actual) / \(target)"
    }
}

private struct SparklineShape: Shape {
    let values: [Double]

    func path(in rect: CGRect) -> Path {
        guard values.count >= 2,
              let minimum = values.min(),
              let maximum = values.max() else { return Path() }
        let range = max(maximum - minimum, max(abs(maximum) * 0.005, 1))
        var path = Path()
        for (index, value) in values.enumerated() {
            let x = rect.minX + rect.width * CGFloat(index) / CGFloat(values.count - 1)
            let normalized = (value - minimum) / range
            let y = rect.maxY - rect.height * CGFloat(normalized * 0.82 + 0.09)
            let point = CGPoint(x: x, y: y)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}

private struct SparklineAreaShape: Shape {
    let values: [Double]

    func path(in rect: CGRect) -> Path {
        guard values.count >= 2 else { return Path() }
        var path = SparklineShape(values: values).path(in: rect)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct AssetSparkline: View {
    let points: [AssetWidgetTrendPoint]

    private var values: [Double] { points.map(\.value) }

    var body: some View {
        ZStack {
            SparklineAreaShape(values: values)
                .fill(
                    LinearGradient(
                        colors: [AssetWidgetPalette.gold.opacity(0.26), AssetWidgetPalette.gold.opacity(0.01)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            SparklineShape(values: values)
                .stroke(
                    AssetWidgetPalette.goldGradient,
                    style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)
                )
        }
    }
}

private struct AssetTrendWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: AssetWidgetEntry

    private var language: AssetWidgetLanguage {
        AssetWidgetLanguage(identifier: entry.snapshot.languageIdentifier)
    }

    private var changeColor: Color {
        guard let change = entry.snapshot.thirtyDayChange else { return AssetWidgetPalette.textSecondary }
        return change >= 0 ? AssetWidgetPalette.positive : AssetWidgetPalette.negative
    }

    var body: some View {
        AssetWidgetSurface(snapshot: entry.snapshot, language: language) {
            if family == .systemMedium { mediumContent } else { smallContent }
        }
    }

    private var smallContent: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(language.assetTrend)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AssetWidgetPalette.textPrimary)
            Text(AssetWidgetFormat.signedPercent(entry.snapshot.thirtyDayChange))
                .font(.system(size: 29, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(changeColor)
            AssetSparkline(points: entry.snapshot.trendPoints)
                .frame(maxHeight: .infinity)
            HStack(spacing: 7) {
                metricLabel(language.surplusProgress, progress: entry.snapshot.surplusProgress)
                Rectangle().fill(AssetWidgetPalette.divider).frame(width: 1, height: 13)
                metricLabel(language.freedom, progress: entry.snapshot.freedomProgress)
            }
        }
    }

    private var mediumContent: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(language.appName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AssetWidgetPalette.textSecondary)
                    Text(AssetWidgetFormat.compactCurrency(
                        entry.snapshot.totalAssets,
                        visible: entry.snapshot.amountsVisible,
                        language: language
                    ))
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(AssetWidgetPalette.textPrimary)
                    .privacySensitive()
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(language.lastThirtyDays)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(AssetWidgetPalette.textSecondary)
                    Text(AssetWidgetFormat.signedPercent(entry.snapshot.thirtyDayChange))
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(changeColor)
                }
            }

            AssetSparkline(points: entry.snapshot.trendPoints)
                .frame(maxHeight: .infinity)

            HStack(spacing: 18) {
                bottomProgress(title: language.surplusProgress, progress: entry.snapshot.surplusProgress, footer: nil)
                bottomProgress(
                    title: language.freedom,
                    progress: entry.snapshot.freedomProgress,
                    footer: language.freedomStatus(entry.snapshot)
                )
            }
        }
    }

    private func metricLabel(_ title: String, progress: Double) -> some View {
        HStack(spacing: 3) {
            Text(title)
                .foregroundStyle(AssetWidgetPalette.textSecondary)
            Text(AssetWidgetFormat.percent(progress))
                .foregroundStyle(AssetWidgetPalette.textPrimary)
        }
        .font(.system(size: 9.5, weight: .semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.72)
    }

    private func bottomProgress(title: String, progress: Double, footer: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text(title)
                    .foregroundStyle(AssetWidgetPalette.textSecondary)
                Text(AssetWidgetFormat.percent(progress))
                    .foregroundStyle(AssetWidgetPalette.goldSoft)
                if let footer {
                    Spacer(minLength: 2)
                    Text(footer)
                        .foregroundStyle(AssetWidgetPalette.textSecondary)
                }
            }
            .font(.system(size: 9.5, weight: .semibold))
            .lineLimit(1)
            WidgetProgressBar(progress: progress, height: 5)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct FreedomRingsWidget: Widget {
    let kind = "AssetTimeMachine.FreedomRings"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AssetWidgetProvider()) { entry in
            FreedomRingsWidgetView(entry: entry)
        }
        .configurationDisplayName("双环进度")
        .description("并列查看结余与财务自由进度。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct FinancialProgressWidget: Widget {
    let kind = "AssetTimeMachine.FinancialProgress"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AssetWidgetProvider()) { entry in
            FinancialProgressWidgetView(entry: entry)
        }
        .configurationDisplayName("财务进度")
        .description("查看结余金额、年度目标与财务自由进度。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct AssetTrendWidget: Widget {
    let kind = "AssetTimeMachine.AssetTrend"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AssetWidgetProvider()) { entry in
            AssetTrendWidgetView(entry: entry)
        }
        .configurationDisplayName("资产趋势")
        .description("查看近 30 日资产趋势和关键财务进度。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct AssetTimeMachineWidgetBundle: WidgetBundle {
    var body: some Widget {
        FreedomRingsWidget()
        FinancialProgressWidget()
        AssetTrendWidget()
    }
}

#Preview("双环 · 小号", as: .systemSmall) {
    FreedomRingsWidget()
} timeline: {
    AssetWidgetEntry(date: .now, snapshot: .preview)
}

#Preview("双进度 · 中号", as: .systemMedium) {
    FinancialProgressWidget()
} timeline: {
    AssetWidgetEntry(date: .now, snapshot: .preview)
}

#Preview("趋势 · 中号", as: .systemMedium) {
    AssetTrendWidget()
} timeline: {
    AssetWidgetEntry(date: .now, snapshot: .preview)
}

#Preview("趋势 · 日间白金", as: .systemMedium) {
    AssetTrendWidget()
} timeline: {
    AssetWidgetEntry(date: .now, snapshot: .preview(theme: .daylightGold))
}

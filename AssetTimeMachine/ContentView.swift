import SwiftUI
import SwiftData

private enum AppTab: Hashable {
    case dashboard
    case snapshots
    case timeMachine
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var marketStore = RemoteMarketStore()
    @State private var selectedTab: AppTab = ProcessInfo.processInfo.arguments.contains("-openSnapshotsTab") ? .snapshots : .dashboard

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView(marketStore: marketStore)
                .tabItem {
                    Label("首页", systemImage: "house")
                }
                .tag(AppTab.dashboard)

            SnapshotListView()
                .tabItem {
                    Label("记录", systemImage: "square.and.pencil")
                }
                .tag(AppTab.snapshots)

            TimeMachineView()
                .tabItem {
                    Label("时光机", systemImage: "clock.arrow.circlepath")
                }
                .tag(AppTab.timeMachine)
        }
        .tint(AssetTheme.gold)
        .task {
            try? SeedDataService.seedDefaultCategoriesIfNeeded(in: modelContext)
            await marketStore.refresh()
        }
    }
}

private struct DashboardView: View {
    @ObservedObject var marketStore: RemoteMarketStore
    @Query(sort: \AssetSnapshot.date, order: .reverse) private var snapshots: [AssetSnapshot]
    @Query private var entries: [AssetEntry]

    private var latestSnapshot: AssetSnapshot? { snapshots.first }

    private var totalAssets: Double {
        entries
            .filter { ($0.item?.category?.group ?? .financial) != .liability }
            .reduce(0) { $0 + $1.resolvedAmount }
    }

    private var totalLiabilities: Double {
        entries
            .filter { ($0.item?.category?.group ?? .financial) == .liability }
            .reduce(0) { $0 + $1.resolvedAmount }
    }

    private var netAssets: Double {
        totalAssets - totalLiabilities
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        ATMHeader(title: "资产时光机") {
                            Button {
                                Task { await marketStore.refresh() }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(AssetTheme.gold)
                                    .frame(width: 44, height: 44)
                                    .background(.white.opacity(0.04), in: Circle())
                                    .overlay(Circle().stroke(AssetTheme.border, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }

                        heroCard

                        HStack(spacing: 12) {
                            MetricTile(
                                title: "总资产",
                                value: totalAssets.currencyString(),
                                accent: AssetTheme.gold
                            )

                            MetricTile(
                                title: "总负债",
                                value: totalLiabilities.currencyString(),
                                accent: AssetTheme.negative
                            )
                        }

                        marketSection
                        recentSection
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 120)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    GoldChip(text: "净资产（元）")

                    Text(netAssets.currencyString())
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundStyle(AssetTheme.textPrimary)

                    HStack(spacing: 10) {
                        InlineStat(text: "记录天数 \(snapshots.count)", color: AssetTheme.textSecondary)
                        InlineStat(text: latestSnapshot.map { "最近 \($0.date.shortDateString)" } ?? "还没有快照", color: AssetTheme.goldSoft)
                    }
                }

                Spacer(minLength: 16)

                SparklineCard(points: [0.14, 0.18, 0.22, 0.21, 0.28, 0.32, 0.30, 0.38, 0.43])
                    .frame(width: 132, height: 84)
            }

            Divider().overlay(AssetTheme.border)

            HStack(spacing: 12) {
                CompactStat(title: "资产", value: totalAssets.currencyString(), accent: AssetTheme.gold)
                CompactStat(title: "负债", value: totalLiabilities.currencyString(), accent: AssetTheme.negative)
                CompactStat(title: "条目", value: "\(entries.count)", accent: AssetTheme.accentBlue)
            }
        }
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(AssetTheme.heroGradient)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(AssetTheme.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 28, x: 0, y: 16)
    }

    private var marketSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(title: "市场锚点")

            Group {
                if let overview = marketStore.overview {
                    VStack(spacing: 0) {
                        ForEach(Array(overview.markets.enumerated()), id: \.element.id) { index, market in
                            MarketPriceRow(market: market)

                            if index < overview.markets.count - 1 {
                                Divider().overlay(AssetTheme.border.opacity(0.6))
                            }
                        }

                    }
                    .atmCardStyle()
                } else if marketStore.isLoading {
                    VStack(spacing: 14) {
                        SkeletonLine(width: 130)
                        SkeletonLine(width: 240)
                        SkeletonLine(width: 210)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .atmCardStyle()
                } else {
                    EmptyStateCard(
                        title: marketStore.errorMessage ?? "行情暂不可用",
                        systemImage: "wifi.exclamationmark"
                    )
                }
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(title: "最近记录")

            if let latestSnapshot {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(latestSnapshot.date.longDateString)
                            .font(.headline)
                            .foregroundStyle(AssetTheme.textPrimary)
                        Spacer()
                        GoldChip(text: "\(latestSnapshot.entries.count) 项")
                    }

                    Text("\(latestSnapshot.entries.count) 项")
                        .font(.subheadline)
                        .foregroundStyle(AssetTheme.textSecondary)
                }
                .atmCardStyle()
            } else {
                EmptyStateCard(
                    title: "暂无记录",
                    systemImage: "tray"
                )
            }
        }
    }
}

private struct SnapshotListView: View {
    @Query(sort: \AssetSnapshot.date, order: .reverse) private var snapshots: [AssetSnapshot]

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        ATMHeader(title: "每日记录")

                        if snapshots.isEmpty {
                            EmptyStateCard(
                                title: "暂无记录",
                                systemImage: "calendar.badge.plus"
                            )
                        } else {
                            ForEach(snapshots) { snapshot in
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack {
                                        Text(snapshot.date.longDateString)
                                            .font(.headline)
                                            .foregroundStyle(AssetTheme.textPrimary)
                                        Spacer()
                                        GoldChip(text: "\(snapshot.entries.count) 条")
                                    }

                                    Text("\(snapshot.entries.count) 条")
                                        .font(.subheadline)
                                        .foregroundStyle(AssetTheme.textSecondary)
                                }
                                .atmCardStyle()
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 120)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

private struct TimeMachineView: View {
    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        ATMHeader(title: "时光机")

                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                                Text("2026年4月26日")
                                    .font(.headline)
                                    .foregroundStyle(AssetTheme.textPrimary)
                                Spacer()
                                GoldChip(text: "预览态")
                            }

                            Text("1,158,267.30")
                                .font(.system(size: 34, weight: .bold, design: .rounded))
                                .foregroundStyle(AssetTheme.goldSoft)

                            HStack(spacing: 12) {
                                MetricTile(title: "较昨日", value: "-3,247.10", detail: "-0.28%", accent: AssetTheme.negative)
                                MetricTile(title: "较年初", value: "+158,267.30", detail: "+15.81%", accent: AssetTheme.positive)
                            }
                        }
                        .atmCardStyle()

                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 120)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

private struct APIDocumentationView: View {
    @ObservedObject var marketStore: RemoteMarketStore

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        ATMHeader(title: "接口文档", subtitle: "给 App 自己看的，也给未来的分析逻辑备用。") {
                            Button {
                                Task { await marketStore.refresh() }
                            } label: {
                                GoldChip(text: "刷新")
                            }
                            .buttonStyle(.plain)
                        }

                        VStack(alignment: .leading, spacing: 14) {
                            Text("Base URL")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AssetTheme.textSecondary)

                            Text(RemoteMarketClient.baseURL.absoluteString)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(AssetTheme.textPrimary)
                                .textSelection(.enabled)
                        }
                        .atmCardStyle()

                        ForEach(RemoteMarketClient.endpointDocs) { endpoint in
                            EndpointCard(endpoint: endpoint, market: endpoint.symbol.flatMap { marketStore.market(for: $0) })
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 120)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

private struct ATMHeader<Trailing: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder var trailing: Trailing

    init(title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(.white.opacity(0.04))
                            .frame(width: 40, height: 40)
                        Image(systemName: "hourglass")
                            .foregroundStyle(AssetTheme.gold)
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(AssetTheme.border, lineWidth: 1)
                    )

                    Text(title)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(AssetTheme.textPrimary)
                }

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(AssetTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
            trailing
        }
    }
}

private struct SectionTitle: View {
    let title: String
    let subtitle: String?

    init(title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(AssetTheme.textPrimary)

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(AssetTheme.textSecondary)
            }
        }
    }
}

private struct GoldChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(AssetTheme.goldSoft)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(AssetTheme.gold.opacity(0.12), in: Capsule())
            .overlay(Capsule().stroke(AssetTheme.border, lineWidth: 1))
    }
}

private struct InlineStat: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Text(text)
                .font(.footnote)
                .foregroundStyle(color)
        }
    }
}

private struct CompactStat: View {
    let title: String
    let value: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(AssetTheme.textSecondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AssetTheme.textPrimary)
            RoundedRectangle(cornerRadius: 999)
                .fill(accent)
                .frame(width: 28, height: 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AssetTheme.border.opacity(0.8), lineWidth: 1)
        )
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    let detail: String?
    let accent: Color

    init(title: String, value: String, detail: String? = nil, accent: Color) {
        self.title = title
        self.value = value
        self.detail = detail
        self.accent = accent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption)
                .foregroundStyle(AssetTheme.textSecondary)
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(AssetTheme.textPrimary)
                .minimumScaleFactor(0.72)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .atmCardStyle()
    }
}

private struct MarketPriceRow: View {
    let market: PublicMarketPrice

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)

            Text(displayName)
                .font(.title3.weight(.semibold))
                .foregroundStyle(AssetTheme.textPrimary)

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                Text(market.price.formatted(.number.precision(.fractionLength(2))))
                    .font(.title2.weight(.bold))
                    .foregroundStyle(AssetTheme.textPrimary)
                Text(market.currency)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AssetTheme.goldSoft)
            }
        }
        .padding(.vertical, 16)
    }

    private var displayName: String {
        switch market.symbol {
        case "gold": return "黄金"
        case "btc": return "BTC"
        case "nasdaq": return "纳指锚点"
        default: return market.symbol.uppercased()
        }
    }

    private var color: Color {
        switch market.symbol {
        case "gold": return AssetTheme.gold
        case "btc": return AssetTheme.accentOrange
        case "nasdaq": return AssetTheme.accentBlue
        default: return AssetTheme.textSecondary
        }
    }
}

private struct EndpointCard: View {
    let endpoint: MarketEndpointDoc
    let market: PublicMarketPrice?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(endpoint.title)
                        .font(.headline)
                        .foregroundStyle(AssetTheme.textPrimary)

                    Text(endpoint.path)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(AssetTheme.goldSoft)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 12)
                GoldChip(text: "GET")
            }

            Text(endpoint.description)
                .font(.subheadline)
                .foregroundStyle(AssetTheme.textSecondary)

            if let market {
                HStack(spacing: 12) {
                    Label(market.price.formatted(.number.precision(.fractionLength(2))), systemImage: "waveform.path.ecg")
                    Text(market.currency)
                    Spacer()
                    Text(market.fetchedAt.formatted(date: .omitted, time: .shortened))
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AssetTheme.goldSoft)
                .padding(12)
                .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .atmCardStyle()
    }
}

private struct CapabilityRow: View {
    let title: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 28)
            Text(title)
                .foregroundStyle(AssetTheme.textPrimary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AssetTheme.textSecondary)
        }
        .padding(14)
        .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AssetTheme.border.opacity(0.75), lineWidth: 1)
        )
    }
}

private struct EmptyStateCard: View {
    let title: String
    let message: String?
    let systemImage: String

    init(title: String, message: String? = nil, systemImage: String) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(AssetTheme.gold)

            VStack(spacing: 8) {
                Text(title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(AssetTheme.textPrimary)

                if let message, !message.isEmpty {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(AssetTheme.textSecondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .atmCardStyle()
    }
}

private struct SkeletonLine: View {
    let width: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 999, style: .continuous)
            .fill(.white.opacity(0.08))
            .frame(width: width, height: 14)
    }
}

private struct SparklineCard: View {
    let points: [CGFloat]

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.white.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(AssetTheme.border.opacity(0.8), lineWidth: 1)
                )

            ChartLine(points: points)
                .stroke(AssetTheme.goldSoft, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                .padding(14)

            ChartLine(points: points)
                .fill(
                    LinearGradient(
                        colors: [AssetTheme.gold.opacity(0.24), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .padding(14)
                .mask(
                    VStack(spacing: 0) {
                        Spacer()
                        Rectangle().frame(height: 40)
                    }
                )
        }
    }
}

private struct ChartLine: Shape {
    let points: [CGFloat]

    func path(in rect: CGRect) -> Path {
        guard points.count > 1 else { return Path() }

        let stepX = rect.width / CGFloat(points.count - 1)
        let minY = points.min() ?? 0
        let maxY = points.max() ?? 1
        let range = max(maxY - minY, 0.001)

        var path = Path()
        for (index, point) in points.enumerated() {
            let x = CGFloat(index) * stepX
            let normalizedY = (point - minY) / range
            let y = rect.height - normalizedY * rect.height

            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
    }
}

private extension Double {
    func currencyString(code: String = "CNY") -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: NSNumber(value: self)) ?? String(format: "%.2f", self)
    }
}

private extension Date {
    var shortDateString: String {
        formatted(date: .abbreviated, time: .omitted)
    }

    var longDateString: String {
        formatted(date: .long, time: .omitted)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [AssetCategory.self, AssetItem.self, AssetSnapshot.self, AssetEntry.self], inMemory: true)
}

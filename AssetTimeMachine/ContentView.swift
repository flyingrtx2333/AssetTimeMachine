import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var marketStore = RemoteMarketStore()

    var body: some View {
        TabView {
            DashboardView(marketStore: marketStore)
                .tabItem {
                    Label("首页", systemImage: "chart.line.uptrend.xyaxis")
                }

            SnapshotListView()
                .tabItem {
                    Label("记录", systemImage: "calendar")
                }

            TimeMachineView()
                .tabItem {
                    Label("时光机", systemImage: "clock.arrow.circlepath")
                }

            APIDocumentationView(marketStore: marketStore)
                .tabItem {
                    Label("接口文档", systemImage: "book.pages")
                }
        }
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

    private var latestSnapshot: AssetSnapshot? {
        snapshots.first
    }

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
            List {
                Section("资产概览") {
                    SummaryRow(title: "总资产", value: totalAssets)
                    SummaryRow(title: "总负债", value: totalLiabilities)
                    SummaryRow(title: "净资产", value: netAssets, emphasize: true)
                }

                Section("市场锚点") {
                    if let overview = marketStore.overview {
                        ForEach(overview.markets) { market in
                            MarketPriceRow(market: market)
                        }

                        if let updateIntervalHours = overview.updateIntervalHours {
                            Label("服务端每 \(updateIntervalHours) 小时刷新一次数据库", systemImage: "clock.badge.checkmark")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else if marketStore.isLoading {
                        ProgressView("正在同步公共行情…")
                    } else {
                        ContentUnavailableView(
                            "还没拉到公共行情",
                            systemImage: "wifi.exclamationmark",
                            description: Text(marketStore.errorMessage ?? "可以稍后再试一次。")
                        )
                    }
                }

                Section("最近记录") {
                    if let latestSnapshot {
                        LabeledContent("最近日期", value: latestSnapshot.date.formatted(date: .abbreviated, time: .omitted))
                        LabeledContent("记录条目", value: "\(latestSnapshot.entries.count)")
                    } else {
                        ContentUnavailableView("还没有资产记录", systemImage: "tray", description: Text("接下来可以先创建资产分类和首日快照。"))
                    }
                }
            }
            .navigationTitle("资产时光机")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await marketStore.refresh() }
                    } label: {
                        Label("刷新行情", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
    }
}

private struct SnapshotListView: View {
    @Query(sort: \AssetSnapshot.date, order: .reverse) private var snapshots: [AssetSnapshot]

    var body: some View {
        NavigationStack {
            List {
                if snapshots.isEmpty {
                    ContentUnavailableView("还没有每日快照", systemImage: "calendar.badge.plus", description: Text("后面这里会做成每天继承前一天的快速记账入口。"))
                } else {
                    ForEach(snapshots) { snapshot in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(snapshot.date.formatted(date: .abbreviated, time: .omitted))
                                .font(.headline)
                            Text("共 \(snapshot.entries.count) 项")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("每日记录")
        }
    }
}

private struct TimeMachineView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("时光机") {
                    Label("按日期回看总资产、净资产和资产构成", systemImage: "clock")
                    Label("后续会补历史高点、回撤、阶段涨跌", systemImage: "mountain.2")
                }
            }
            .navigationTitle("时光机")
        }
    }
}

private struct APIDocumentationView: View {
    @ObservedObject var marketStore: RemoteMarketStore
    private let baseURL = RemoteMarketClient.baseURL.absoluteString

    var body: some View {
        NavigationStack {
            List {
                Section("公共行情接口") {
                    ForEach(RemoteMarketClient.endpointDocs) { endpoint in
                        APIDocRow(
                            title: endpoint.title,
                            method: "GET",
                            path: endpoint.path,
                            description: endpoint.description,
                            market: endpoint.symbol.flatMap { marketStore.market(for: $0) }
                        )
                    }
                }

                Section("说明") {
                    LabeledContent("Base URL", value: baseURL)
                    Text("这些接口默认给资产时光机后续做锚点分析和调试联调用，不需要登录。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if let errorMessage = marketStore.errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("接口文档")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await marketStore.refresh() }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
    }
}

private struct APIDocRow: View {
    let title: String
    let method: String
    let path: String
    let description: String
    let market: PublicMarketPrice?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Text(method)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.blue.opacity(0.12), in: Capsule())
            }

            Text(path)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)

            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let market {
                VStack(alignment: .leading, spacing: 4) {
                    Text("当前值: \(market.price.formatted(.number.precision(.fractionLength(2)))) \(market.currency) / \(market.unit)")
                    Text("来源: \(market.source), 更新时间: \(market.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct MarketPriceRow: View {
    let market: PublicMarketPrice

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(marketDisplayName)
                Spacer()
                Text("\(market.price.formatted(.number.precision(.fractionLength(2)))) \(market.currency)")
                    .fontWeight(.semibold)
            }

            Text("\(market.unit) · \(market.source) · \(market.fetchedAt.formatted(date: .omitted, time: .shortened))")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var marketDisplayName: String {
        switch market.symbol {
        case "gold":
            return "黄金"
        case "btc":
            return "BTC"
        case "nasdaq":
            return "纳指锚点"
        default:
            return market.symbol
        }
    }
}

private struct SummaryRow: View {
    let title: String
    let value: Double
    var emphasize: Bool = false

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value, format: .currency(code: Locale.current.currency?.identifier ?? "CNY"))
                .fontWeight(emphasize ? .semibold : .regular)
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [AssetCategory.self, AssetItem.self, AssetSnapshot.self, AssetEntry.self], inMemory: true)
}

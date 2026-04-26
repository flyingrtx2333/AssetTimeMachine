import SwiftUI
import SwiftData

struct ContentView: View {
    var body: some View {
        TabView {
            DashboardView()
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
        }
    }
}

private struct DashboardView: View {
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

import AppKit
import AssetTimeMachineBacktestCore
import Charts
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct NativeQuantView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @ObservedObject var store: NativeQuantStore
    @State private var pendingDelete: BacktestRecord?
    @State private var search = ""
    @State private var historyKind = "all"
    private var reducesMotion: Bool { reducedMotion || NativeHomeStyle.previewReduced }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header.padding(.bottom, NativeStyle.Space.md)
                    .overlay(alignment: .bottom) { Rectangle().fill(NativePalette.line).frame(height: 0.5) }
                if let error = store.error {
                    HStack {
                        Text(error).foregroundStyle(AssetTheme.accentOrange).textSelection(.enabled)
                        Spacer()
                        Button { store.error = nil } label: { Image(systemName: "xmark") }.accessibilityLabel("关闭错误")
                    }.font(NativeStyle.FontRole.body).padding(.vertical, NativeStyle.Space.lg).transition(.opacity)
                }
                Group { switch store.route {
                case "configure": NativeQuantConfigurationView(store: store, market: store.market)
                case "result":
                    if let record = store.result {
                        NativeQuantResultView(record: record, restore: { store.restore(record) })
                    }
                case "records": recordList
                default: overview
                } }.id(store.route).padding(.top, NativeStyle.Layout.sectionGap).transition(NativeStyle.Motion.quantTransition(reducesMotion))
            }.padding(NativeStyle.Layout.pageInset)
        }
        .modifier(NativeWorkspaceSurface())
        .buttonStyle(NativeQuantFeedback(reduced: reducesMotion))
        .animation(NativeStyle.Motion.quant(reducesMotion), value: store.route)
        .animation(NativeStyle.Motion.quant(reducesMotion), value: store.records.map(\.id))
        .task {
            store.loadRecords(context)
            if !AppPreviewSession.isActive { await store.market.refreshAssetCatalogIfNeeded() }
        }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { notification in
            guard let saved = notification.object as? ModelContext, saved === context else { return }
            store.loadRecords(context)
        }
        .confirmationDialog("删除这条回测记录？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("删除", role: .destructive) {
                if let pendingDelete { store.delete(pendingDelete, context: context) }
                pendingDelete = nil
            }
        }
    }

    private var header: some View {
        HStack(spacing: NativeStyle.Space.md) {
            if store.route != "overview" {
                Button { store.route = "overview" } label: { Image(systemName: "arrow.left").frame(width: 26, height: 26) }
                    .accessibilityLabel("返回量化")
            }
            Text(title).font(NativeStyle.FontRole.pageTitle)
            Spacer()
            if store.route == "overview" {
                ForEach(Array(BacktestRecordKind.allCases.enumerated()), id: \.element.rawValue) { index, kind in
                    if index > 0 { Rectangle().fill(NativePalette.line).frame(width: 0.5, height: 18) }
                    entry(kind)
                }
            }
            if store.isWorking {
                ProgressView().controlSize(.small)
                Text(store.progress).font(NativeStyle.FontRole.caption).foregroundStyle(NativeHomeStyle.secondary)
                Button("取消") { store.cancel() }
            }
            if store.route != "records" && store.route != "overview" {
                Button { store.loadRecords(context); store.route = "records" } label: { Label("回测记录", systemImage: "clock.arrow.circlepath") }
                    .font(NativeStyle.FontRole.body)
            }
        }.frame(minHeight: 42)
    }
    private var title: String {
        switch store.route {
        case "configure": return store.config.kind.title
        case "result": return store.result?.subtitle.isEmpty == false ? store.result!.subtitle : "回测结果"
        case "records": return "回测记录"
        default: return "量化"
        }
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 0) {
            NativeQuantAdviceView(projection: store.advice, market: store.market)
            Color.clear.frame(height: NativeStyle.Layout.sectionGap)
            HStack {
                Text("最近回测").font(NativeStyle.FontRole.sectionTitle)
                Spacer()
                Button { store.loadRecords(context); store.route = "records" } label: {
                    HStack(spacing: 7) { Text("回测记录"); Image(systemName: "chevron.right").font(NativeStyle.FontRole.micro) }
                        .foregroundStyle(NativePalette.accent).frame(height: 28)
                }.font(NativeStyle.FontRole.body).accessibilityLabel("回测记录")
            }.padding(.bottom, NativeStyle.Space.md)
            Rectangle().fill(NativePalette.line).frame(height: 0.5)
            if store.records.isEmpty {
                Text("暂无回测记录").font(NativeStyle.FontRole.body).foregroundStyle(NativeHomeStyle.secondary).padding(.vertical, 18)
            } else {
                ForEach(Array(store.records.prefix(5))) { record in recordRow(record).transition(NativeStyle.Motion.quantTransition(reducesMotion)) }
            }
        }
    }
    private func entry(_ kind: BacktestRecordKind) -> some View {
        Button { store.show(kind) } label: {
            Text(kind.title).font(NativeStyle.FontRole.input).padding(.horizontal, NativeStyle.Space.sm).frame(height: NativeStyle.Control.height)
        }.accessibilityLabel(kind.title)
    }
    private var recordList: some View {
        VStack(spacing: NativeStyle.Space.lg) {
            HStack {
                TextField("搜索记录", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                Spacer()
                Picker("类型", selection: $historyKind) {
                    Text("全部").tag("all")
                    ForEach(BacktestRecordKind.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }.labelsHidden().frame(width: 130)
            }
            let records = store.records.filter { record in
                (historyKind == "all" || record.kindRawValue == historyKind)
                && (search.isEmpty || "\(record.title) \(record.subtitle) \(record.configSummary)".localizedCaseInsensitiveContains(search))
            }
            if records.isEmpty { Text("暂无记录").foregroundStyle(NativeHomeStyle.secondary).padding(36) }
            ForEach(records) { record in recordRow(record).transition(NativeStyle.Motion.quantTransition(reducesMotion)) }
        }
        .animation(NativeStyle.Motion.quant(reducesMotion), value: search)
        .animation(NativeStyle.Motion.quant(reducesMotion), value: historyKind)
    }
    private func recordRow(_ record: BacktestRecord) -> some View {
        HStack(spacing: 18) {
            Button {
                store.result = record; store.route = "result"
            } label: {
                ViewThatFits(in: .horizontal) {
                  HStack(spacing: NativeStyle.Space.lg) {
                    Text(record.subtitle.isEmpty ? record.title : record.subtitle).font(NativeStyle.FontRole.inputStrong).frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(NativeQuantFormat.date(record.startDate)) — \(NativeQuantFormat.date(record.endDate))")
                        .font(NativeStyle.FontRole.caption).foregroundStyle(NativePalette.secondary).fixedSize()
                    Text(NativeQuantFormat.percent(record.totalReturn)).font(NativeStyle.FontRole.section).monospacedDigit()
                        .foregroundStyle(record.totalReturn >= 0 ? NativePalette.accent : AssetTheme.negative).frame(width: 110, alignment: .trailing)
                  }.frame(minWidth: 590)
                  HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(record.subtitle.isEmpty ? record.title : record.subtitle).font(NativeStyle.FontRole.inputStrong).multilineTextAlignment(.leading)
                        Text("\(NativeQuantFormat.date(record.startDate)) — \(NativeQuantFormat.date(record.endDate))")
                            .font(NativeStyle.FontRole.micro).foregroundStyle(NativeHomeStyle.secondary)
                    }
                    Spacer()
                    Text(NativeQuantFormat.percent(record.totalReturn)).font(NativeStyle.FontRole.section).monospacedDigit()
                        .foregroundStyle(record.totalReturn >= 0 ? NativeHomeStyle.accent : AssetTheme.negative)
                  }
                }.frame(minHeight: 40).contentShape(Rectangle())
            }.accessibilityLabel("\(record.subtitle.isEmpty ? record.title : record.subtitle)，\(NativeQuantFormat.percent(record.totalReturn))")
            Menu {
                Button("恢复参数") { store.restore(record) }
                Button("导出数据") { NativeQuantExport.write(record: record) { store.error = $0 } }
                Button("删除", role: .destructive) { pendingDelete = record }
            } label: { Image(systemName: "ellipsis").frame(width: 26, height: 26) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("回测记录菜单")
        }.padding(.vertical, 2)
            .overlay(alignment: .bottom) { Rectangle().fill(NativeHomeStyle.line).frame(height: 0.5) }
    }
}

private struct NativeQuantConfigurationView: View {
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @Environment(\.modelContext) private var context
    @ObservedObject var store: NativeQuantStore
    @ObservedObject var market: RemoteMarketStore
    @State private var showsLibrary = false
    @State private var showsValidation = false
    @State private var customRange = false
    @State private var assetSearch = ""
    private var config: Binding<NativeQuantConfiguration> { $store.config }
    private var selectedTemplate: AdvancedBacktestStrategyTemplate? { AdvancedBacktestStrategyTemplate.all.first { $0.id == store.config.templateID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            dateRange
            Divider()
            switch store.config.kind {
            case .allocation: allocation
            case .dca: dca
            case .advanced: advanced
            }
            if store.config.kind == .advanced && !store.config.mode.isRotation {
                HStack {
                    Text("候选策略").font(NativeStyle.FontRole.section)
                    Spacer()
                    Button("扫描候选", systemImage: "sparkle.magnifyingglass") { store.optimize() }
                }
                ForEach(store.candidates) { candidate in
                    HStack {
                        Text("\(candidate.buyRule.direction.localizedShortTitle) \(candidate.buyRule.days) 天 / \(candidate.sellRule.direction.localizedShortTitle) \(candidate.sellRule.days) 天")
                        Spacer()
                        Text("年化 \(candidate.report.annualizedReturn.map(NativeQuantFormat.percent) ?? "—")")
                        Text("回撤 \(NativeQuantFormat.percent(candidate.report.maxDrawdown))")
                        Button("采用") { store.apply(candidate) }
                    }.font(NativeStyle.FontRole.caption).padding(.vertical, NativeStyle.Space.sm)
                }
            }
            Divider()
            HStack {
                if market.isLoading { ProgressView().controlSize(.small) }
                if let message = market.errorMessage { Text(message).font(NativeStyle.FontRole.caption).foregroundStyle(AssetTheme.accentOrange).lineLimit(3) }
                Spacer()
                Button("运行回测", systemImage: "play.fill") { store.run(in: context) }
                    .modifier(NativeWorkspacePrimary()).disabled(store.isWorking)
            }
        }
        .disabled(store.isWorking)
        .animation(NativeStyle.Motion.quant(reducedMotion || NativeHomeStyle.previewReduced), value: customRange)
        .animation(NativeStyle.Motion.quant(reducedMotion || NativeHomeStyle.previewReduced), value: store.config.mode.rawValue)
        .onAppear { customRange = store.config.startDate != nil || store.config.endDate != nil }
        .sheet(isPresented: $showsLibrary) {
            NativeQuantStrategyLibrary(selectedID: store.config.templateID) { template in
                store.config.applyTemplate(template.id); showsLibrary = false
            }
        }
        .sheet(isPresented: $showsValidation) {
            NativeQuantForwardValidation(templateID: store.config.templateID)
        }
    }
    private var dateRange: some View {
        HStack(spacing: NativeStyle.Space.lg) {
            Text("回测区间").font(NativeStyle.FontRole.input)
            Picker("区间", selection: $customRange) {
                Text("全部历史").tag(false)
                Text("自选日期").tag(true)
            }.labelsHidden().frame(width: 130)
                .onChange(of: customRange) { _, value in
                    if value {
                        store.config.startDate = store.config.startDate ?? Calendar.current.date(byAdding: .year, value: -5, to: .now)
                        store.config.endDate = store.config.endDate ?? .now
                    } else { store.config.startDate = nil; store.config.endDate = nil }
                }
            if customRange {
                DatePicker("开始", selection: Binding(get: { store.config.startDate ?? .now }, set: { store.config.startDate = $0 }), displayedComponents: .date)
                    .labelsHidden().frame(width: 140)
                Text("—").foregroundStyle(NativeHomeStyle.secondary)
                DatePicker("结束", selection: Binding(get: { store.config.endDate ?? .now }, set: { store.config.endDate = $0 }), in: ...Date.now, displayedComponents: .date)
                    .labelsHidden().frame(width: 140)
            }
            Spacer(minLength: 0)
        }
    }
    private var allocation: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("资产配置").font(NativeStyle.FontRole.subheading)
                Spacer()
                let sum = store.config.cashWeight + store.config.goldWeight + store.config.indexWeights.values.reduce(0, +)
                Text("合计 \(sum.formatted(.number.precision(.fractionLength(1))))%")
                    .font(NativeStyle.FontRole.body).foregroundStyle(abs(sum - 100) < 0.01 ? NativeHomeStyle.secondary : .orange)
                Button("重置") {
                    store.config.cashWeight = BacktestDefaults.cashWeight; store.config.goldWeight = BacktestDefaults.goldWeight
                    store.config.indexWeights = BacktestDefaults.indexWeights
                }.font(NativeStyle.FontRole.caption)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 18) {
                percentInput("现金", value: config.cashWeight)
                percentInput("黄金", value: config.goldWeight)
                ForEach(BacktestDefaults.indexOptions) { option in
                    percentInput(option.title, value: Binding(get: { store.config.indexWeights[option.symbol, default: 0] }, set: { store.config.indexWeights[option.symbol] = $0 }))
                }
            }
        }
    }
    private var dca: some View {
        VStack(alignment: .leading, spacing: NativeStyle.Space.section) {
            Text("定投设置").font(NativeStyle.FontRole.subheading)
            Picker("资产", selection: config.dcaSymbol) {
                ForEach(market.backtestAssetOptions) { Text($0.title).tag($0.symbol) }
            }.frame(maxWidth: 420)
            HStack(spacing: 30) {
                numberInput("每期金额", value: config.contribution, suffix: "元")
                VStack(alignment: .leading, spacing: 10) {
                    Text("间隔").font(NativeStyle.FontRole.caption).foregroundStyle(NativeHomeStyle.secondary)
                    HStack {
                        TextField("天数", value: config.intervalDays, format: .number).textFieldStyle(.roundedBorder).frame(width: 100)
                        Text("天").font(NativeStyle.FontRole.caption).foregroundStyle(NativeHomeStyle.secondary)
                    }
                }
            }
        }
    }
    private var advanced: some View {
        VStack(alignment: .leading, spacing: NativeStyle.Space.section) {
            HStack {
                VStack(alignment: .leading, spacing: 9) {
                    Text(selectedTemplate?.title ?? "自定义策略").font(NativeStyle.FontRole.sectionTitle)
                }
                Spacer()
                if selectedTemplate != nil { Button("前瞻跟踪") { showsValidation = true } }
                Button("策略库", systemImage: "square.grid.2x2") { showsLibrary = true }
                Button("自定义") { store.config.templateID = "custom"; store.config.mode = .ruleBased }
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: NativeStyle.Space.xl) {
                numberInput("初始资金", value: config.initialCash, suffix: "元")
                if !store.config.mode.isRotation { numberInput("单次金额", value: config.tradeAmount, suffix: "元") }
                percentInput("仓位上限", value: config.maxPosition)
                percentInput("交易费率", value: config.fee)
                percentInput("滑点", value: config.slippage)
                VStack(alignment: .leading, spacing: 10) {
                    Text("冷却天数").font(NativeStyle.FontRole.caption).foregroundStyle(NativeHomeStyle.secondary)
                    TextField("天数", value: config.cooldown, format: .number).textFieldStyle(.roundedBorder)
                }
                percentInput("止损", value: config.stopLoss)
                percentInput("止盈", value: config.takeProfit)
            }
            if !store.config.mode.isRotation {
                HStack(spacing: NativeStyle.Space.xl) {
                    ruleInput("买入条件", direction: config.buyDirection, days: config.buyDays)
                    ruleInput("卖出条件", direction: config.sellDirection, days: config.sellDays)
                }
            }
            Divider()
            HStack {
                Text("资产").font(NativeStyle.FontRole.icon)
                Spacer()
                TextField("搜索资产", text: $assetSearch).textFieldStyle(.roundedBorder).frame(width: 200)
            }
            let options = market.backtestAssetOptions + BacktestDefaults.internalStrategyAssetOptions.filter { item in
                !market.backtestAssetOptions.contains(where: { $0.symbol == item.symbol })
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 14) {
                ForEach(options.filter { assetSearch.isEmpty || $0.title.localizedCaseInsensitiveContains(assetSearch) || $0.symbol.localizedCaseInsensitiveContains(assetSearch) }) { option in
                    Toggle(option.title, isOn: Binding(get: { store.config.selectedSymbols.contains(option.symbol) }, set: { included in
                        if included { store.config.selectedSymbols.insert(option.symbol) }
                        else { store.config.selectedSymbols.remove(option.symbol) }
                    })).toggleStyle(.checkbox).font(NativeStyle.FontRole.body)
                        .disabled(store.config.mode.requiredSignalAssetSymbols.contains(option.symbol))
                }
            }
        }
    }
    private func ruleInput(_ label: String, direction: Binding<AdvancedBacktestSignalDirection>, days: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label).font(NativeStyle.FontRole.caption).foregroundStyle(NativeHomeStyle.secondary)
            Picker(label, selection: direction) {
                ForEach(AdvancedBacktestSignalDirection.allCases) { Text($0.localizedTitle).tag($0) }
            }.labelsHidden()
            Stepper("连续 \(days.wrappedValue) 天", value: days, in: 1...250).font(NativeStyle.FontRole.caption)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func percentInput(_ title: String, value: Binding<Double>) -> some View { numberInput(title, value: value, suffix: "%") }
    private func numberInput(_ title: String, value: Binding<Double>, suffix: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(NativeStyle.FontRole.caption).foregroundStyle(NativeHomeStyle.secondary)
            HStack(spacing: NativeStyle.Space.sm) {
                TextField(title, value: value, format: .number.precision(.fractionLength(0...4))).textFieldStyle(.roundedBorder)
                Text(suffix).font(NativeStyle.FontRole.caption).foregroundStyle(NativeHomeStyle.secondary)
            }
        }
    }
}

private struct NativeQuantStrategyLibrary: View {
    @Environment(\.dismiss) private var dismiss
    let selectedID: String
    let select: (AdvancedBacktestStrategyTemplate) -> Void
    @State private var search = ""
    @State private var group = "selected"
    private var templates: [AdvancedBacktestStrategyTemplate] {
        AdvancedBacktestStrategyTemplate.productCatalog.filter {
            let basic = BacktestProductStrategyCatalog.isBasicTemplateID($0.id)
            return (group == "selected" ? !basic : basic) && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search))
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text("策略库").font(NativeStyle.FontRole.sectionTitle)
                Spacer()
                Button("完成") { dismiss() }
            }
            HStack {
                Picker("分组", selection: $group) { Text("精选").tag("selected"); Text("基础").tag("basic") }
                    .pickerStyle(.segmented).frame(width: 180).labelsHidden()
                Spacer()
                TextField("搜索策略", text: $search).textFieldStyle(.roundedBorder).frame(width: 190)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(templates) { template in
                        Button { select(template) } label: {
                            HStack(spacing: 18) {
                                VStack(alignment: .leading, spacing: 9) {
                                    Text(template.title).font(NativeStyle.FontRole.sectionStrong)
                                    Text(template.subtitle).font(NativeStyle.FontRole.caption).foregroundStyle(NativeHomeStyle.secondary)
                                        .multilineTextAlignment(.leading).lineLimit(3)
                                }
                                Spacer(minLength: 12)
                                if selectedID == template.id { Image(systemName: "checkmark").foregroundStyle(NativeHomeStyle.accent) }
                            }.padding(.vertical, 18).contentShape(Rectangle())
                        }
                        Divider()
                    }
                }
            }
        }.padding(26).frame(width: 620, height: 540).modifier(NativeWorkspaceSurface())
        .buttonStyle(NativeQuantFeedback(reduced: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || NativeHomeStyle.previewReduced))
        .animation(NativeStyle.Motion.quant(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || NativeHomeStyle.previewReduced), value: group)
        .animation(NativeStyle.Motion.quant(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || NativeHomeStyle.previewReduced), value: search)
    }
}

/// Partition only the positive finite weights. Zero/missing holdings never become a fake cash position.
enum NativeQuantAllocationLayout {
    static func frames(weights: [Double], size: CGSize) -> [CGRect] {
        var result = Array(repeating: CGRect.zero, count: weights.count)
        let indices = weights.indices.filter { weights[$0].isFinite && weights[$0] > 0 }
        guard !indices.isEmpty, size.width > 0, size.height > 0 else { return result }
        func partition(_ ids: [Int], _ rect: CGRect, _ horizontal: Bool) {
            guard let first = ids.first else { return }
            if ids.count == 1 { result[first] = rect; return }
            let total = ids.reduce(0.0) { $0 + weights[$1] }
            var running = 0.0
            var split = 1
            var distance = Double.infinity
            for index in 1..<ids.count {
                running += weights[ids[index - 1]]
                let next = abs(running / total - 0.5)
                if next < distance { distance = next; split = index }
            }
            let a = Array(ids.prefix(split)), b = Array(ids.dropFirst(split))
            let ratio = a.reduce(0.0) { $0 + weights[$1] } / total
            if horizontal {
                let width = rect.width * ratio
                partition(a, CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height), false)
                partition(b, CGRect(x: rect.minX + width, y: rect.minY, width: rect.width - width, height: rect.height), false)
            } else {
                let height = rect.height * ratio
                partition(a, CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: height), true)
                partition(b, CGRect(x: rect.minX, y: rect.minY + height, width: rect.width, height: rect.height - height), true)
            }
        }
        partition(indices, CGRect(origin: .zero, size: size), true)
        return result
    }
}

private struct NativeQuantAllocationItem: Identifiable {
    let id: String
    let title: String
    let weight: Double
    let amount: Double?
    let color: Color
}

private struct NativeQuantAllocationMap: View {
    let items: [NativeQuantAllocationItem]
    let unknown: Bool
    let reduced: Bool
    let showsAmounts: Bool
    @Binding var hovered: String?
    @State private var pointer: CGPoint?
    private func amountText(_ item: NativeQuantAllocationItem) -> String {
        showsAmounts ? item.amount.map(NativeHomeStyle.amount) ?? "—" : "••••"
    }
    var body: some View {
        GeometryReader { geometry in
            let frames = NativeQuantAllocationLayout.frames(weights: items.map(\.weight), size: geometry.size)
            if unknown {
                Rectangle().strokeBorder(NativePalette.line, lineWidth: 1)
                    .overlay { Text("未记录").foregroundStyle(NativePalette.secondary).font(NativeStyle.FontRole.input) }
            } else {
                ZStack(alignment: .topLeading) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        let rect = frames[index]
                        ZStack(alignment: .leading) {
                            Rectangle().fill(item.color)
                            if rect.width >= 70 && rect.height >= 46 {
                                VStack(alignment: .leading, spacing: NativeStyle.Space.xxs) {
                                    Text(item.title).lineLimit(2)
                                    Text(item.weight, format: .percent.precision(.fractionLength(2)))
                                        .monospacedDigit().contentTransition(.numericText())
                                }.font(NativeStyle.FontRole.section).padding(.horizontal, 15)
                            }
                        }
                        .overlay(Rectangle().stroke(NativePalette.accent.opacity(hovered == item.id ? 0.65 : 0), lineWidth: 1.2))
                        .padding(1).frame(width: max(0, rect.width), height: max(0, rect.height))
                        .position(x: rect.midX, y: rect.midY)
                        .opacity(item.weight > 0 ? 1 : 0)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(item.title)，\(NativeQuantFormat.percent(item.weight))")
                        .accessibilityValue(amountText(item))
                        .accessibilityHidden(item.weight <= 0)
                    }
                }.animation(NativeStyle.Motion.quant(reduced), value: items.map(\.weight))
                    .animation(NativeStyle.Motion.quant(reduced), value: hovered)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            pointer = point
                            let next = items.indices.first { items[$0].weight > 0 && frames[$0].contains(point) }
                                .map { items[$0].id }
                            if hovered != next { hovered = next }
                        case .ended:
                            pointer = nil
                            hovered = nil
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if let pointer, let item = items.first(where: { $0.id == hovered && $0.weight > 0 }) {
                            let width = min(210.0, geometry.size.width - 16)
                            VStack(alignment: .leading, spacing: NativeStyle.Space.xs) {
                                Text(item.title).font(NativeStyle.FontRole.inputStrong).lineLimit(2)
                                HStack {
                                    Text("占比").foregroundStyle(NativePalette.secondary)
                                    Spacer()
                                    Text(item.weight, format: .percent.precision(.fractionLength(2)))
                                }
                                HStack {
                                    Text("金额").foregroundStyle(NativePalette.secondary)
                                    Spacer()
                                    Text(item.amount.map(NativeHomeStyle.amount) ?? "—")
                                }
                            }.font(NativeStyle.FontRole.body).monospacedDigit()
                                .padding(NativeStyle.Space.md).frame(width: width)
                                .background(NativePalette.surface, in: RoundedRectangle(cornerRadius: NativeStyle.Radius.field))
                                .overlay(RoundedRectangle(cornerRadius: NativeStyle.Radius.field).stroke(NativePalette.line, lineWidth: 0.7))
                                .offset(x: min(max(8, pointer.x + 12), max(8, geometry.size.width - width - 8)),
                                        y: min(max(8, pointer.y + 16), max(8, geometry.size.height - 100)))
                                .allowsHitTesting(false).accessibilityHidden(true)
                                .transaction { $0.animation = nil }
                        }
                    }
                    .onDisappear { pointer = nil; hovered = nil }
            }
        }
    }
}

private struct NativeQuantAllocationLegend: View {
    let items: [NativeQuantAllocationItem]
    let showsAmounts: Bool
    @Binding var hovered: String?
    var body: some View {
        VStack(spacing: NativeStyle.Space.xxs) {
            ForEach(items.filter { $0.weight.isFinite && $0.weight > 0 }) { item in
                HStack(spacing: NativeStyle.Space.sm) {
                    RoundedRectangle(cornerRadius: 2).fill(item.color).frame(width: 8, height: 8)
                    Text(item.title).lineLimit(2)
                    Spacer(minLength: NativeStyle.Space.xs)
                    Text(item.weight, format: .percent.precision(.fractionLength(2)))
                        .monospacedDigit().foregroundStyle(NativePalette.secondary)
                    if showsAmounts {
                        Text(item.amount.map(NativeHomeStyle.amount) ?? "—").monospacedDigit()
                    }
                }.font(NativeStyle.FontRole.body).frame(minHeight: 24).contentShape(Rectangle())
                    .onHover { over in
                        if over { hovered = item.id } else if hovered == item.id { hovered = nil }
                    }
                    .help("\(item.title)  \(item.weight.formatted(.percent.precision(.fractionLength(2))))  \(item.amount.map(NativeHomeStyle.amount) ?? "—")")
            }
        }.onDisappear { hovered = nil }
    }
}

private struct NativeQuantAdviceView: View {
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @Environment(\.modelContext) private var context
    @ObservedObject var projection: StrategyAdviceProjectionStore
    @ObservedObject var market: RemoteMarketStore
    @State private var templateID = StrategyRebalanceDefaults.defaultTemplateID
    @State private var latestSnapshot: AssetSnapshot?
    @State private var showsAmounts = false
    @State private var showsLibrary = false
    @State private var reloadToken = 0
    @State private var snapshotError: String?
    @State private var hovered: String?
    private var reducesMotion: Bool { reducedMotion || NativeHomeStyle.previewReduced }
    private var taskID: String {
        let symbols = StrategyRebalanceDefaults.template(for: templateID).map { StrategyRebalanceDefaults.historySymbols(for: $0) } ?? []
        return "\(templateID)|\(reloadToken)|\(market.strategyInputRelevanceToken(for: symbols))"
    }
    private var currentKnown: Bool { projection.actions.contains { $0.currentWeight != nil } }
    private var mapHeight: CGFloat { max(215, CGFloat(projection.actions.count + 1) * 69) }
    private func color(_ symbol: String, index: Int) -> Color {
        if symbol == "cash" { return NativePalette.cash }
        if symbol.lowercased().contains("gold") { return NativePalette.goldAllocation }
        let colors: [Color] = [
            NativePalette.allocationLight,
            NativePalette.allocationMedium,
            NativePalette.allocationDark
        ]
        let ordinal = projection.actions.prefix(index).filter { !$0.symbol.lowercased().contains("gold") }.count
        return colors[ordinal % colors.count]
    }
    private func items(target: Bool) -> [NativeQuantAllocationItem] {
        var result = projection.actions.enumerated().map { index, action in
            NativeQuantAllocationItem(id: action.symbol, title: action.title,
                weight: max(0, target ? action.targetWeight : (action.currentWeight ?? 0)),
                amount: target ? action.targetAmount : action.currentAmount,
                color: color(action.symbol, index: index))
        }
        let used = result.reduce(0) { $0 + $1.weight }
        let residualAmount = projection.actions.compactMap(\.investmentBase).first.map {
            max(0, $0 - result.compactMap(\.amount).reduce(0, +))
        }
        result.append(.init(id: "native-residual-cash", title: "现金 / 其他", weight: max(0, 1 - used),
            amount: residualAmount, color: color("cash", index: 0)))
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 17) {
                Text("今日持仓建议").font(NativeStyle.FontRole.pageTitle)
                Spacer(minLength: 12)
                Button { showsLibrary = true } label: {
                    HStack(spacing: NativeStyle.Space.sm) {
                        Text(StrategyRebalanceDefaults.template(for: templateID)?.title ?? "选择策略").lineLimit(2)
                        Image(systemName: "chevron.down").font(NativeStyle.FontRole.micro)
                    }.font(NativeStyle.FontRole.body).frame(minHeight: 30)
                }.accessibilityLabel("选择持仓建议策略")
                Button {
                    if projection.isRefreshing { projection.cancel() } else { reloadToken += 1 }
                } label: {
                    ZStack {
                        if projection.isRefreshing { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.clockwise").font(NativeStyle.FontRole.metric) }
                    }.frame(width: 26, height: 30)
                }.accessibilityLabel(projection.isRefreshing ? "取消刷新" : "刷新持仓建议")
                Rectangle().fill(NativePalette.line).frame(width: 0.5, height: 20)
                Button {
                    withAnimation(NativeStyle.Motion.quant(reducesMotion)) { showsAmounts.toggle() }
                } label: {
                    Image(systemName: showsAmounts ? "eye.slash" : "eye").font(NativeStyle.FontRole.metric)
                        .contentTransition(reducesMotion ? .opacity : .symbolEffect(.replace))
                        .frame(width: 28, height: 30)
                }.accessibilityLabel(showsAmounts ? "隐藏金额" : "显示金额")
            }.frame(minHeight: 30).padding(.bottom, 22)
            if projection.isRefreshing {
                HStack(spacing: NativeStyle.Space.md) {
                    ProgressView(value: projection.progressFraction).frame(width: 150)
                        .accessibilityLabel("今日策略生成进度")
                    Text(projection.progressFraction, format: .percent.precision(.fractionLength(0)))
                        .font(NativeStyle.FontRole.captionStrong).monospacedDigit()
                        .foregroundStyle(NativePalette.accent).frame(width: 34, alignment: .trailing)
                    Text(projection.progressMessage).font(NativeStyle.FontRole.caption).foregroundStyle(NativePalette.secondary)
                }.padding(.bottom, 14).transition(.opacity)
            }
            if let snapshotError { Text(snapshotError).font(NativeStyle.FontRole.body).foregroundStyle(AssetTheme.accentOrange).padding(.bottom, 14).transition(.opacity) }
            if let status = projection.statusMessage { Text(status).font(NativeStyle.FontRole.body).foregroundStyle(AssetTheme.accentOrange).padding(.bottom, 14).transition(.opacity) }
            if let advice = projection.advice {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 30) {
                        maps
                        actions.frame(width: 181).padding(.top, 30)
                    }.frame(minWidth: 790)
                    VStack(alignment: .leading, spacing: NativeStyle.Space.section) { maps; actions }
                }.transition(NativeStyle.Motion.quantTransition(reducesMotion))
                HStack {
                    Text("信号截至 \(NativeQuantFormat.date(advice.asOfDate))")
                    if let date = projection.snapshotDate { Text("· 资产记录 \(NativeQuantFormat.date(date))") }
                    Spacer(minLength: 0)
                }.font(NativeStyle.FontRole.micro).foregroundStyle(NativePalette.secondary).padding(.top, 35)
                if !projection.historySourceNames.isEmpty {
                    Text(projection.historySourceNames.joined(separator: " · ")).font(NativeStyle.FontRole.micro).foregroundStyle(NativePalette.secondary).lineLimit(2).padding(.top, NativeStyle.Space.xs)
                }
            } else if !projection.isRefreshing && projection.statusMessage == nil {
                Text("暂无持仓建议").font(NativeStyle.FontRole.body).foregroundStyle(NativePalette.secondary)
                    .frame(maxWidth: .infinity, minHeight: NativeStyle.Layout.emptyStateHeight).transition(.opacity)
            }
        }
        .animation(NativeStyle.Motion.quant(reducesMotion), value: projection.actions.map(\.targetWeight))
        .animation(NativeStyle.Motion.quant(reducesMotion), value: projection.actions.map(\.currentWeight))
        .animation(NativeStyle.Motion.quant(reducesMotion), value: projection.isRefreshing)
        .animation(NativeStyle.Motion.quant(reducesMotion), value: projection.statusMessage)
        .task {
            if AppPreviewSession.isActive,
               let template = AdvancedBacktestStrategyTemplate.productCatalog.first(where: { $0.title == projection.advice?.strategyTitle }) {
                templateID = template.id
            } else if !AppPreviewSession.isActive {
                templateID = StrategyRebalanceDefaults.migratedTemplateID(UserDefaults.standard.string(forKey: "app.strategyNotifications.templateID") ?? StrategyRebalanceDefaults.defaultTemplateID)
            }
        }
        .task(id: taskID) {
            let fixtureInteraction = AppPreviewSession.isActive
                && ProcessInfo.processInfo.arguments.contains("-macWorkspaceInMemory")
                && ProcessInfo.processInfo.arguments.contains("-macQuantProbeStdin")
            guard !AppPreviewSession.isActive || fixtureInteraction else { return }
            var descriptor = FetchDescriptor<AssetSnapshot>(sortBy: [SortDescriptor(\.date, order: .reverse)])
            descriptor.fetchLimit = 1
            do {
                latestSnapshot = try context.fetch(descriptor).first
                await projection.refresh(templateID: templateID, marketStore: market, snapshot: latestSnapshot, force: reloadToken > 0)
                snapshotError = nil
            } catch { snapshotError = "无法读取当前持仓：\(error.localizedDescription)" }
        }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { notification in
            guard let saved = notification.object as? ModelContext, saved === context else { return }
            var descriptor = FetchDescriptor<AssetSnapshot>(sortBy: [SortDescriptor(\.date, order: .reverse)])
            descriptor.fetchLimit = 1
            do { latestSnapshot = try context.fetch(descriptor).first; projection.updateSnapshot(latestSnapshot); snapshotError = nil }
            catch { snapshotError = "无法更新当前持仓：\(error.localizedDescription)" }
        }
        .onDisappear { projection.cancel() }
        .sheet(isPresented: $showsLibrary) {
            NativeQuantStrategyLibrary(selectedID: templateID) { template in
                templateID = template.id
                if !AppPreviewSession.isActive { UserDefaults.standard.set(template.id, forKey: "app.strategyNotifications.templateID") }
                showsLibrary = false
            }
        }
    }
    private var maps: some View {
        HStack(alignment: .top, spacing: 21) {
            map("当前", target: false)
            map("目标", target: true)
        }
    }
    private func map(_ title: String, target: Bool) -> some View {
        let allocations = items(target: target)
        return VStack(alignment: .leading, spacing: NativeStyle.Space.md) {
            Text(title).font(NativeStyle.FontRole.iconStrong).frame(height: 18)
            NativeQuantAllocationMap(items: allocations, unknown: !target && !currentKnown,
                reduced: reducesMotion, showsAmounts: showsAmounts, hovered: $hovered).frame(height: mapHeight)
            if target || currentKnown {
                NativeQuantAllocationLegend(items: allocations, showsAmounts: showsAmounts, hovered: $hovered)
            }
        }.frame(maxWidth: .infinity)
    }
    private var actions: some View {
        VStack(spacing: 0) {
            ForEach(Array(projection.actions.enumerated()), id: \.element.id) { index, action in
                actionRow(action.title, color: color(action.symbol, index: index), action: action.kind.title,
                    accent: action.kind.accent, amount: action.amountText)
            }
            actionRow("现金 / 其他", color: color("cash", index: 0), action: "防守仓位", accent: NativePalette.secondary, amount: "—")
            Rectangle().fill(NativePalette.line).frame(height: 0.5)
        }
    }
    private func actionRow(_ title: String, color: Color, action: String, accent: Color, amount: String) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 17, height: 17)
            Text(title).font(NativeStyle.FontRole.input).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: NativeStyle.Space.xxs) {
                Text(action).font(NativeStyle.FontRole.body).foregroundStyle(accent)
                if showsAmounts {
                    Text(amount).font(NativeStyle.FontRole.micro).monospacedDigit().foregroundStyle(NativePalette.secondary)
                        .transition(NativeStyle.Motion.quantTransition(reducesMotion))
                }
            }.fixedSize(horizontal: true, vertical: false)
        }.frame(maxWidth: .infinity, minHeight: mapHeight / CGFloat(projection.actions.count + 1))
            .overlay(alignment: .top) { Rectangle().fill(NativePalette.line).frame(height: 0.5) }
    }
}

private struct NativeQuantResultView: View {
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    let record: BacktestRecord
    let restore: () -> Void
    @State private var chartMode = "value"
    @State private var showBenchmark = true
    @State private var showParameters = false
    @State private var hoverDate: Date?
    @State private var exportError: String?
    @State private var points: [BacktestSeriesPoint] = []
    @State private var config: BacktestRecordConfigPayload?
    @State private var tradeLimit = 100
    private var trades: [BacktestRecordAdvancedTradePayload] { config?.advancedTrades ?? [] }
    private var hovered: BacktestSeriesPoint? {
        guard let hoverDate else { return nil }
        return plotted.min { abs($0.date.timeIntervalSince(hoverDate)) < abs($1.date.timeIntervalSince(hoverDate)) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 25) {
            HStack {
                Text("\(NativeQuantFormat.date(record.startDate)) — \(NativeQuantFormat.date(record.endDate))")
                    .font(NativeStyle.FontRole.caption).foregroundStyle(NativeHomeStyle.secondary)
                Spacer()
                Button("恢复参数", action: restore)
                Menu {
                    Button("导出数据") { NativeQuantExport.write(record: record) { exportError = $0 } }
                    Button("导出图片") { NativeQuantExport.writePoster(record: record) { exportError = $0 } }
                } label: { Label("导出", systemImage: "square.and.arrow.up") }
                    .menuStyle(.borderlessButton).fixedSize()
            }.font(NativeStyle.FontRole.body)
            if let exportError { Text(exportError).font(NativeStyle.FontRole.caption).foregroundStyle(AssetTheme.accentOrange) }
            HStack(alignment: .firstTextBaseline, spacing: NativeStyle.Space.page) {
                metric("总收益", value: NativeQuantFormat.percent(record.totalReturn), primary: true)
                Spacer(minLength: 0)
                metric("年化收益", value: record.annualizedReturn.map(NativeQuantFormat.percent) ?? "—")
                metric("最大回撤", value: NativeQuantFormat.percent(record.maxDrawdown))
                metric("夏普比率", value: record.sharpeRatio.map { $0.formatted(.number.precision(.fractionLength(2))) } ?? "—")
            }
            Divider()
            HStack {
                Picker("图表", selection: $chartMode) {
                    Text("净值").tag("value")
                    Text("回撤").tag("drawdown")
                    if !(config?.advancedExposurePoints?.isEmpty ?? true) { Text("仓位").tag("exposure") }
                }.pickerStyle(.segmented).frame(width: 220).labelsHidden()
                Spacer()
                if let hovered {
                    Text("\(NativeQuantFormat.date(hovered.date))  \(chartMode == "value" ? chartLabel(hovered.portfolioValue) : NativeQuantFormat.percent(hovered.portfolioValue))")
                        .font(NativeStyle.FontRole.caption).monospacedDigit().foregroundStyle(NativeHomeStyle.secondary)
                }
                if chartMode == "value", !(config?.advancedBenchmarkSeries?.isEmpty ?? true) {
                    Toggle("基准", isOn: $showBenchmark).toggleStyle(.checkbox).font(NativeStyle.FontRole.caption)
                }
            }
            if chartMode == "value", showBenchmark {
                HStack(spacing: 18) {
                    ForEach(Array((config?.advancedBenchmarkSeries ?? []).enumerated()), id: \.element.id) { index, benchmark in
                        HStack(spacing: 5) {
                            Circle().fill(benchmarkColor(index)).frame(width: 4, height: 4)
                            Text(benchmark.title).font(NativeStyle.FontRole.micro).foregroundStyle(NativeHomeStyle.secondary)
                        }
                    }
                }
            }
            resultChart.frame(height: 255)
            HStack(spacing: 30) {
                if let value = record.finalValue { metric(record.kindRawValue == "allocation" ? "期末净值" : "期末资产", value: chartLabel(value)) }
                if let value = record.totalInvested { metric("累计投入", value: NativeHomeStyle.amount(value)) }
                if let value = record.profitLoss { metric("盈亏", value: NativeHomeStyle.amount(value)) }
                if record.kindRawValue != "allocation" {
                    metric(record.kindRawValue == "dca" ? "定投次数" : "交易次数", value: "\(record.tradeCount)")
                }
                if let volatility = record.annualizedVolatility { metric("年化波动", value: NativeQuantFormat.percent(volatility)) }
            }
            if let summary = config?.cashYieldSummary {
                Divider()
                HStack(spacing: 30) {
                    metric("现金利息", value: NativeHomeStyle.amount(summary.totalCashInterest))
                    metric("平均现金占比", value: NativeQuantFormat.percent(summary.averageCashRatio))
                    metric("平均现金年利率", value: NativeQuantFormat.percent(summary.averageAnnualRate))
                }
                Text(summary.source).font(NativeStyle.FontRole.micro).foregroundStyle(NativeHomeStyle.secondary)
            }
            if let risk = config?.riskSignalSummary {
                DisclosureGroup("风险信号") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(risk.sourceDetail).font(NativeStyle.FontRole.caption).foregroundStyle(NativeHomeStyle.secondary)
                        Text("压力期占比 \(NativeQuantFormat.percent(risk.stressSessionRatio))").font(NativeStyle.FontRole.body)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, NativeStyle.Space.md)
                }
            }
            DisclosureGroup("回测参数", isExpanded: $showParameters) {
                Text(parameterSummary).font(NativeStyle.FontRole.caption).foregroundStyle(NativeHomeStyle.secondary)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, NativeStyle.Space.md)
            }.font(NativeStyle.FontRole.body)
            if !trades.isEmpty {
                Divider()
                Text("交易明细").font(NativeStyle.FontRole.subheading)
                HStack {
                    Text("日期").frame(width: 90, alignment: .leading)
                    Text("资产").frame(maxWidth: .infinity, alignment: .leading)
                    Text("方向").frame(width: 50)
                    Text("成交价").frame(width: 90, alignment: .trailing)
                    Text("金额").frame(width: 110, alignment: .trailing)
                }.font(NativeStyle.FontRole.micro).foregroundStyle(NativeHomeStyle.secondary)
                LazyVStack(spacing: 0) {
                    ForEach(Array(trades.prefix(tradeLimit))) { trade in
                        VStack(alignment: .leading, spacing: NativeStyle.Space.sm) {
                            HStack {
                                Text(NativeQuantFormat.date(trade.date)).frame(width: 90, alignment: .leading)
                                Text(trade.assetTitle).frame(maxWidth: .infinity, alignment: .leading)
                                Text(trade.action.title).foregroundStyle(trade.action == .buy ? AssetTheme.positive : AssetTheme.negative).frame(width: 50)
                                Text(trade.price.formatted(.number.precision(.fractionLength(2)))).frame(width: 90, alignment: .trailing)
                                Text(NativeHomeStyle.amount(trade.cashAmount)).frame(width: 110, alignment: .trailing)
                            }.font(NativeStyle.FontRole.caption).monospacedDigit()
                            if let reason = trade.reason { Text(reason).font(NativeStyle.FontRole.micro).foregroundStyle(NativeHomeStyle.secondary).lineLimit(2) }
                        }.padding(.vertical, NativeStyle.Space.md)
                        Divider()
                    }
                    if tradeLimit < trades.count { Button("显示更多") { tradeLimit += 100 }.padding(.top, 15) }
                }
            }
        }
        .animation(NativeStyle.Motion.quant(reducedMotion || NativeHomeStyle.previewReduced), value: chartMode)
        .animation(NativeStyle.Motion.quant(reducedMotion || NativeHomeStyle.previewReduced), value: showBenchmark)
        .task(id: record.id) {
            points = BacktestRecordCodec.decodePoints(from: record)
            config = BacktestRecordCodec.decodeConfig(from: record)
            chartMode = "value"; hoverDate = nil; tradeLimit = 100
        }
    }
    private var parameterSummary: String {
        guard let config else { return record.configSummary }
        var lines = [record.configSummary]
        if let symbols = config.selectedAssetSymbols { lines.append(symbols.joined(separator: " · ")) }
        if let fee = config.feeRate, let slippage = config.slippageRate {
            lines.append("交易费率 \(fee)% · 滑点 \(slippage)%")
        }
        if let max = config.maxPositionRatio { lines.append("仓位上限 \(max)% · 冷却 \(config.cooldownDays ?? 0) 天") }
        if let initialCash = config.initialCash { lines.append("初始资金 \(NativeHomeStyle.amount(initialCash))") }
        if let buy = config.buyDirectionRawValue, let sell = config.sellDirectionRawValue {
            lines.append("买入 \(AdvancedBacktestSignalDirection(rawValue: buy)?.localizedTitle ?? buy) \(config.buyDays ?? 1) 天")
            lines.append("卖出 \(AdvancedBacktestSignalDirection(rawValue: sell)?.localizedTitle ?? sell) \(config.sellDays ?? 1) 天")
        }
        if let provenance = config.runtimeProvenance { lines.append(provenance.executionVersion) }
        return lines.joined(separator: "\n")
    }
    private var plotted: [BacktestSeriesPoint] {
        if chartMode == "exposure" {
            return (config?.advancedExposurePoints ?? []).map { .init(date: $0.date, portfolioValue: $0.ratio, sequence: $0.sequence) }
        }
        if chartMode == "drawdown" {
            var peak = 0.0
            return points.map { point in
                peak = max(peak, point.portfolioValue)
                return .init(date: point.date, portfolioValue: peak > 0 ? (point.portfolioValue / peak - 1) : 0, sequence: point.id)
            }
        }
        return points
    }
    private var resultChart: some View {
        Chart {
            ForEach(plotted) { point in
                LineMark(x: .value("日期", point.date), y: .value("数值", point.portfolioValue), series: .value("曲线", "策略"))
                    .foregroundStyle(NativeHomeStyle.accent).lineStyle(StrokeStyle(lineWidth: 1.7))
            }
            if chartMode == "value", showBenchmark {
                ForEach(Array((config?.advancedBenchmarkSeries ?? []).enumerated()), id: \.element.id) { index, benchmark in
                    ForEach(benchmark.points, id: \.sequence) { point in
                        LineMark(x: .value("日期", point.date), y: .value("数值", normalizedBenchmark(point.value, series: benchmark)), series: .value("曲线", benchmark.id))
                            .foregroundStyle(benchmarkColor(index)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
            }
            if let hovered {
                RuleMark(x: .value("日期", hovered.date)).foregroundStyle(NativeHomeStyle.text.opacity(0.25)).lineStyle(StrokeStyle(lineWidth: 0.5))
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.4)).foregroundStyle(NativeHomeStyle.line)
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(chartMode == "value" ? chartLabel(number) : NativeQuantFormat.percent(number)).font(NativeStyle.FontRole.chartLabel).foregroundStyle(NativeHomeStyle.secondary)
                    }
                }
            }
        }
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { _ in AxisValueLabel().font(NativeStyle.FontRole.chartLabel).foregroundStyle(NativeHomeStyle.secondary) } }
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Color.clear.contentShape(Rectangle()).onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        guard let anchor = proxy.plotFrame else { return }
                        hoverDate = proxy.value(atX: location.x - geometry[anchor].origin.x, as: Date.self)
                    case .ended: hoverDate = nil
                    }
                }
            }
        }
    }
    private func benchmarkColor(_ index: Int) -> Color {
        [AssetTheme.gold.opacity(0.7), AssetTheme.positive.opacity(0.7), NativeHomeStyle.text.opacity(0.4)][index % 3]
    }
    private func normalizedBenchmark(_ value: Double, series: BacktestRecordAdvancedBenchmarkSeriesPayload) -> Double {
        guard let first = series.points.first?.value, first > 0 else { return value }
        return value / first * (points.first?.portfolioValue ?? 1)
    }
    private func chartLabel(_ value: Double) -> String {
        record.kindRawValue == "allocation" ? "\(value.formatted(.number.precision(.fractionLength(2))))×" : NativeHomeStyle.amount(value)
    }
    private func metric(_ label: String, value: String, primary: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label).font(NativeStyle.FontRole.micro).foregroundStyle(NativeHomeStyle.secondary)
            Text(value).font(primary ? NativeStyle.FontRole.displayRegular : NativeStyle.FontRole.metric).monospacedDigit()
                .foregroundStyle(primary ? NativeHomeStyle.accent : NativeHomeStyle.text).lineLimit(1).minimumScaleFactor(0.7)
        }
    }
}

enum NativeQuantFormat {
    static func percent(_ value: Double) -> String { value.formatted(.percent.precision(.fractionLength(1))) }
    static func date(_ value: Date?) -> String {
        value?.formatted(Date.FormatStyle().year().month(.twoDigits).day(.twoDigits).locale(Locale(identifier: "zh_CN"))) ?? "—"
    }
}

@MainActor
enum NativeQuantExport {
    static func write(record: BacktestRecord, onError: (String) -> Void) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "回测-\(record.id.uuidString.prefix(8)).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // Preserve the existing wire payloads, rather than exporting rendered chart text.
            let metadata: [String: Any] = ["id": record.id.uuidString, "kind": record.kindRawValue,
                "title": record.title, "subtitle": record.subtitle, "summary": record.configSummary,
                "createdAt": record.createdAt.ISO8601Format(), "startDate": record.startDate?.ISO8601Format() as Any? ?? NSNull(),
                "endDate": record.endDate?.ISO8601Format() as Any? ?? NSNull(), "totalReturn": record.totalReturn,
                "annualizedReturn": record.annualizedReturn as Any? ?? NSNull(), "maxDrawdown": record.maxDrawdown,
                "annualizedVolatility": record.annualizedVolatility as Any? ?? NSNull(),
                "finalValue": record.finalValue as Any? ?? NSNull(), "totalInvested": record.totalInvested as Any? ?? NSNull(),
                "profitLoss": record.profitLoss as Any? ?? NSNull(),
                "sharpeRatio": record.sharpeRatio as Any? ?? NSNull(), "tradeCount": record.tradeCount,
                "points": try JSONSerialization.jsonObject(with: record.pointsJSON),
                "config": try JSONSerialization.jsonObject(with: record.configJSON)]
            let data = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
        } catch { onError("导出失败：\(error.localizedDescription)") }
    }
}

private struct NativeQuantForwardValidation: View {
    @Environment(\.dismiss) private var dismiss
    let templateID: String
    @State private var response: PublicForwardValidationResponse?
    @State private var error: String?
    @State private var isLoading = true
    var body: some View {
        VStack(alignment: .leading, spacing: NativeStyle.Space.section) {
            HStack {
                Text("前瞻跟踪").font(NativeStyle.FontRole.sectionTitle)
                Spacer()
                Button("完成") { dismiss() }
            }
            if isLoading { ProgressView().controlSize(.small) }
            if let error { Text(error).font(NativeStyle.FontRole.body).foregroundStyle(AssetTheme.accentOrange) }
            if let response {
                let strategies = response.strategies.filter { $0.strategyID == templateID }
                if strategies.isEmpty { Text("暂无前瞻记录").foregroundStyle(NativeHomeStyle.secondary) }
                ForEach(strategies) { strategy in
                    VStack(alignment: .leading, spacing: NativeStyle.Space.lg) {
                        Text(strategy.strategyName).font(NativeStyle.FontRole.emphasis)
                        LabeledContent("版本", value: strategy.strategyVersion)
                        LabeledContent("冻结日期", value: strategy.frozenAt)
                        LabeledContent("信号日期", value: strategy.latestSignalDate)
                        LabeledContent("新增交易日", value: "\(strategy.newSessions)")
                        LabeledContent("目标现金", value: NativeQuantFormat.percent(strategy.latestDesiredCashWeight))
                    }.font(NativeStyle.FontRole.body)
                }
                Divider()
                HStack(spacing: NativeStyle.Space.xl) {
                    ForEach(response.milestones) { milestone in
                        Label(milestone.label, systemImage: milestone.reached ? "checkmark.circle.fill" : "circle")
                            .font(NativeStyle.FontRole.caption).foregroundStyle(milestone.reached ? NativeHomeStyle.accent : NativeHomeStyle.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }.padding(NativeStyle.Space.page).frame(width: 560, height: 420).modifier(NativeWorkspaceSurface())
            .task {
                defer { isLoading = false }
                guard !AppPreviewSession.isActive else { error = "样例不读取实时跟踪数据"; return }
                do { response = try await RemoteMarketClient.fetchForwardValidation() }
                catch { self.error = "读取失败：\(error.localizedDescription)" }
            }
    }
}

@MainActor
extension NativeQuantExport {
    static func posterData(record: BacktestRecord) -> Data? {
        let renderer = ImageRenderer(content: NativeQuantPoster(record: record).environment(\.colorScheme, NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
    static func writePoster(record: BacktestRecord, onError: (String) -> Void) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "回测-\(record.id.uuidString.prefix(8)).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = posterData(record: record) else { onError("图片生成失败"); return }
        do { try data.write(to: url, options: .atomic) }
        catch { onError("导出失败：\(error.localizedDescription)") }
    }
}

private struct NativeQuantPoster: View {
    let record: BacktestRecord
    var body: some View {
        VStack(alignment: .leading, spacing: NativeStyle.Space.page) {
            HStack(spacing: NativeStyle.Space.lg) {
                Image("brand_logo").resizable().scaledToFit().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: NativeStyle.Space.sm) {
                    Text("资产时光机").font(NativeStyle.FontRole.input).foregroundStyle(NativeHomeStyle.secondary)
                    Text(record.subtitle.isEmpty ? record.title : record.subtitle).font(NativeStyle.FontRole.pageTitle)
                }
                Spacer()
                Text("\(NativeQuantFormat.date(record.startDate)) — \(NativeQuantFormat.date(record.endDate))")
                    .font(NativeStyle.FontRole.caption).foregroundStyle(NativeHomeStyle.secondary)
            }
            Rectangle().fill(NativeHomeStyle.line).frame(height: 1)
            HStack(alignment: .firstTextBaseline) {
                metric("总收益", NativeQuantFormat.percent(record.totalReturn), large: true)
                Spacer()
                metric("年化收益", record.annualizedReturn.map(NativeQuantFormat.percent) ?? "—")
                Spacer()
                metric("最大回撤", NativeQuantFormat.percent(record.maxDrawdown))
                Spacer()
                metric("夏普比率", record.sharpeRatio.map { $0.formatted(.number.precision(.fractionLength(2))) } ?? "—")
            }
            Chart(BacktestRecordCodec.decodePoints(from: record)) { point in
                LineMark(x: .value("日期", point.date), y: .value("净值", point.portfolioValue))
                    .foregroundStyle(NativeHomeStyle.accent).lineStyle(StrokeStyle(lineWidth: 2))
            }.chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) }
                .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) }
                .frame(height: 270)
        }.padding(NativeStyle.Space.hero).frame(width: 900, height: 600).foregroundStyle(NativeHomeStyle.text).background(NativeHomeStyle.ink)
    }
    private func metric(_ label: String, _ value: String, large: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: NativeStyle.Space.md) {
            Text(label).font(NativeStyle.FontRole.caption).foregroundStyle(NativeHomeStyle.secondary)
            Text(value).font(large ? NativeStyle.FontRole.largeDisplay : NativeStyle.FontRole.summary).monospacedDigit()
                .foregroundStyle(large ? NativeHomeStyle.accent : NativeHomeStyle.text)
        }
    }
}

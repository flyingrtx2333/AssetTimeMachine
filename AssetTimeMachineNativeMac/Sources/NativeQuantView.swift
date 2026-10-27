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
                header.padding(.bottom, 12)
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
                Button { store.route = "overview" } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("返回量化")
                Text(title).font(NativeStyle.FontRole.section).lineLimit(1).help(title)
            } else {
                ForEach(BacktestRecordKind.allCases, id: \.rawValue) { kind in entry(kind) }
            }
            Spacer()
            if store.isWorking {
                ProgressView().controlSize(.small)
                Text(store.progress).font(NativeStyle.FontRole.caption).foregroundStyle(NativePalette.secondary).lineLimit(1)
                    .frame(maxWidth: 180, alignment: .leading)
                Button("取消") { store.cancel() }
            }
            if store.route != "records" {
                Button { store.loadRecords(context); store.route = "records" } label: { Label("回测记录", systemImage: "clock.arrow.circlepath") }
            }
        }.controlSize(.small).frame(height: 28)
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
            Text("最近回测").font(NativeStyle.FontRole.section).padding(.bottom, 8)
            recordHeadings
            if store.records.isEmpty {
                Text("暂无回测记录").foregroundStyle(NativePalette.secondary).padding(.vertical, 16)
            } else {
                ForEach(Array(store.records.prefix(5).enumerated()), id: \.element.id) { index, record in
                    recordRow(record, index: index)
                }
            }
        }
    }
    private func entry(_ kind: BacktestRecordKind) -> some View {
        Button(kind.title) { store.show(kind) }.accessibilityLabel(kind.title)
    }
    private var recordList: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("搜索记录", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                Spacer()
                Picker("类型", selection: $historyKind) {
                    Text("全部").tag("all")
                    ForEach(BacktestRecordKind.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }.labelsHidden().frame(width: 130)
            }.padding(.bottom, 12)
            let records = store.records.filter { record in
                (historyKind == "all" || record.kindRawValue == historyKind)
                && (search.isEmpty || "\(record.title) \(record.subtitle) \(record.configSummary)".localizedCaseInsensitiveContains(search))
            }
            recordHeadings
            if records.isEmpty { Text("暂无记录").foregroundStyle(NativePalette.secondary).padding(20) }
            ForEach(Array(records.enumerated()), id: \.element.id) { index, record in recordRow(record, index: index) }
        }
        .animation(NativeStyle.Motion.quant(reducesMotion), value: search)
        .animation(NativeStyle.Motion.quant(reducesMotion), value: historyKind)
    }
    private var recordHeadings: some View {
        HStack(spacing: 12) {
            Text("名称").frame(maxWidth: .infinity, alignment: .leading)
            Text("回测区间").frame(width: 210, alignment: .leading)
            Text("总收益").frame(width: 88, alignment: .trailing)
            Color.clear.frame(width: 26, height: 1)
        }.font(NativeStyle.FontRole.caption).foregroundStyle(NativePalette.secondary)
            .padding(.horizontal, 10).frame(height: 26).background(NativePalette.sidebar)
    }
    private func recordRow(_ record: BacktestRecord, index: Int) -> some View {
        HStack(spacing: 12) {
            Button {
                store.result = record; store.route = "result"
            } label: {
                HStack(spacing: 12) {
                    Text(record.subtitle.isEmpty ? record.title : record.subtitle).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(NativeQuantFormat.date(record.startDate)) — \(NativeQuantFormat.date(record.endDate))")
                        .font(NativeStyle.FontRole.caption).foregroundStyle(NativePalette.secondary)
                        .frame(width: 210, alignment: .leading)
                    Text(NativeQuantFormat.percent(record.totalReturn)).monospacedDigit()
                        .foregroundStyle(record.totalReturn >= 0 ? NativePalette.text : AssetTheme.negative)
                        .frame(width: 88, alignment: .trailing)
                }.frame(height: 28).contentShape(Rectangle())
            }.accessibilityLabel("\(record.subtitle.isEmpty ? record.title : record.subtitle)，\(NativeQuantFormat.percent(record.totalReturn))")
                .buttonStyle(.plain).help(record.subtitle.isEmpty ? record.title : record.subtitle)
            Menu {
                Button("恢复参数") { store.restore(record) }
                Button("导出数据") { NativeQuantExport.write(record: record) { store.error = $0 } }
                Button("删除", role: .destructive) { pendingDelete = record }
            } label: { Image(systemName: "ellipsis").frame(width: 26, height: 26) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("回测记录菜单")
        }.padding(.horizontal, 10).frame(height: 28)
            .background(index.isMultiple(of: 2) ? NativePalette.surface : NativePalette.sidebar.opacity(0.45))
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
        VStack(alignment: .leading, spacing: 14) {
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
        VStack(alignment: .leading, spacing: 12) {
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
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                percentInput("现金", value: config.cashWeight)
                percentInput("黄金", value: config.goldWeight)
                ForEach(BacktestDefaults.indexOptions) { option in
                    percentInput(option.title, value: Binding(get: { store.config.indexWeights[option.symbol, default: 0] }, set: { store.config.indexWeights[option.symbol] = $0 }))
                }
            }
        }
    }
    private var dca: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("定投设置").font(NativeStyle.FontRole.subheading)
            Picker("资产", selection: config.dcaSymbol) {
                ForEach(market.backtestAssetOptions) { Text($0.title).tag($0.symbol) }
            }.frame(maxWidth: 420)
            HStack(spacing: 20) {
                numberInput("每期金额", value: config.contribution, suffix: "元")
                HStack(spacing: 8) {
                    Text("间隔").foregroundStyle(NativePalette.secondary)
                    HStack {
                        TextField("天数", value: config.intervalDays, format: .number).textFieldStyle(.roundedBorder).frame(width: 100)
                        Text("天").font(NativeStyle.FontRole.caption).foregroundStyle(NativeHomeStyle.secondary)
                    }
                }
            }
        }
    }
    private var advanced: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(selectedTemplate?.title ?? "自定义策略").font(NativeStyle.FontRole.section).lineLimit(1)
                Spacer()
                if selectedTemplate != nil { Button("前瞻跟踪") { showsValidation = true } }
                Button("策略库", systemImage: "square.grid.2x2") { showsLibrary = true }
                Button("自定义") { store.config.templateID = "custom"; store.config.mode = .ruleBased }
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                numberInput("初始资金", value: config.initialCash, suffix: "元")
                if !store.config.mode.isRotation { numberInput("单次金额", value: config.tradeAmount, suffix: "元") }
                percentInput("仓位上限", value: config.maxPosition)
                percentInput("交易费率", value: config.fee)
                percentInput("滑点", value: config.slippage)
                HStack(spacing: 8) {
                    Text("冷却天数").font(NativeStyle.FontRole.caption).foregroundStyle(NativePalette.secondary)
                        .frame(width: 66, alignment: .leading)
                    TextField("天数", value: config.cooldown, format: .number).textFieldStyle(.roundedBorder)
                }.frame(height: 28)
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
                Text("资产").font(NativeStyle.FontRole.section)
                Spacer()
                TextField("搜索资产", text: $assetSearch).textFieldStyle(.roundedBorder).frame(width: 200)
            }
            let options = market.backtestAssetOptions + BacktestDefaults.internalStrategyAssetOptions.filter { item in
                !market.backtestAssetOptions.contains(where: { $0.symbol == item.symbol })
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(options.filter { assetSearch.isEmpty || $0.title.localizedCaseInsensitiveContains(assetSearch) || $0.symbol.localizedCaseInsensitiveContains(assetSearch) }) { option in
                    Toggle(isOn: Binding(get: { store.config.selectedSymbols.contains(option.symbol) }, set: { included in
                        if included { store.config.selectedSymbols.insert(option.symbol) }
                        else { store.config.selectedSymbols.remove(option.symbol) }
                    })) {
                        HStack(spacing: 6) {
                            MarketAssetLogoView(asset: option.marketDescriptor, size: 20)
                            Text(option.title)
                        }
                    }.toggleStyle(.checkbox).font(NativeStyle.FontRole.body)
                        .disabled(store.config.mode.requiredSignalAssetSymbols.contains(option.symbol))
                }
            }
        }
    }
    private func ruleInput(_ label: String, direction: Binding<AdvancedBacktestSignalDirection>, days: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(NativeStyle.FontRole.caption).foregroundStyle(NativeHomeStyle.secondary)
            Picker(label, selection: direction) {
                ForEach(AdvancedBacktestSignalDirection.allCases) { Text($0.localizedTitle).tag($0) }
            }.labelsHidden()
            Stepper("连续 \(days.wrappedValue) 天", value: days, in: 1...250).font(NativeStyle.FontRole.caption)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func percentInput(_ title: String, value: Binding<Double>) -> some View { numberInput(title, value: value, suffix: "%") }
    private func numberInput(_ title: String, value: Binding<Double>, suffix: String) -> some View {
        HStack(spacing: 8) {
            Text(title).font(NativeStyle.FontRole.caption).foregroundStyle(NativePalette.secondary)
                .frame(width: 66, alignment: .leading)
            HStack(spacing: NativeStyle.Space.sm) {
                TextField(title, value: value, format: .number.precision(.fractionLength(0...4))).textFieldStyle(.roundedBorder)
                Text(suffix).font(NativeStyle.FontRole.caption).foregroundStyle(NativeHomeStyle.secondary)
            }
        }.frame(height: 28)
    }
}

private struct NativeQuantStrategyLibrary: View {
    @Environment(\.dismiss) private var dismiss
    let selectedID: String
    let select: (AdvancedBacktestStrategyTemplate) -> Void
    @State private var search = ""
    @State private var group = "selected"
    @State private var highlightedID: String?
    @State private var showsReference = false
    @FocusState private var searchFocused: Bool
    @FocusState private var focusedStrategyID: String?

    init(selectedID: String, select: @escaping (AdvancedBacktestStrategyTemplate) -> Void) {
        self.selectedID = selectedID; self.select = select
        _group = State(initialValue: BacktestProductStrategyCatalog.isBasicTemplateID(selectedID) ? "basic" : "selected")
        _highlightedID = State(initialValue: selectedID)
    }

    private var templates: [AdvancedBacktestStrategyTemplate] {
        AdvancedBacktestStrategyTemplate.productCatalog.filter {
            let basic = BacktestProductStrategyCatalog.isBasicTemplateID($0.id)
            return (group == "selected" ? !basic : basic)
                && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search))
        }
    }
    private var highlightedTemplate: AdvancedBacktestStrategyTemplate? {
        templates.first { $0.id == highlightedID }
    }
    private var sheetHeight: CGFloat { min(420, max(220, 172 + CGFloat(templates.count) * 28)) }
    var body: some View {
        NativeSheet("策略库", width: 620, height: sheetHeight, close: { dismiss() }) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Picker("分组", selection: $group) {
                        Text("精选").tag("selected"); Text("基础").tag("basic")
                    }.pickerStyle(.segmented).frame(width: 180).labelsHidden()
                    Spacer(minLength: 12)
                    TextField("搜索策略", text: $search).textFieldStyle(.roundedBorder).focused($searchFocused)
                        .frame(maxWidth: 230)
                }.frame(height: 28).padding(.bottom, 8)
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Color.clear.frame(width: 18, height: 1)
                        Text("策略").frame(maxWidth: .infinity, alignment: .leading)
                        Text("年化").frame(width: 72, alignment: .trailing)
                        Text("最大回撤").frame(width: 84, alignment: .trailing)
                        Text("夏普").frame(width: 56, alignment: .trailing)
                    }.frame(height: 24).font(NativeStyle.FontRole.caption).foregroundStyle(NativePalette.secondary)
                        .padding(.horizontal, 8).background(NativePalette.sidebar)
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                if templates.isEmpty {
                                    Text("未找到策略").font(NativeStyle.FontRole.body).foregroundStyle(NativePalette.secondary)
                                        .frame(maxWidth: .infinity, minHeight: 48)
                                }
                                ForEach(Array(templates.enumerated()), id: \.element.id) { index, template in
                                    row(template, index: index).id(template.id)
                                }
                            }
                        }
                        .onChange(of: highlightedID, initial: true) { _, id in
                            if let id { proxy.scrollTo(id) }
                        }
                    }
                }.overlay(Rectangle().strokeBorder(NativePalette.line.opacity(0.65), lineWidth: 0.5).allowsHitTesting(false))
                HStack(spacing: 8) {
                    if let current = highlightedTemplate {
                        if let period = current.performancePeriod {
                            Text(period)
                            Text("全历史回测")
                        } else {
                            Text(metricStatus(current) ?? current.metricReferenceDetails).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    Button { showsReference.toggle() } label: { Label("口径", systemImage: "info.circle") }
                        .buttonStyle(.borderless).disabled(highlightedTemplate == nil)
                        .popover(isPresented: $showsReference) {
                            if let current = highlightedTemplate {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(current.title).font(NativeStyle.FontRole.bodyStrong)
                                    Text(metricStatus(current) ?? current.metricReferenceDetails)
                                }.font(NativeStyle.FontRole.caption).textSelection(.enabled)
                                    .padding(16).frame(width: 320, alignment: .leading)
                            }
                        }
                }.font(NativeStyle.FontRole.caption).foregroundStyle(NativePalette.secondary)
                    .frame(height: 28).padding(.top, 8)
            }
        }
        .background {
            NativeStrategyLibraryKeys(handle: handleKey).frame(width: 0, height: 0)
        }
        .onAppear { searchFocused = true }
        .onChange(of: templates.map(\.id), initial: true) { _, ids in
            guard !ids.contains(highlightedID ?? "") else { return }
            highlightedID = ids.contains(selectedID) ? selectedID : ids.first
        }
        .onChange(of: focusedStrategyID) { _, id in
            if let id { highlightedID = id }
        }
        .onExitCommand { dismiss() }
    }

    private func handleKey(_ keyCode: UInt16) -> Bool {
        let visible = templates
        guard !visible.isEmpty else { return false }
        switch keyCode {
        case 125, 126:
            let step = keyCode == 125 ? 1 : -1
            let current = visible.firstIndex(where: { $0.id == highlightedID }) ?? (step > 0 ? -1 : visible.count)
            highlightedID = visible[min(max(current + step, 0), visible.count - 1)].id
            return true
        case 36, 76:
            guard let template = visible.first(where: { $0.id == highlightedID }) else { return false }
            select(template)
            return true
        default:
            return false
        }
    }

    private func metricStatus(_ template: AdvancedBacktestStrategyTemplate) -> String? {
        guard template.performancePeriod == nil, template.annualizedReturn == 0,
              template.maxDrawdown == 0, template.sharpeRatio == 0 else { return nil }
        switch template.mode {
        case .nfciDualCoreV1, .nfciDualCoreSimplifiedV11:
            return AppLocalization.string("前瞻观察")
        case .nfciDualCoreSimplifiedV11QualRole:
            return AppLocalization.string("研究中")
        default:
            return AppLocalization.string("暂无回测指标")
        }
    }

    private func row(_ template: AdvancedBacktestStrategyTemplate, index: Int) -> some View {
        let selected = template.id == selectedID
        let highlighted = template.id == highlightedID
        let status = metricStatus(template)
        return Button { select(template) } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark").foregroundStyle(NativePalette.accent).opacity(selected ? 1 : 0).frame(width: 18)
                Text(template.title).font(selected ? NativeStyle.FontRole.bodyStrong : NativeStyle.FontRole.body)
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                if let status {
                    Text(status).font(NativeStyle.FontRole.caption).foregroundStyle(NativePalette.secondary)
                        .frame(width: 228, alignment: .trailing)
                } else {
                    Text(template.annualizedReturn.formatted(.percent.precision(.fractionLength(2))))
                        .frame(width: 72, alignment: .trailing)
                    Text(template.maxDrawdown.formatted(.percent.precision(.fractionLength(2))))
                        .frame(width: 84, alignment: .trailing)
                    Text(template.sharpeRatio.formatted(.number.precision(.fractionLength(2))))
                        .frame(width: 56, alignment: .trailing)
                }
            }
            .monospacedDigit().padding(.horizontal, 8).frame(height: 28)
            .background(selected ? NativePalette.softGold.opacity(0.65) :
                            (index.isMultiple(of: 2) ? NativePalette.surface : NativePalette.sidebar.opacity(0.45)))
            .overlay(Rectangle().strokeBorder(highlighted && !selected ? NativePalette.accent.opacity(0.65) : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focusedStrategyID, equals: template.id)
        .help(status ?? template.metricReferenceDetails)
        .accessibilityLabel(template.title)
        .accessibilityValue(status ?? template.subtitle)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Search-field arrows reach the list without intercepting keys in another window or an IME.
private struct NativeStrategyLibraryKeys: NSViewRepresentable {
    let handle: (UInt16) -> Bool
    func makeNSView(context: Context) -> KeyView { KeyView() }
    func updateNSView(_ view: KeyView, context: Context) { view.handle = handle }
    static func dismantleNSView(_ view: KeyView, coordinator: ()) { view.stop() }

    final class KeyView: NSView {
        var handle: (UInt16) -> Bool = { _ in false }
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      NSApp.isActive, window.isKeyWindow, window.attachedSheet == nil,
                      event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return event }
                if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
                return self.handle(event.keyCode) ? nil : event
            }
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
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
    @State private var showsSources = false
    @State private var reloadToken = 0
    @FocusState private var strategyPickerFocused: Bool
    @State private var snapshotError: String?
    private var reducesMotion: Bool { reducedMotion || NativeHomeStyle.previewReduced }
    private var taskID: String {
        let symbols = StrategyRebalanceDefaults.template(for: templateID).map { StrategyRebalanceDefaults.historySymbols(for: $0) } ?? []
        return "\(templateID)|\(reloadToken)|\(market.strategyInputRelevanceToken(for: symbols))"
    }
    private var investmentBase: Double? { projection.actions.compactMap(\.investmentBase).first }
    private var currentCashWeight: Double? {
        guard projection.actions.contains(where: { $0.currentWeight != nil }) else { return nil }
        return max(0, 1 - projection.actions.compactMap(\.currentWeight).reduce(0, +))
    }
    private var currentCashAmount: Double? {
        investmentBase.map { max(0, $0 - projection.actions.compactMap(\.currentAmount).reduce(0, +)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("今日持仓建议").font(NativeStyle.FontRole.section)
                Spacer(minLength: 12)
                Button { showsLibrary = true } label: {
                    HStack(spacing: 6) {
                        Text(StrategyRebalanceDefaults.template(for: templateID)?.title ?? "选择策略").lineLimit(1)
                        Image(systemName: "chevron.down").font(NativeStyle.FontRole.caption)
                    }
                }
                .accessibilityLabel("选择持仓建议策略")
                .accessibilityValue(StrategyRebalanceDefaults.template(for: templateID)?.title ?? AppLocalization.string("选择策略"))
                .focusable()
                .focused($strategyPickerFocused)
                Button {
                    if projection.isRefreshing { projection.cancel() } else { reloadToken += 1 }
                } label: {
                    Image(systemName: projection.isRefreshing ? "xmark" : "arrow.clockwise")
                }.accessibilityLabel(projection.isRefreshing ? "取消刷新" : "刷新持仓建议")
                Button {
                    showsAmounts.toggle()
                } label: {
                    Image(systemName: showsAmounts ? "eye.slash" : "eye")
                }.accessibilityLabel(showsAmounts ? "隐藏金额" : "显示金额")
            }.controlSize(.small).frame(height: 28)
            if projection.isRefreshing {
                HStack(spacing: 8) {
                    ProgressView(value: projection.progressFraction).frame(width: 120)
                        .accessibilityLabel("今日策略生成进度")
                    Text(projection.progressFraction, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit().frame(width: 34, alignment: .trailing)
                    Text(projection.progressMessage).lineLimit(1)
                }.font(NativeStyle.FontRole.caption).foregroundStyle(NativePalette.secondary)
            }
            if let snapshotError {
                Text(snapshotError).foregroundStyle(AssetTheme.negative).fixedSize(horizontal: false, vertical: true)
            }
            if let status = projection.statusMessage {
                Text(status).foregroundStyle(NativePalette.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let advice = projection.advice {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Text("资产").frame(maxWidth: .infinity, alignment: .leading)
                        Text("当前").frame(width: 140, alignment: .trailing)
                        Text("目标").frame(width: 140, alignment: .trailing)
                        Text("操作").frame(width: 72, alignment: .trailing)
                        if showsAmounts { Text("操作金额").frame(width: 104, alignment: .trailing) }
                    }
                    .font(NativeStyle.FontRole.caption).foregroundStyle(NativePalette.secondary)
                    .padding(.horizontal, 10).frame(height: 26).background(NativePalette.sidebar)
                    ForEach(Array(projection.actions.enumerated()), id: \.element.id) { index, action in
                        HStack(spacing: 12) {
                            HStack(spacing: 6) {
                                if let asset = market.assetDescriptor(for: action.symbol) {
                                    MarketAssetLogoView(asset: asset, size: 20)
                                } else {
                                    MarketAssetLogoView(symbol: action.symbol, sectionID: "other", title: action.title, size: 20)
                                }
                                Text(action.title).lineLimit(1).help(action.title)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            NativeQuantWeightCell(weight: action.currentWeight, amount: action.currentAmount,
                                                  showsAmounts: showsAmounts, target: false)
                            NativeQuantWeightCell(weight: action.targetWeight, amount: action.targetAmount,
                                                  showsAmounts: showsAmounts, target: true)
                            Text(action.kind.title).foregroundStyle(action.kind.accent).frame(width: 72, alignment: .trailing)
                            if showsAmounts { Text(action.amountText).monospacedDigit().frame(width: 104, alignment: .trailing) }
                        }
                        .padding(.horizontal, 10).frame(minHeight: showsAmounts ? 38 : 28)
                        .background(index.isMultiple(of: 2) ? NativePalette.surface : NativePalette.sidebar.opacity(0.45))
                    }
                    HStack(spacing: 12) {
                        HStack(spacing: 6) {
                            NativeAssetIcon(key: "icon_cash", group: .financial, title: AppLocalization.string("现金"))
                            Text("现金 / 其他")
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        NativeQuantWeightCell(weight: currentCashWeight, amount: currentCashAmount,
                                              showsAmounts: showsAmounts, target: false)
                        NativeQuantWeightCell(weight: advice.cashWeight, amount: investmentBase.map { $0 * advice.cashWeight },
                                              showsAmounts: showsAmounts, target: true)
                        Text("防守仓位").font(NativeStyle.FontRole.caption).foregroundStyle(NativePalette.secondary)
                            .frame(width: 72, alignment: .trailing)
                        if showsAmounts { Text("—").frame(width: 104, alignment: .trailing) }
                    }
                    .padding(.horizontal, 10).frame(minHeight: showsAmounts ? 38 : 28)
                    .background(projection.actions.count.isMultiple(of: 2) ? NativePalette.surface : NativePalette.sidebar.opacity(0.45))
                }
                .overlay(Rectangle().strokeBorder(NativePalette.line.opacity(0.65), lineWidth: 0.5).allowsHitTesting(false))
                HStack(spacing: 12) {
                    Text(AppLocalization.format("信号截至 %@", NativeQuantFormat.date(advice.asOfDate)))
                    if let date = projection.snapshotDate {
                        Text(AppLocalization.format("资产记录 %@", NativeQuantFormat.date(date)))
                    }
                    Spacer(minLength: 0)
                    Button { showsSources.toggle() } label: { Label("口径", systemImage: "info.circle") }
                        .buttonStyle(.borderless)
                        .popover(isPresented: $showsSources) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(advice.strategyTitle).font(NativeStyle.FontRole.bodyStrong)
                                if !projection.historySourceNames.isEmpty {
                                    Text(projection.historySourceNames.joined(separator: " · "))
                                }
                                if let reason = advice.signalReason, !reason.isEmpty { Text(reason) }
                            }.font(NativeStyle.FontRole.caption).textSelection(.enabled)
                                .padding(16).frame(width: 320, alignment: .leading)
                        }
                }.font(NativeStyle.FontRole.caption).foregroundStyle(NativePalette.secondary)
            } else if !projection.isRefreshing && projection.statusMessage == nil {
                Text("暂无持仓建议").foregroundStyle(NativePalette.secondary).padding(.vertical, 16)
            }
        }
        .animation(NativeStyle.Motion.quant(reducesMotion), value: projection.isRefreshing)
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
        .sheet(isPresented: $showsLibrary, onDismiss: { strategyPickerFocused = true }) {
            NativeQuantStrategyLibrary(selectedID: templateID) { template in
                templateID = template.id
                if !AppPreviewSession.isActive { UserDefaults.standard.set(template.id, forKey: "app.strategyNotifications.templateID") }
                showsLibrary = false
            }
        }
    }
}

private struct NativeQuantWeightCell: View {
    let weight: Double?
    let amount: Double?
    let showsAmounts: Bool
    let target: Bool
    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 8) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(NativePalette.line.opacity(0.6))
                        if let weight, weight.isFinite {
                            Capsule().fill(target ? NativePalette.accent : NativePalette.chartSecondary)
                                .frame(width: geometry.size.width * min(max(weight, 0), 1))
                        }
                    }
                }.frame(width: 48, height: 4).accessibilityHidden(true)
                Text(weight.map(NativeQuantFormat.percent) ?? "—").monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if showsAmounts {
                Text(amount.map(NativeHomeStyle.amount) ?? "—")
                    .font(NativeStyle.FontRole.caption).foregroundStyle(NativePalette.secondary)
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            }
        }.frame(width: 140, alignment: .trailing)
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
        VStack(alignment: .leading, spacing: 14) {
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
            HStack(alignment: .firstTextBaseline, spacing: 24) {
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
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(Array((config?.advancedBenchmarkSeries ?? []).enumerated()), id: \.element.id) { index, benchmark in
                        HStack(spacing: 5) {
                            Circle().fill(benchmarkColor(index)).frame(width: 4, height: 4)
                            Text(benchmark.title).font(NativeStyle.FontRole.micro).foregroundStyle(NativeHomeStyle.secondary)
                        }
                    }
                }
            }
            resultChart.frame(height: 210)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)], alignment: .leading, spacing: 12) {
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
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 12) {
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
                        }.padding(.vertical, 6)
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
        [NativePalette.chartSecondary, AssetTheme.positive.opacity(0.8), NativePalette.text.opacity(0.5)][index % 3]
    }
    private func normalizedBenchmark(_ value: Double, series: BacktestRecordAdvancedBenchmarkSeriesPayload) -> Double {
        guard let first = series.points.first?.value, first > 0 else { return value }
        return value / first * (points.first?.portfolioValue ?? 1)
    }
    private func chartLabel(_ value: Double) -> String {
        record.kindRawValue == "allocation" ? "\(value.formatted(.number.precision(.fractionLength(2))))×" : NativeHomeStyle.amount(value)
    }
    private func metric(_ label: String, value: String, primary: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(NativeStyle.FontRole.micro).foregroundStyle(NativeHomeStyle.secondary)
            Text(value).font(primary ? .system(size: 24, weight: .medium) : NativeStyle.FontRole.metric).monospacedDigit()
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
    @State private var reload = 0
    var body: some View {
        NativeSheet("前瞻跟踪", width: 520, height: response == nil ? 200 : 360, close: { dismiss() }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if isLoading { ProgressView().controlSize(.small) }
                    if let error {
                        HStack(alignment: .top) {
                            Text(error).foregroundStyle(AssetTheme.negative).textSelection(.enabled)
                            Spacer()
                            Button("重试") { reload += 1 }
                        }
                    }
                    if let response {
                        let strategies = response.strategies.filter { $0.strategyID == templateID }
                        if strategies.isEmpty { Text("暂无前瞻记录").foregroundStyle(NativePalette.secondary) }
                        ForEach(strategies) { strategy in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(strategy.strategyName).font(NativeStyle.FontRole.section)
                                LabeledContent("版本", value: strategy.strategyVersion)
                                LabeledContent("冻结日期", value: strategy.frozenAt)
                                LabeledContent("信号日期", value: strategy.latestSignalDate)
                                LabeledContent("新增交易日", value: "\(strategy.newSessions)")
                                LabeledContent("目标现金", value: NativeQuantFormat.percent(strategy.latestDesiredCashWeight))
                            }
                        }
                        Divider()
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], alignment: .leading, spacing: 8) {
                            ForEach(response.milestones) { milestone in
                                Label(milestone.label, systemImage: milestone.reached ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(milestone.reached ? NativePalette.accent : NativePalette.secondary)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onExitCommand { dismiss() }
        .task(id: reload) {
            isLoading = true; error = nil
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

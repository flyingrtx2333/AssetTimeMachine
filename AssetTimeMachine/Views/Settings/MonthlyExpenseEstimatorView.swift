import SwiftUI

enum FixedExpenseFrequency: String, Codable, CaseIterable, Identifiable {
    case monthly
    case annual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .monthly:
            return AppLocalization.string("每月")
        case .annual:
            return AppLocalization.string("每年")
        }
    }
}

struct FixedExpenseLine: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var amountText: String
    var frequency: FixedExpenseFrequency

    init(
        id: UUID = UUID(),
        name: String = "",
        amountText: String = "",
        frequency: FixedExpenseFrequency = .monthly
    ) {
        self.id = id
        self.name = name
        self.amountText = amountText
        self.frequency = frequency
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case amountText
        case frequency
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        amountText = try container.decodeIfPresent(String.self, forKey: .amountText) ?? ""
        frequency = try container.decodeIfPresent(FixedExpenseFrequency.self, forKey: .frequency) ?? .monthly
    }

    var amount: Double {
        let trimmed = amountText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }

        let formatter = NumberFormatter()
        formatter.locale = .current
        formatter.numberStyle = .decimal
        formatter.generatesDecimalNumbers = true

        let localizedValue = formatter.number(from: trimmed)?.doubleValue
        let fallbackValue = Double(
            trimmed
                .replacingOccurrences(of: "，", with: ",")
                .replacingOccurrences(of: ",", with: "")
        )
        guard let value = localizedValue ?? fallbackValue, value.isFinite else { return 0 }
        return max(value, 0)
    }

    var monthlyEquivalent: Double {
        frequency == .annual ? amount / 12 : amount
    }
}

struct MonthlyExpenseEstimate: Codable, Equatable {
    var items: [FixedExpenseLine]

    private enum CodingKeys: String, CodingKey {
        case items
        case monthlyItems
        case annualItems
    }

    init(items: [FixedExpenseLine]) {
        self.items = items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let items = try container.decodeIfPresent([FixedExpenseLine].self, forKey: .items) {
            self.items = items
            return
        }

        var monthlyItems = try container.decodeIfPresent([FixedExpenseLine].self, forKey: .monthlyItems) ?? []
        var annualItems = try container.decodeIfPresent([FixedExpenseLine].self, forKey: .annualItems) ?? []
        monthlyItems = monthlyItems.map { item in
            var item = item
            item.frequency = .monthly
            return item
        }
        annualItems = annualItems.map { item in
            var item = item
            item.frequency = .annual
            return item
        }
        items = monthlyItems + annualItems
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(items, forKey: .items)
    }

    var monthlyFixedTotal: Double {
        items
            .filter { $0.frequency == .monthly }
            .reduce(0) { $0 + $1.amount }
    }

    var annualFixedTotal: Double {
        items
            .filter { $0.frequency == .annual }
            .reduce(0) { $0 + $1.amount }
    }

    var annualMonthlyAverage: Double {
        annualFixedTotal / 12
    }

    var monthlyAverage: Double {
        monthlyFixedTotal + annualMonthlyAverage
    }
}

enum MonthlyExpenseEstimateStorage {
    static let defaultsKey = "settings.monthlyExpenseEstimate.v1"

    static func decode(_ rawValue: String) -> MonthlyExpenseEstimate? {
        guard let data = rawValue.data(using: .utf8), !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(MonthlyExpenseEstimate.self, from: data)
    }

    static func encode(_ estimate: MonthlyExpenseEstimate) -> String? {
        guard let data = try? JSONEncoder().encode(estimate) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func monthlyAverage(from rawValue: String, fallback: Double) -> Double {
        decode(rawValue)?.monthlyAverage ?? fallback
    }
}

private enum ExpenseListFilter: String, CaseIterable, Identifiable {
    case all
    case monthly
    case annual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return AppLocalization.string("全部")
        case .monthly:
            return AppLocalization.string("每月")
        case .annual:
            return AppLocalization.string("每年")
        }
    }

    func includes(_ frequency: FixedExpenseFrequency) -> Bool {
        switch self {
        case .all:
            return true
        case .monthly:
            return frequency == .monthly
        case .annual:
            return frequency == .annual
        }
    }
}

private enum ExpenseEstimatorField: Hashable {
    case name(UUID)
    case amount(UUID)
    case draftName
    case draftAmount
}

struct MonthlyExpenseEstimatorView: View {
    @AppStorage(MonthlyExpenseEstimateStorage.defaultsKey) private var storedEstimate = ""
    @AppStorage("dashboard.monthlyExpense") private var dashboardMonthlyExpense: Double = 3000

    @State private var items: [FixedExpenseLine] = []
    @State private var filter: ExpenseListFilter = .all
    @State private var draftName = ""
    @State private var draftAmountText = ""
    @State private var draftFrequency: FixedExpenseFrequency = .monthly
    @State private var didLoad = false
    @FocusState private var focusedField: ExpenseEstimatorField?

    private var estimate: MonthlyExpenseEstimate {
        MonthlyExpenseEstimate(items: items)
    }

    private var visibleItemCount: Int {
        items.count(where: { filter.includes($0.frequency) })
    }

    private var draftItem: FixedExpenseLine {
        FixedExpenseLine(
            name: draftName,
            amountText: draftAmountText,
            frequency: draftFrequency
        )
    }

    private var canAddDraft: Bool {
        !draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draftItem.amount > 0
    }

    var body: some View {
        ZStack {
            AssetTheme.background.ignoresSafeArea()

            List {
                Section {
                    ExpenseLedgerHeader(
                        monthlyAverage: estimate.monthlyAverage,
                        itemCount: items.count,
                        filter: $filter
                    )
                    .listRowInsets(EdgeInsets(top: 12, leading: 22, bottom: 10, trailing: 22))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }

                Section {
                    if visibleItemCount == 0 {
                        ExpenseFilterEmptyRow(filter: filter)
                            .expenseLedgerRow()
                    } else {
                        ForEach($items) { $item in
                            if filter.includes(item.frequency) {
                                FixedExpenseLedgerRow(
                                    item: $item,
                                    focusedField: $focusedField
                                )
                                .expenseLedgerRow()
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        deleteItem(item.id)
                                    } label: {
                                        Label(AppLocalization.string("删除"), systemImage: "trash")
                                    }
                                }
                                .accessibilityAction(named: AppLocalization.string("删除")) {
                                    deleteItem(item.id)
                                }
                            }
                        }
                    }

                    ExpenseDraftRow(
                        name: $draftName,
                        amountText: $draftAmountText,
                        frequency: $draftFrequency,
                        focusedField: $focusedField,
                        canAdd: canAddDraft,
                        onAdd: addDraft
                    )
                    .expenseLedgerRow()
                }

                Color.clear
                    .frame(height: 72)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .listSectionSpacing(.custom(8))
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .environment(\.defaultMinListRowHeight, 58)
        }
        .navigationTitle(AppLocalization.string("月开支估算"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(AppLocalization.string("完成")) {
                    focusedField = nil
                    dismissActiveKeyboard()
                }
                .font(AppTypography.rowTitle)
                .foregroundStyle(AssetTheme.gold)
            }
        }
        .onAppear(perform: loadEstimate)
        .onChange(of: items) { _, _ in persistEstimate() }
        .onChange(of: filter) { _, newValue in
            switch newValue {
            case .all:
                break
            case .monthly:
                draftFrequency = .monthly
            case .annual:
                draftFrequency = .annual
            }
        }
    }

    private func addDraft() {
        guard canAddDraft else { return }
        let item = FixedExpenseLine(
            name: draftName.trimmingCharacters(in: .whitespacesAndNewlines),
            amountText: draftAmountText.trimmingCharacters(in: .whitespacesAndNewlines),
            frequency: draftFrequency
        )
        withAnimation(.easeInOut(duration: 0.18)) {
            items.append(item)
        }
        draftName = ""
        draftAmountText = ""
        focusedField = .draftName
    }

    private func deleteItem(_ id: UUID) {
        if focusedField == .name(id) || focusedField == .amount(id) {
            focusedField = nil
        }
        withAnimation(.easeInOut(duration: 0.18)) {
            items.removeAll(where: { $0.id == id })
        }
    }

    private func loadEstimate() {
        guard !didLoad else { return }

        if let saved = MonthlyExpenseEstimateStorage.decode(storedEstimate) {
            items = saved.items
            didLoad = true
            synchronizeDashboardMonthlyExpense(with: saved.monthlyAverage)
            return
        }

        if dashboardMonthlyExpense > 0 {
            items = [
                FixedExpenseLine(
                    name: AppLocalization.string("日常开支"),
                    amountText: editableAmountText(dashboardMonthlyExpense),
                    frequency: .monthly
                )
            ]
        }
        didLoad = true
        persistEstimate()
    }

    private func persistEstimate() {
        guard didLoad, let encoded = MonthlyExpenseEstimateStorage.encode(estimate) else { return }
        storedEstimate = encoded
        synchronizeDashboardMonthlyExpense(with: estimate.monthlyAverage)
    }

    private func synchronizeDashboardMonthlyExpense(with monthlyAverage: Double) {
        guard abs(dashboardMonthlyExpense - monthlyAverage) > 0.005 else { return }
        dashboardMonthlyExpense = monthlyAverage
    }

    private func editableAmountText(_ value: Double) -> String {
        if abs(value.rounded() - value) < 0.005 {
            return String(Int(value.rounded()))
        }
        return value.formatted(.number.precision(.fractionLength(0...2)).grouping(.never))
    }
}

private struct ExpenseLedgerHeader: View {
    let monthlyAverage: Double
    let itemCount: Int
    @Binding var filter: ExpenseListFilter

    var body: some View {
        VStack(spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(AppLocalization.string("月均开销"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AssetTheme.textSecondary)

                Text(monthlyAverage.currencyString())
                    .font(.system(size: 31, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(AssetTheme.goldSoft)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Spacer(minLength: 10)

                Text(AppLocalization.format("共 %d 项", itemCount))
                    .font(.subheadline)
                    .foregroundStyle(AssetTheme.textSecondary)
                    .lineLimit(1)
            }

            Picker(AppLocalization.string("开支频率"), selection: $filter) {
                ForEach(ExpenseListFilter.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .tint(AssetTheme.gold)
        }
        .padding(.vertical, 6)
    }
}

private struct FixedExpenseLedgerRow: View {
    @Binding var item: FixedExpenseLine
    @FocusState.Binding var focusedField: ExpenseEstimatorField?

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack(spacing: 14) {
                TextField(AppLocalization.string("项目名称"), text: $item.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(AssetTheme.textPrimary)
                    .focused($focusedField, equals: .name(item.id))
                    .submitLabel(.next)
                    .onSubmit {
                        focusedField = .amount(item.id)
                    }

                HStack(spacing: 3) {
                    Text("¥")
                        .font(.subheadline)
                        .foregroundStyle(AssetTheme.textSecondary)

                    TextField("0", text: $item.amountText)
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(AssetTheme.textPrimary)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.decimalPad)
                        .focused($focusedField, equals: .amount(item.id))
                        .frame(width: 92)
                }

                ExpenseFrequencyMenu(frequency: $item.frequency)
            }

            if item.frequency == .annual, item.amount > 0 {
                Text(AppLocalization.format(
                    "折合 %@/月",
                    (item.amount / 12).currencyString()
                ))
                .font(AppTypography.caption)
                .monospacedDigit()
                .foregroundStyle(AssetTheme.textSecondary)
                .lineLimit(1)
                .padding(.trailing, 72)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .frame(minHeight: 66)
    }
}

private struct ExpenseDraftRow: View {
    @Binding var name: String
    @Binding var amountText: String
    @Binding var frequency: FixedExpenseFrequency
    @FocusState.Binding var focusedField: ExpenseEstimatorField?
    let canAdd: Bool
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            TextField(AppLocalization.string("项目名称"), text: $name)
                .font(.body.weight(.medium))
                .foregroundStyle(AssetTheme.textPrimary)
                .focused($focusedField, equals: .draftName)
                .submitLabel(.next)
                .onSubmit {
                    focusedField = .draftAmount
                }

            TextField(AppLocalization.string("金额"), text: $amountText)
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(AssetTheme.textPrimary)
                .multilineTextAlignment(.trailing)
                .keyboardType(.decimalPad)
                .focused($focusedField, equals: .draftAmount)
                .frame(width: 78)

            ExpenseFrequencyMenu(frequency: $frequency)

            Button(action: onAdd) {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(canAdd ? Color.black.opacity(0.82) : AssetTheme.textSecondary)
                    .frame(width: 36, height: 36)
                    .background(canAdd ? AssetTheme.gold : AssetTheme.surfaceRaised, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canAdd)
            .accessibilityLabel(AppLocalization.string("添加开支"))
        }
        .frame(minHeight: 62)
    }
}

private struct ExpenseFrequencyMenu: View {
    @Binding var frequency: FixedExpenseFrequency

    var body: some View {
        Menu {
            Picker(AppLocalization.string("开支频率"), selection: $frequency) {
                ForEach(FixedExpenseFrequency.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(frequency.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(AssetTheme.gold)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(AssetTheme.gold.opacity(0.09), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct ExpenseFilterEmptyRow: View {
    let filter: ExpenseListFilter

    private var title: String {
        switch filter {
        case .all:
            return AppLocalization.string("暂无固定开支")
        case .monthly:
            return AppLocalization.string("暂无月固定开支")
        case .annual:
            return AppLocalization.string("暂无年固定开支")
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(AssetTheme.textSecondary)

            Text(title)
                .font(.subheadline)
                .foregroundStyle(AssetTheme.textSecondary)

            Spacer()
        }
        .frame(minHeight: 58)
    }
}

private extension View {
    func expenseLedgerRow() -> some View {
        listRowInsets(EdgeInsets(top: 0, leading: 22, bottom: 0, trailing: 22))
            .listRowBackground(AssetTheme.surface.opacity(0.36))
            .listRowSeparatorTint(AssetTheme.border.opacity(0.72))
    }
}

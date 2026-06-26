import SwiftUI
import SwiftData
import Charts
import UIKit

struct APIDocumentationView: View {
    @ObservedObject var marketStore: RemoteMarketStore

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        ATMHeader(title: AppLocalization.string("接口文档"), subtitle: AppLocalization.string("供应用与分析模块使用。")) {
                            Button {
                                Task { await marketStore.refresh() }
                            } label: {
                                GoldChip(text: AppLocalization.string("刷新"))
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

struct ATMBackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.footnote.weight(.bold))
                Text(AppLocalization.string("返回"))
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(AssetTheme.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(AssetTheme.overlaySubtle, in: Capsule())
            .overlay(Capsule().stroke(AssetTheme.border.opacity(0.7), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

struct ATMHeader<Trailing: View>: View {
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
                            .fill(AssetTheme.overlaySubtle)
                            .frame(width: 40, height: 40)
                        Image(systemName: "hourglass")
                            .foregroundStyle(AssetTheme.gold)
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(AssetTheme.border, lineWidth: 1)
                    )

                    Text(AppLocalization.string(title))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(AssetTheme.textPrimary)
                }

                if let subtitle, !subtitle.isEmpty {
                    Text(AppLocalization.string(subtitle))
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

enum AppTypography {
    static let eyebrow = Font.system(size: 13, weight: .semibold, design: .rounded)
    static let meta = Font.system(size: 14, weight: .medium, design: .rounded)
    static let sectionTitle = Font.system(size: 20, weight: .bold, design: .rounded)
    static let heroValue = Font.system(size: 40, weight: .bold, design: .rounded)
    static let rowTitle = Font.system(size: 18, weight: .semibold, design: .rounded)
    static let rowValue = Font.system(size: 20, weight: .semibold, design: .rounded)
    static let metricValue = Font.system(size: 18, weight: .semibold, design: .rounded)
}

struct SectionTitle: View {
    let title: String
    let subtitle: String?

    init(title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AppLocalization.string(title))
                .font(AppTypography.sectionTitle)
                .foregroundStyle(AssetTheme.textPrimary)

            if let subtitle, !subtitle.isEmpty {
                Text(AppLocalization.string(subtitle))
                    .font(AppTypography.meta)
                    .foregroundStyle(AssetTheme.textSecondary)
            }
        }
    }
}

struct GoldChip: View {
    let text: String

    var body: some View {
        Text(AppLocalization.string(text))
            .font(AppTypography.eyebrow)
            .foregroundStyle(AssetTheme.goldSoft)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(AssetTheme.gold.opacity(0.12), in: Capsule())
            .overlay(Capsule().stroke(AssetTheme.border, lineWidth: 1))
    }
}

struct InlineStat: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Text(text)
                .font(AppTypography.meta)
                .foregroundStyle(color)
        }
    }
}

struct CompactStat: View {
    let title: String
    let value: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppLocalization.string(title))
                .font(AppTypography.eyebrow)
                .foregroundStyle(AssetTheme.textSecondary)
            Text(value)
                .font(AppTypography.metricValue)
                .monospacedDigit()
                .foregroundStyle(AssetTheme.textPrimary)
                .minimumScaleFactor(0.72)
                .lineLimit(1)
            RoundedRectangle(cornerRadius: 999)
                .fill(accent)
                .frame(width: 28, height: 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AssetTheme.overlaySoft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AssetTheme.border.opacity(0.8), lineWidth: 1)
        )
    }
}

struct HeroSideMetric: View {
    let title: String
    let value: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(accent)
                    .frame(width: 6, height: 6)

                Text(AppLocalization.string(title))
                    .font(AppTypography.eyebrow)
                    .foregroundStyle(AssetTheme.textSecondary)
            }

            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(AssetTheme.textPrimary)
                .minimumScaleFactor(0.72)
                .lineLimit(1)
        }
    }
}

struct MarketPriceRow: View {
    let market: PublicMarketPrice

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)

            Text(displayName)
                .font(AppTypography.rowTitle)
                .foregroundStyle(AssetTheme.textPrimary)

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                Text(market.price.formatted(.number.precision(.fractionLength(2))))
                    .font(AppTypography.rowValue)
                    .monospacedDigit()
                    .foregroundStyle(AssetTheme.textPrimary)
                Text(market.currency)
                    .font(AppTypography.meta)
                    .foregroundStyle(AssetTheme.goldSoft)
            }
        }
        .padding(.vertical, 16)
    }

    private var displayName: String {
        switch market.symbol {
        case "gold": return AppLocalization.string("黄金")
        case "nasdaq": return AppLocalization.string("纳指锚点")
        default: return market.symbol.uppercased()
        }
    }

    private var color: Color {
        switch market.symbol {
        case "gold": return AssetTheme.gold
        case "nasdaq": return AssetTheme.accentBlue
        default: return AssetTheme.textSecondary
        }
    }
}

struct EndpointCard: View {
    let endpoint: MarketEndpointDoc
    let market: PublicMarketPrice?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(AppLocalization.string(endpoint.title))
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

            Text(AppLocalization.string(endpoint.description))
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
                .background(AssetTheme.overlaySoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .atmCardStyle()
    }
}

struct CapabilityRow: View {
    let title: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 28)
            Text(AppLocalization.string(title))
                .foregroundStyle(AssetTheme.textPrimary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AssetTheme.textSecondary)
        }
        .padding(14)
        .background(AssetTheme.overlaySoft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AssetTheme.border.opacity(0.75), lineWidth: 1)
        )
    }
}

struct EmptyStateCard: View {
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
                Text(AppLocalization.string(title))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(AssetTheme.textPrimary)

                if let message, !message.isEmpty {
                    Text(AppLocalization.string(message))
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

struct LoadingStateCard: View {
    let title: String
    let message: String?

    init(title: String, message: String? = nil) {
        self.title = title
        self.message = message
    }

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
                .tint(AssetTheme.gold)

            VStack(spacing: 8) {
                Text(AppLocalization.string(title))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(AssetTheme.textPrimary)

                if let message, !message.isEmpty {
                    Text(AppLocalization.string(message))
                        .font(.subheadline)
                        .foregroundStyle(AssetTheme.textSecondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 420, alignment: .center)
        .padding(.vertical, 26)
    }
}

struct SkeletonLine: View {
    let width: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 999, style: .continuous)
            .fill(AssetTheme.overlayStrong)
            .frame(width: width, height: 14)
    }
}

struct ATMFlowLayout: Layout {
    enum RowAlignment {
        case leading
        case center
    }

    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 8
    var rowAlignment: RowAlignment = .leading

    private struct Row {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0

        var isEmpty: Bool { items.isEmpty }
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let rows = arrangedRows(for: subviews, maxWidth: proposal.width)
        let maxRowWidth = rows.map(\.width).max() ?? 0
        let totalHeight = rows.enumerated().reduce(CGFloat.zero) { partial, item in
            partial + item.element.height + (item.offset == 0 ? 0 : verticalSpacing)
        }

        if let proposedWidth = proposal.width, proposedWidth.isFinite {
            return CGSize(width: proposedWidth, height: totalHeight)
        }
        return CGSize(width: maxRowWidth, height: totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let rows = arrangedRows(for: subviews, maxWidth: bounds.width)
        var y = bounds.minY

        for row in rows {
            let rowX: CGFloat
            switch rowAlignment {
            case .leading:
                rowX = bounds.minX
            case .center:
                rowX = bounds.minX + max((bounds.width - row.width) / 2, 0)
            }
            var x = rowX
            for item in row.items {
                let itemY = y + max((row.height - item.size.height) / 2, 0)
                subviews[item.index].place(
                    at: CGPoint(x: x, y: itemY),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: item.size.width, height: item.size.height)
                )
                x += item.size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }

    private func arrangedRows(for subviews: Subviews, maxWidth proposedMaxWidth: CGFloat?) -> [Row] {
        let maxWidth = proposedMaxWidth?.isFinite == true ? max(proposedMaxWidth ?? 0, 0) : .infinity
        var rows: [Row] = []
        var currentRow = Row()

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let spacing = currentRow.isEmpty ? CGFloat.zero : horizontalSpacing
            let candidateWidth = currentRow.width + spacing + size.width

            if !currentRow.isEmpty, candidateWidth > maxWidth {
                rows.append(currentRow)
                currentRow = Row()
            }

            let itemSpacing = currentRow.isEmpty ? CGFloat.zero : horizontalSpacing
            currentRow.items.append((index, size))
            currentRow.width += itemSpacing + size.width
            currentRow.height = max(currentRow.height, size.height)
        }

        if !currentRow.isEmpty {
            rows.append(currentRow)
        }
        return rows
    }
}

func evenlySampledItems<T>(_ items: [T], maxCount: Int) -> [T] {
    guard maxCount > 2, items.count > maxCount else { return items }

    let lastIndex = items.count - 1
    let step = Double(lastIndex) / Double(maxCount - 1)
    var sampled: [T] = []
    sampled.reserveCapacity(maxCount)

    var previousIndex = -1
    for position in 0..<maxCount {
        let index = min(lastIndex, Int((Double(position) * step).rounded()))
        guard index != previousIndex else { continue }
        sampled.append(items[index])
        previousIndex = index
    }

    if previousIndex != lastIndex {
        sampled.append(items[lastIndex])
    }

    return sampled
}

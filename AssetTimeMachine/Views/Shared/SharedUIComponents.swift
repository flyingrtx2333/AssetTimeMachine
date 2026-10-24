import SwiftUI

/// One treatment for in-page actions; toolbar and icon buttons keep native chrome.
struct ATMActionButtonStyle: ButtonStyle {
    enum Prominence { case primary, secondary }

    var prominence: Prominence = .primary
    var expands = true
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(prominence == .primary ? Color.black.opacity(0.88) : AssetTheme.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: expands ? .infinity : nil, minHeight: 48)
            .background(
                prominence == .primary ? AssetTheme.gold : AssetTheme.surfaceRaised,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                if prominence == .secondary {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(AssetTheme.border, lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.45)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

struct ATMBackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(AppTypography.metaStrong)
                Text(AppLocalization.string("返回"))
                    .font(AppTypography.rowTitle)
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
                        .font(AppTypography.body)
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

    init(title: String, message: String? = nil) {
        self.title = title
    }

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
                .tint(AssetTheme.gold)

            Text(AppLocalization.string(title))
                .font(.title3.weight(.bold))
                .foregroundStyle(AssetTheme.textPrimary)
        }
        .frame(maxWidth: .infinity, minHeight: 420, alignment: .center)
        .padding(.vertical, 26)
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

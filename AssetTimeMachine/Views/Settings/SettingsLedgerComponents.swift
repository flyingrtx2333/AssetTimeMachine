import SwiftUI

/// Local layout treatment; every color comes from the app's adaptive theme.
struct SettingsLedgerButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        #if targetEnvironment(macCatalyst)
        configuration.label
        #else
        configuration.label
            .background(configuration.isPressed && isEnabled ? AssetTheme.overlayMedium : AssetTheme.overlayMedium.opacity(0))
            .opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.45)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: configuration.isPressed)
        #endif
    }
}

#if !targetEnvironment(macCatalyst)
struct SettingsLedgerRule: View {
    var body: some View {
        Rectangle()
            .fill(AssetTheme.border)
            .frame(height: 0.5)
            .accessibilityHidden(true)
    }
}

struct SettingsLedgerHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppLocalization.string("资产时光机"))
                .font(AppTypography.meta)
                .foregroundStyle(AssetTheme.goldSoft)

            Text(AppLocalization.string("设置"))
                .font(AppTypography.pageHero)
                .foregroundStyle(AssetTheme.textPrimary)
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: 3) {
                Rectangle().fill(AssetTheme.gold.opacity(0.55)).frame(height: 0.5)
                SettingsLedgerRule()
            }
            .padding(.top, 4)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsLedgerExpenseRow: View {
    let value: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                label
                Spacer(minLength: 12)
                Rectangle()
                    .fill(AssetTheme.border)
                    .frame(width: 0.5, height: 32)
                    .accessibilityHidden(true)
                amount
                chevron
            }

            VStack(alignment: .leading, spacing: 8) {
                label
                HStack {
                    amount
                    Spacer(minLength: 12)
                    chevron
                }
            }
        }
        .padding(.vertical, 10)
        .frame(minHeight: 54)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var label: some View {
        Text(AppLocalization.string("月开支估算"))
            .font(AppTypography.rowTitle)
            .foregroundStyle(AssetTheme.textPrimary)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var amount: some View {
        Text(value)
            .font(AppTypography.panelHero)
            .monospacedDigit()
            .foregroundStyle(AssetTheme.textPrimary)
            .fixedSize(horizontal: true, vertical: false)
            .contentTransition(.numericText())
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(AppTypography.captionStrong)
            .foregroundStyle(AssetTheme.textSecondary)
            .accessibilityHidden(true)
    }
}

struct SettingsLedgerAppearancePicker: View {
    @Binding var selection: String
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ViewThatFits(in: .horizontal) {
            if !dynamicTypeSize.isAccessibilitySize {
                HStack(spacing: 12) {
                    title
                        .frame(width: 112, alignment: .leading)
                    Rectangle()
                        .fill(AssetTheme.border)
                        .frame(width: 0.5, height: 80)
                        .accessibilityHidden(true)
                    choices
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                title
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 8) {
                        ForEach(AppAppearanceMode.allCases) { mode in
                            accessibleChoice(mode)
                        }
                    }
                } else {
                    choices
                }
            }
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
    }

    private var title: some View {
        Text(AppLocalization.string("外观"))
            .font(AppTypography.rowTitle)
            .foregroundStyle(AssetTheme.textPrimary)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var choices: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(AppAppearanceMode.allCases) { mode in
                Button {
                    select(mode)
                } label: {
                    VStack(spacing: 7) {
                        SettingsLedgerAppearanceSample()
                            .environment(\.colorScheme, mode.colorScheme ?? colorScheme)
                            .frame(height: 58)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .overlay {
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(selection == mode.rawValue ? AssetTheme.gold : AssetTheme.border,
                                            lineWidth: selection == mode.rawValue ? 1.5 : 0.5)
                            }

                        Text(mode.title)
                            .font(AppTypography.caption)
                            .foregroundStyle(selection == mode.rawValue ? AssetTheme.textPrimary : AssetTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 80)
                    .contentShape(Rectangle())
                }
                .buttonStyle(SettingsLedgerButtonStyle())
                .accessibilityLabel(mode.title)
                .accessibilityAddTraits(selection == mode.rawValue ? .isSelected : [])
                .accessibilityIdentifier("settings.appearance.\(mode.rawValue)")
            }
        }
    }

    private func accessibleChoice(_ mode: AppAppearanceMode) -> some View {
        Button {
            select(mode)
        } label: {
            HStack(spacing: 12) {
                Text(mode.title)
                    .font(.body)
                    .foregroundStyle(AssetTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if selection == mode.rawValue {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(AssetTheme.gold)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsLedgerButtonStyle())
        .accessibilityAddTraits(selection == mode.rawValue ? .isSelected : [])
        .accessibilityIdentifier("settings.appearance.\(mode.rawValue)")
    }

    private func select(_ mode: AppAppearanceMode) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            selection = mode.rawValue
        }
    }
}

private struct SettingsLedgerAppearanceSample: View {
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Circle()
                    .fill(AssetTheme.gold)
                    .frame(width: 4, height: 4)
                    .padding(.top, 8)
                Spacer()
            }
            .frame(width: 14)
            .background(AssetTheme.backgroundSecondary)

            VStack(alignment: .leading, spacing: 5) {
                Rectangle().fill(AssetTheme.textSecondary.opacity(0.5)).frame(height: 2)
                Rectangle().fill(AssetTheme.border).frame(height: 2)
                Rectangle().fill(AssetTheme.border).frame(height: 2)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AssetTheme.background)
        }
        .accessibilityHidden(true)
    }
}
#endif

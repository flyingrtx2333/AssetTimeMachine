import SwiftUI

struct AssetRecordingQuickStartView: View {
    let selectedChoice: AssetRecordingQuickChoice?
    let onSelect: (AssetRecordingQuickChoice) -> Void
    let onSearchOtherAssets: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: contentSpacing) {
            VStack(alignment: .leading, spacing: 4) {
                Text(AppLocalization.string("先录入一项资产"))
                    #if targetEnvironment(macCatalyst)
                    .font(.system(size: 16, weight: .semibold))
                    #else
                    .font(.title2.weight(.semibold))
                    #endif
                    .foregroundStyle(AssetTheme.textPrimary)

                Text(AppLocalization.string("从常见类型中选择，快速开始"))
                    #if targetEnvironment(macCatalyst)
                    .font(.system(size: 12))
                    #else
                    .font(AppTypography.body)
                    #endif
                    .foregroundStyle(AssetTheme.textSecondary)
            }

            VStack(spacing: 0) {
                ForEach(AssetRecordingQuickChoice.allCases) { choice in
                    Button {
                        onSelect(choice)
                    } label: {
                        HStack(spacing: rowSpacing) {
                            Image(systemName: choice.systemImageName)
                                .font(.system(size: iconSize, weight: .semibold))
                                .foregroundStyle(selectedChoice == choice ? AssetTheme.goldSoft : AssetTheme.textSecondary)
                                .frame(width: iconFrameSize, height: iconFrameSize)

                            Text(AppLocalization.string(choice.titleLocalizationKey))
                                .font(AppTypography.rowTitle)
                                .foregroundStyle(AssetTheme.textPrimary)

                            Spacer(minLength: 12)

                            Image(systemName: selectedChoice == choice ? "checkmark.circle.fill" : "chevron.right")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(selectedChoice == choice ? AssetTheme.gold : AssetTheme.textSecondary)
                        }
                        .padding(.horizontal, rowHorizontalPadding)
                        .frame(minHeight: rowHeight)
                        .contentShape(Rectangle())
                        .background(selectedChoice == choice ? AssetTheme.gold.opacity(0.09) : Color.clear)
                    }
                    .buttonStyle(.plain)

                    if choice != AssetRecordingQuickChoice.allCases.last {
                        Divider()
                            .overlay(AssetTheme.border.opacity(0.4))
                            .padding(.leading, dividerInset)
                    }
                }
            }
            .background(AssetTheme.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: panelRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: panelRadius, style: .continuous)
                    .stroke(AssetTheme.border.opacity(0.7), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: panelRadius, style: .continuous))

            Button(action: onSearchOtherAssets) {
                Label(AppLocalization.string("搜索其他资产"), systemImage: "magnifyingglass")
                    .font(AppTypography.metaStrong)
                    .foregroundStyle(AssetTheme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: searchButtonHeight)
                    .background(AssetTheme.overlaySoft, in: RoundedRectangle(cornerRadius: panelRadius, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private var contentSpacing: CGFloat {
        #if targetEnvironment(macCatalyst)
        10
        #else
        18
        #endif
    }

    private var rowSpacing: CGFloat {
        #if targetEnvironment(macCatalyst)
        10
        #else
        14
        #endif
    }

    private var iconSize: CGFloat {
        #if targetEnvironment(macCatalyst)
        14
        #else
        17
        #endif
    }

    private var iconFrameSize: CGFloat {
        #if targetEnvironment(macCatalyst)
        20
        #else
        28
        #endif
    }

    private var rowHorizontalPadding: CGFloat {
        #if targetEnvironment(macCatalyst)
        12
        #else
        16
        #endif
    }

    private var rowHeight: CGFloat {
        #if targetEnvironment(macCatalyst)
        38
        #else
        58
        #endif
    }

    private var dividerInset: CGFloat {
        #if targetEnvironment(macCatalyst)
        42
        #else
        58
        #endif
    }

    private var searchButtonHeight: CGFloat {
        #if targetEnvironment(macCatalyst)
        32
        #else
        48
        #endif
    }

    private var panelRadius: CGFloat {
        #if targetEnvironment(macCatalyst)
        10
        #else
        18
        #endif
    }
}

struct AssetRecordingOnboardingResumeBanner: View {
    let onContinue: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "1.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(AssetTheme.gold)

                VStack(alignment: .leading, spacing: 4) {
                    Text(AppLocalization.string("完成第一笔录入"))
                        .font(AppTypography.blockTitleBold)
                        .foregroundStyle(AssetTheme.textPrimary)

                    Text(AppLocalization.string("添加一项资产并记录当前金额，之后就能持续更新。"))
                        .font(AppTypography.caption)
                        .foregroundStyle(AssetTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 10) {
                Button(AppLocalization.string("暂时跳过"), action: onSkip)
                    .font(AppTypography.captionStrong)
                    .foregroundStyle(AssetTheme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                    .padding(.vertical, 2)
                    .background(AssetTheme.overlaySoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                Button(AppLocalization.string("继续录入"), action: onContinue)
                    .font(AppTypography.captionStrong)
                    .foregroundStyle(Color.black.opacity(0.82))
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                    .padding(.vertical, 2)
                    .background(AssetTheme.gold, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(AssetTheme.surface.opacity(0.76), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AssetTheme.gold.opacity(0.24), lineWidth: 1)
        )
    }
}

struct AssetRecordingOnboardingSuccessBanner: View {
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(AssetTheme.positive)

            VStack(alignment: .leading, spacing: 4) {
                Text(AppLocalization.string("第一项资产已录入"))
                    .font(AppTypography.blockTitleBold)
                    .foregroundStyle(AssetTheme.textPrimary)

                Text(AppLocalization.string("以后点击金额或数量，就能更新今天的记录"))
                    .font(AppTypography.caption)
                    .foregroundStyle(AssetTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 10)

            Button(AppLocalization.string("知道了"), action: onDismiss)
                .font(AppTypography.captionStrong)
                .foregroundStyle(AssetTheme.goldSoft)
        }
        .padding(16)
        .background(AssetTheme.surface.opacity(0.76), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AssetTheme.positive.opacity(0.24), lineWidth: 1)
        )
    }
}

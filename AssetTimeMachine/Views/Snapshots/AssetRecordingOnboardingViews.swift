import SwiftUI

struct AssetRecordingQuickStartView: View {
    let selectedChoice: AssetRecordingQuickChoice?
    let onSelect: (AssetRecordingQuickChoice) -> Void
    let onSearchOtherAssets: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(AppLocalization.string("先录入一项资产"))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(AssetTheme.textPrimary)

                Text(AppLocalization.string("从常见类型中选择，快速开始"))
                    .font(AppTypography.body)
                    .foregroundStyle(AssetTheme.textSecondary)
            }

            VStack(spacing: 0) {
                ForEach(AssetRecordingQuickChoice.allCases) { choice in
                    Button {
                        onSelect(choice)
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: choice.systemImageName)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(selectedChoice == choice ? AssetTheme.goldSoft : AssetTheme.textSecondary)
                                .frame(width: 28, height: 28)

                            Text(AppLocalization.string(choice.titleLocalizationKey))
                                .font(AppTypography.rowTitle)
                                .foregroundStyle(AssetTheme.textPrimary)

                            Spacer(minLength: 12)

                            Image(systemName: selectedChoice == choice ? "checkmark.circle.fill" : "chevron.right")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(selectedChoice == choice ? AssetTheme.gold : AssetTheme.textSecondary)
                        }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 58)
                        .contentShape(Rectangle())
                        .background(selectedChoice == choice ? AssetTheme.gold.opacity(0.09) : Color.clear)
                    }
                    .buttonStyle(.plain)

                    if choice != AssetRecordingQuickChoice.allCases.last {
                        Divider()
                            .overlay(AssetTheme.border.opacity(0.4))
                            .padding(.leading, 58)
                    }
                }
            }
            .background(AssetTheme.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(AssetTheme.border.opacity(0.7), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            Button(action: onSearchOtherAssets) {
                Label(AppLocalization.string("搜索其他资产"), systemImage: "magnifyingglass")
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(AssetTheme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(AssetTheme.overlaySoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
        }
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

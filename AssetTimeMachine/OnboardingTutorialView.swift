import SwiftUI

enum OnboardingAnchorID: Hashable {
    case dashboardAllocation
    case dashboardTrend
    case dashboardFreedom
    case recordsTotal
    case recordsAddAsset
    case recordsFirstInput
    case timeMachineRange
    case timeMachineChart
    case timeMachineAnchors
    case backtestMode
    case backtestConfiguration
    case backtestStart
    case settingsAppearance
    case settingsReplay
    case settingsNotifications
}

struct OnboardingAnchorPreferenceKey: PreferenceKey {
    static var defaultValue: [OnboardingAnchorID: Anchor<CGRect>] = [:]

    static func reduce(value: inout [OnboardingAnchorID: Anchor<CGRect>], nextValue: () -> [OnboardingAnchorID: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newValue in newValue })
    }
}

extension View {
    func onboardingAnchor(_ id: OnboardingAnchorID) -> some View {
        anchorPreference(key: OnboardingAnchorPreferenceKey.self, value: .bounds) { anchor in
            [id: anchor]
        }
    }

    @ViewBuilder
    func onboardingAnchorIf(_ condition: Bool, _ id: OnboardingAnchorID) -> some View {
        if condition {
            onboardingAnchor(id)
        } else {
            self
        }
    }
}

private enum OnboardingBubblePlacement {
    case above
    case below
}

private struct OnboardingStep: Identifiable {
    let id: String
    let tab: AppTab
    let anchorID: OnboardingAnchorID
    let titleKey: String
    let messageKey: String
    let accent: Color
    let placement: OnboardingBubblePlacement?
}

struct OnboardingTutorialView: View {
    @Binding var selectedTab: AppTab
    @Binding var activeAnchorID: OnboardingAnchorID?
    let anchors: [OnboardingAnchorID: Anchor<CGRect>]
    let onFinish: () -> Void
    let onSkip: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var currentStepIndex = 0

    private let steps: [OnboardingStep] = [
        .init(
            id: "dashboard.allocation",
            tab: .dashboard,
            anchorID: .dashboardAllocation,
            titleKey: "先看总览",
            messageKey: "首页帮你快速看清资产分布和整体变化。",
            accent: AssetTheme.gold,
            placement: .below
        ),
        .init(
            id: "records.add",
            tab: .snapshots,
            anchorID: .recordsAddAsset,
            titleKey: "添加资产",
            messageKey: "银行卡、房产、贷款或投资标的，都从这里新增。",
            accent: AssetTheme.accentOrange,
            placement: .below
        ),
        .init(
            id: "records.input",
            tab: .snapshots,
            anchorID: .recordsFirstInput,
            titleKey: "记录数值",
            messageKey: "点金额或数量即可更新今天的记录。",
            accent: AssetTheme.accentOrange,
            placement: nil
        ),
        .init(
            id: "timeMachine.chart",
            tab: .timeMachine,
            anchorID: .timeMachineChart,
            titleKey: "看历史",
            messageKey: "这里可以回看资产走势，并和黄金、纳指等锚点对照。",
            accent: AssetTheme.accentBlue,
            placement: nil
        ),
        .init(
            id: "backtest.mode",
            tab: .backtest,
            anchorID: .backtestMode,
            titleKey: "做回测",
            messageKey: "选择模式、调整参数，然后模拟不同资产策略。",
            accent: AssetTheme.positive,
            placement: .below
        ),
        .init(
            id: "settings.appearance",
            tab: .settings,
            anchorID: .settingsAppearance,
            titleKey: "基础设置",
            messageKey: "外观、语言和其他偏好都在这里。",
            accent: AssetTheme.accentBlue,
            placement: .below
        )
    ]

    private var currentStep: OnboardingStep {
        steps[currentStepIndex]
    }

    private var isLastStep: Bool {
        currentStepIndex == steps.count - 1
    }

    private let defaultSpotlightInset: CGFloat = 10
    private let spotlightCornerRadius: CGFloat = 16

    var body: some View {
        GeometryReader { proxy in
            let activeFrame = anchors[currentStep.anchorID].map { proxy[$0] }
            let spotlightRect = resolvedSpotlightRect(from: activeFrame)
            ZStack {
                OnboardingDimLayer(
                    spotlightRect: spotlightRect,
                    cornerRadius: spotlightCornerRadius,
                    dimOpacity: colorScheme == .dark ? 0.64 : 0.56
                )
                .allowsHitTesting(true)

                if let spotlightRect {
                    ZStack {
                        RoundedRectangle(cornerRadius: spotlightCornerRadius, style: .continuous)
                            .fill(currentStep.accent.opacity(colorScheme == .dark ? 0.10 : 0.08))

                        RoundedRectangle(cornerRadius: spotlightCornerRadius, style: .continuous)
                            .stroke(Color.white.opacity(colorScheme == .dark ? 0.28 : 0.92), lineWidth: 4)

                        RoundedRectangle(cornerRadius: spotlightCornerRadius, style: .continuous)
                            .stroke(currentStep.accent, lineWidth: 2.5)
                            .shadow(color: currentStep.accent.opacity(0.55), radius: 14, x: 0, y: 0)
                    }
                    .frame(width: spotlightRect.width, height: spotlightRect.height)
                    .position(x: spotlightRect.midX, y: spotlightRect.midY)
                    .allowsHitTesting(false)
                }

                bubble(proxy: proxy, activeFrame: activeFrame)
            }
        }
        .onAppear {
            if let forcedIndex = ProcessInfo.processInfo.arguments.firstIndex(of: "-onboardingStep"),
               ProcessInfo.processInfo.arguments.indices.contains(forcedIndex + 1),
               let step = Int(ProcessInfo.processInfo.arguments[forcedIndex + 1]) {
                currentStepIndex = min(max(step, 0), steps.count - 1)
            }
            syncSelectedTab(animated: false)
            syncActiveAnchor()
        }
        .onChange(of: currentStepIndex) { _, _ in
            syncSelectedTab(animated: true)
            syncActiveAnchor()
        }
        .onDisappear {
            activeAnchorID = nil
        }
        .accessibilityElement(children: .contain)
    }

    private func bubble(proxy: GeometryProxy, activeFrame: CGRect?) -> some View {
        let safeInsets = proxy.safeAreaInsets
        let bubbleWidth = min(proxy.size.width - 32, 360)
        let resolvedPlacement = placement(for: activeFrame, in: proxy.size)
        let bubbleSize = CGSize(width: bubbleWidth, height: 204)
        let position = bubblePosition(
            activeFrame: activeFrame,
            bubbleSize: bubbleSize,
            placement: resolvedPlacement,
            container: proxy.size,
            safeInsets: safeInsets
        )

        return VStack(spacing: 12) {
            progressBar
            bubbleCard
            controls
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: bubbleWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(AssetTheme.cardGradient)
                .shadow(color: AssetTheme.cardShadow, radius: 20, x: 0, y: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AssetTheme.border.opacity(0.9), lineWidth: 1)
        )
        .overlay(alignment: resolvedPlacement == .above ? .bottom : .top) {
            BubbleTail()
                .fill(AssetTheme.surface)
                .frame(width: 18, height: 18)
                .rotationEffect(.degrees(45))
                .offset(y: resolvedPlacement == .above ? 9 : -9)
        }
        .position(position)
        .animation(.spring(response: 0.26, dampingFraction: 0.9), value: currentStep.id)
    }

    private var progressBar: some View {
        HStack(spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                Capsule()
                    .fill(index == currentStepIndex ? step.accent : AssetTheme.border.opacity(0.7))
                    .frame(maxWidth: index == currentStepIndex ? 22 : 6)
                    .frame(height: 6)
            }
        }
    }

    private var bubbleCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(AppLocalization.format("第 %d / %d 步", currentStepIndex + 1, steps.count))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(currentStep.accent)

                Spacer(minLength: 8)

                Image(systemName: symbolName(for: currentStep.tab))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(currentStep.accent)
            }

            Text(AppLocalization.string(currentStep.titleKey))
                .font(.headline.weight(.bold))
                .foregroundStyle(AssetTheme.textPrimary)

            Text(AppLocalization.string(currentStep.messageKey))
                .font(.subheadline)
                .foregroundStyle(AssetTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button(AppLocalization.string("跳过"), action: onSkip)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AssetTheme.textSecondary)

            Spacer(minLength: 12)

            Button(isLastStep ? AppLocalization.string("开始使用") : AppLocalization.string("下一步")) {
                advance()
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AssetTheme.surface)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(currentStep.accent, in: Capsule())
        }
    }

    private func placement(for frame: CGRect?, in container: CGSize) -> OnboardingBubblePlacement {
        if let explicit = currentStep.placement {
            return explicit
        }
        guard let frame else { return .below }
        return frame.midY > container.height * 0.52 ? .above : .below
    }

    private func bubblePosition(
        activeFrame: CGRect?,
        bubbleSize: CGSize,
        placement: OnboardingBubblePlacement,
        container: CGSize,
        safeInsets: EdgeInsets
    ) -> CGPoint {
        guard let activeFrame else {
            return CGPoint(x: container.width / 2, y: container.height - safeInsets.bottom - bubbleSize.height / 2 - 36)
        }

        let horizontalPadding: CGFloat = 16
        let verticalGap: CGFloat = 24
        let x = min(
            max(activeFrame.midX, bubbleSize.width / 2 + horizontalPadding),
            container.width - bubbleSize.width / 2 - horizontalPadding
        )

        let minY = safeInsets.top + bubbleSize.height / 2 + 12
        let maxY = container.height - safeInsets.bottom - bubbleSize.height / 2 - 12
        let proposedY: CGFloat

        switch placement {
        case .above:
            proposedY = activeFrame.minY - verticalGap - bubbleSize.height / 2
        case .below:
            proposedY = activeFrame.maxY + verticalGap + bubbleSize.height / 2
        }

        return CGPoint(x: x, y: min(max(proposedY, minY), maxY))
    }

    private func advance() {
        if isLastStep {
            onFinish()
        } else {
            currentStepIndex += 1
        }
    }

    private func syncSelectedTab(animated: Bool) {
        let update = {
            selectedTab = currentStep.tab
        }

        if animated {
            withAnimation(.easeInOut(duration: 0.22), update)
        } else {
            update()
        }
    }

    private func symbolName(for tab: AppTab) -> String {
        switch tab {
        case .dashboard:
            return "house.fill"
        case .snapshots:
            return "square.and.pencil"
        case .timeMachine:
            return "clock.arrow.circlepath"
        case .backtest:
            return "chart.xyaxis.line"
        case .settings:
            return "gearshape.fill"
        }
    }

    private func syncActiveAnchor() {
        activeAnchorID = currentStep.anchorID
    }

    private func resolvedSpotlightRect(from activeFrame: CGRect?) -> CGRect? {
        guard let activeFrame else { return nil }

        if currentStep.id == "backtest.start" {
            let horizontalInset: CGFloat = 14
            let bottomInset: CGFloat = 16
            let buttonHeight: CGFloat = 66
            return CGRect(
                x: activeFrame.minX + horizontalInset,
                y: activeFrame.maxY - buttonHeight - bottomInset,
                width: activeFrame.width - horizontalInset * 2,
                height: buttonHeight
            ).integral
        }

        let inset: CGFloat
        switch currentStep.anchorID {
        case .dashboardAllocation, .timeMachineRange, .backtestStart:
            inset = 18
        default:
            inset = defaultSpotlightInset
        }

        return activeFrame
            .insetBy(dx: -inset, dy: -inset)
            .integral
    }
}

private struct OnboardingDimLayer: View {
    let spotlightRect: CGRect?
    let cornerRadius: CGFloat
    let dimOpacity: Double

    var body: some View {
        SpotlightShape(
            spotlightRect: spotlightRect,
            cornerRadius: cornerRadius
        )
        .fill(Color.black.opacity(dimOpacity), style: FillStyle(eoFill: true))
    }
}

private struct SpotlightShape: Shape {
    let spotlightRect: CGRect?
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect.insetBy(dx: -80, dy: -80))

        if let spotlightRect {
            path.addRoundedRect(
                in: spotlightRect,
                cornerSize: CGSize(width: cornerRadius, height: cornerRadius)
            )
        }

        return path
    }
}

private struct BubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }
}

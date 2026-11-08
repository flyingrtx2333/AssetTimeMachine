import AppKit
import SwiftUI

/// First launch only. The existing caller owns account choice and store creation.
struct NativeFreshStartView: View {
    let start: (Bool) -> Void
    var forceReducedMotion = false
    @Environment(\.accessibilityReduceMotion) private var systemReducedMotion
    @State private var entered = false
    @State private var brandHovered = false

    private var reducedMotion: Bool { systemReducedMotion || forceReducedMotion }

    var body: some View {
        GeometryReader { geometry in
            let inset = max(28, min(48, geometry.size.width * 0.059))
            let top = max(48, min(88, geometry.size.height * 0.132))
            let footerHeight: CGFloat = 166
            ZStack(alignment: .topLeading) {
                NativePalette.welcomeCanvas
                NativeWelcomeFlow(reducedMotion: reducedMotion)
                    .frame(height: max(190, geometry.size.height - top - 248))
                    .frame(maxHeight: .infinity)
                    .offset(y: -9)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)

                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 14) {
                        Image("brand_logo")
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: 52, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 11))
                            .scaleEffect(brandHovered && !reducedMotion ? 1.04 : 1)
                            .animation(.easeInOut(duration: reducedMotion ? 0 : 0.55), value: brandHovered)
                            .accessibilityHidden(true)
                        Text(AppLocalization.string("资产时光机"))
                            .font(.system(size: 35, weight: .semibold))
                            .foregroundStyle(NativePalette.text)
                            .accessibilityAddTraits(.isHeader)
                    }
                    .onHover { brandHovered = $0 }
                    Text(AppLocalization.string("记录资产，回看变化。"))
                        .font(.system(size: 17))
                        .foregroundStyle(NativePalette.secondary)
                }
                .opacity(entered ? 1 : 0)
                .offset(y: entered || reducedMotion ? 0 : 6)
                .padding(.horizontal, inset)
                .padding(.top, top)

                VStack(alignment: .leading, spacing: 20) {
                    Rectangle().fill(NativePalette.text.opacity(0.20)).frame(height: 0.5)
                    HStack(spacing: 18) {
                        Button { start(false) } label: {
                            HStack(spacing: 36) {
                                Text(AppLocalization.string("登录同步手机数据"))
                                Image(systemName: "arrow.right").font(.system(size: 18, weight: .regular))
                                    .accessibilityHidden(true)
                            }
                            .frame(minWidth: 236)
                        }
                        .buttonStyle(NativeWelcomeButtonStyle(primary: true, forceReducedMotion: reducedMotion))
                        .focusable()
                        .onKeyPress(.space, phases: .down) { _ in start(false); return .handled }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("welcome.login")

                        Button { start(true) } label: {
                            Text(AppLocalization.string("先在本机使用"))
                                .frame(minWidth: 180)
                        }
                        .buttonStyle(NativeWelcomeButtonStyle(primary: false, forceReducedMotion: reducedMotion))
                        .focusable()
                        .onKeyPress(.space, phases: .down) { _ in start(true); return .handled }
                        .accessibilityIdentifier("welcome.offline")
                    }
                    Text(AppLocalization.string("之后也可随时登录。"))
                        .font(.system(size: 14))
                        .foregroundStyle(NativePalette.secondary)
                        .padding(.top, -4)
                }
                .padding(.horizontal, inset)
                .frame(height: footerHeight, alignment: .top)
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .clipped()
        }
        .frame(minWidth: NativeStyle.Layout.windowMinWidth, minHeight: NativeStyle.Layout.windowMinHeight)
        .onAppear {
            withAnimation(reducedMotion ? nil : .easeOut(duration: 0.5)) { entered = true }
        }
    }
}

private struct NativeWelcomeButtonStyle: ButtonStyle {
    let primary: Bool
    var forceReducedMotion = false
    @Environment(\.accessibilityReduceMotion) private var systemReducedMotion
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @State private var hovered = false

    private var reducedMotion: Bool { systemReducedMotion || forceReducedMotion }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .padding(.horizontal, 16)
            .frame(height: 51)
            .foregroundStyle(primary ? NativePalette.welcomeActionText : NativePalette.text)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(primary ? NativePalette.welcomeAction : NativePalette.text.opacity(hovered ? 0.065 : 0.025))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(focused ? NativePalette.welcomeGold : NativePalette.text.opacity(primary ? 0.2 : (hovered ? 0.5 : 0.27)), lineWidth: focused ? 2 : 0.8)
            }
            .brightness(primary && hovered ? 0.045 : 0)
            .brightness(configuration.isPressed ? -0.08 : 0)
            .scaleEffect(configuration.isPressed && !reducedMotion ? 0.985 : 1)
            .offset(y: hovered && !configuration.isPressed && !reducedMotion ? -1.5 : 0)
            .opacity(enabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: reducedMotion ? 0 : 0.18), value: hovered)
            .animation(.easeOut(duration: reducedMotion ? 0 : 0.12), value: configuration.isPressed)
    }
}

/// Drawing is isolated from layout. Only the artwork redraws; labels and controls stay still.
private struct NativeWelcomeFlow: View {
    let reducedMotion: Bool
    @State private var visible = false
    @State private var active = NSApp.isActive
    @State private var windowVisible = true
    @State private var elapsed: TimeInterval = 0
    @State private var resumedAt: Date?

    private var running: Bool { visible && active && windowVisible && !reducedMotion }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !running)) { timeline in
            let time = reducedMotion ? 0 : elapsed + (resumedAt.map { max(0, timeline.date.timeIntervalSince($0)) } ?? 0)
            Canvas { context, size in
                draw(in: &context, size: size, time: time)
            }
        }
        .background(NativeWelcomeVisibility { windowVisible = $0 })
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in active = true }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in active = false }
        .onChange(of: reducedMotion) { _, value in
            if value { elapsed = 0; resumedAt = nil }
        }
        .onChange(of: running) { _, value in
            if value {
                resumedAt = Date()
            } else if let start = resumedAt {
                elapsed += Date().timeIntervalSince(start)
                resumedAt = nil
            }
        }
    }

    // All frequencies share an 18-second cycle. Pause/resume preserves phase.
    private func ordinate(_ x: Double, line: Int, time: TimeInterval, height: Double) -> Double {
        let depth = Double(line) / 39
        let phase = time * .pi * 2 / 18
        let main = sin(x * .pi * 3.25 - 0.10 + depth * 0.65) * (37 - depth * 14)
        let spread = depth * 66 + sin(x * 9 + depth * 4) * 11
        let drift = sin(x * 7 + phase) * 7 + sin(x * 11 - phase * 2 + depth * 2) * 3
        let contour = 32 * exp(-pow((x - 0.45) / 0.19, 2)) + 18 * exp(-pow((x - 0.78) / 0.22, 2))
        return height * 0.28 + main + spread + contour + drift
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let width = size.width
        let height = size.height
        for line in 0..<40 {
            var path = Path()
            for sample in 0...140 {
                let x = Double(sample) / 140
                let point = CGPoint(x: x * width, y: ordinate(x, line: line, time: time, height: height))
                if sample == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            let opacity = line % 7 == 0 ? 0.80 : 0.20 + Double(line % 5) * 0.075
            context.stroke(path, with: .color(NativePalette.welcomeGold.opacity(opacity)), lineWidth: line % 7 == 0 ? 0.8 : 0.55)
        }
        let anchors: [(Double, Int, Double)] = [(0.105, 18, 35), (0.257, 8, -28), (0.432, 0, -18), (0.579, 13, 16), (0.700, 4, -28), (0.847, 11, -24), (0.907, 28, 15)]
        for (index, anchor) in anchors.enumerated() {
            let (x, line, extensionY) = anchor
            let y = ordinate(x, line: line, time: time, height: height)
            let px = x * width
            var guide = Path()
            guide.move(to: CGPoint(x: px, y: 4))
            guide.addLine(to: CGPoint(x: px, y: height - 8))
            context.stroke(guide, with: .color(NativePalette.welcomeGold.opacity(0.12)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
            var stem = Path()
            stem.move(to: CGPoint(x: px, y: y))
            stem.addLine(to: CGPoint(x: px, y: y + extensionY))
            context.stroke(stem, with: .color(NativePalette.welcomeGold.opacity(0.70)), lineWidth: 0.7)
            let dot = Path(ellipseIn: CGRect(x: px - 2.5, y: y + extensionY - 2.5, width: 5, height: 5))
            if index == 1 || index == 4 {
                context.fill(dot, with: .color(NativePalette.welcomeCanvas))
                context.stroke(dot, with: .color(NativePalette.welcomeGold), lineWidth: 1)
            } else {
                context.fill(dot, with: .color(NativePalette.welcomeGold))
            }
        }
    }
}

/// Observe the owning window only; no event monitors or global window changes.
private struct NativeWelcomeVisibility: NSViewRepresentable {
    let changed: (Bool) -> Void
    func makeNSView(context: Context) -> VisibilityView { VisibilityView(changed: changed) }
    func updateNSView(_ view: VisibilityView, context: Context) { view.changed = changed }
    static func dismantleNSView(_ view: VisibilityView, coordinator: ()) { view.stop() }

    final class VisibilityView: NSView {
        var changed: (Bool) -> Void
        private var observers: [NSObjectProtocol] = []
        init(changed: @escaping (Bool) -> Void) {
            self.changed = changed
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let window else { return }
            let center = NotificationCenter.default
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.reportVisibility()
                })
            }
            DispatchQueue.main.async { [weak self] in self?.reportVisibility() }
        }
        private func reportVisibility() {
            changed(window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false)
        }
        func stop() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
        }
    }
}

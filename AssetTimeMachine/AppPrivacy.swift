import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum AppPrivacyPreferences {
    static let defaults: UserDefaults = AppPreviewSession.isActive
        ? UserDefaults(suiteName: "com.flyingrtx.AssetTimeMachine.privacy-preview.\(UUID().uuidString)")!
        : .standard
}

private struct FinancialPrivacyModifier: ViewModifier {
    let sensitive: Bool
    @AppStorage("dashboard.amountsVisible", store: AppPrivacyPreferences.defaults) private var visible = true
    func body(content: Content) -> some View {
        if visible || !sensitive { content.privacySensitive() }
        else {
            content.hidden().accessibilityHidden(true)
                .overlay { Text("••••").accessibilityLabel(AppLocalization.string("金额已隐藏")) }
        }
    }
}

extension View {
    func financialPrivacy(_ sensitive: Bool = true) -> some View { modifier(FinancialPrivacyModifier(sensitive: sensitive)) }
}

struct AmountPrivacyButton: View {
    @AppStorage("dashboard.amountsVisible", store: AppPrivacyPreferences.defaults) private var visible = true
    var body: some View {
        Button { visible.toggle() } label: {
            Image(systemName: visible ? "eye" : "eye.slash")
                .frame(minWidth: 28, minHeight: 28)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AppLocalization.string(visible ? "隐藏资产金额" : "显示资产金额"))
        .help(AppLocalization.string(visible ? "隐藏资产金额" : "显示资产金额"))
        .accessibilityIdentifier("privacy.amounts")
    }
}

#if canImport(UIKit)
/// Cover the entire window synchronously before iOS takes its background snapshot,
/// including sheets and editors presented above the root SwiftUI view.
struct AppSwitcherPrivacyShield: UIViewRepresentable {
    @AppStorage("app.privacy.protectAppSwitcher", store: AppPrivacyPreferences.defaults) private var enabled = true
    func makeUIView(context: Context) -> ShieldAnchor { ShieldAnchor() }
    func updateUIView(_ view: ShieldAnchor, context: Context) { view.enabled = enabled; view.refresh() }
    static func dismantleUIView(_ view: ShieldAnchor, coordinator: ()) { view.stop() }

    final class ShieldAnchor: UIView {
        var enabled = true
        private var cover: UIView?
        private var observers: [NSObjectProtocol] = []
        override func didMoveToWindow() {
            super.didMoveToWindow()
            stop()
            guard window != nil else { return }
            for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
                         UIApplication.didBecomeActiveNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notice in
                    MainActor.assumeIsolated {
                        if notice.name == UIApplication.didBecomeActiveNotification { self?.removeCover() }
                        else { self?.showCover() }
                    }
                })
            }
            refresh()
        }
        func refresh() {
            if enabled && UIApplication.shared.applicationState != .active { showCover() }
            else { removeCover() }
        }
        private func showCover() {
            guard enabled, let window else { return }
            if let cover { window.bringSubviewToFront(cover); return }
            let view = UIView(frame: window.bounds)
            view.accessibilityIdentifier = "app.privacy.shield"
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.backgroundColor = .systemBackground
            let icon = UIImageView(image: UIImage(systemName: "lock.fill"))
            icon.tintColor = .secondaryLabel
            icon.contentMode = .scaleAspectFit
            icon.frame = CGRect(x: 0, y: 0, width: 32, height: 32)
            icon.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            icon.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]
            view.addSubview(icon)
            view.accessibilityLabel = AppLocalization.string("后台预览已保护")
            view.isAccessibilityElement = true
            window.addSubview(view)
            cover = view
        }
        private func removeCover() { cover?.removeFromSuperview(); cover = nil }
        func stop() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []; removeCover()
        }
    }
}
#elseif canImport(AppKit)
struct AppSwitcherPrivacyShield: NSViewRepresentable {
    @AppStorage("app.privacy.protectAppSwitcher", store: AppPrivacyPreferences.defaults) private var enabled = true
    func makeNSView(context: Context) -> ShieldAnchor { ShieldAnchor() }
    func updateNSView(_ view: ShieldAnchor, context: Context) { view.enabled = enabled; view.refresh() }
    static func dismantleNSView(_ view: ShieldAnchor, coordinator: ()) { view.stop() }

    final class ShieldAnchor: NSView {
        var enabled = true
        private var covers: [NSView] = []
        private var observers: [NSObjectProtocol] = []
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            for name in [NSApplication.willResignActiveNotification, NSApplication.didBecomeActiveNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notice in
                    MainActor.assumeIsolated {
                        if notice.name == NSApplication.didBecomeActiveNotification { self?.removeCovers() }
                        else { self?.showCovers() }
                    }
                })
            }
            refresh()
        }
        func refresh() {
            if enabled && !NSApp.isActive { showCovers() } else { removeCovers() }
        }
        private func showCovers() {
            guard enabled, covers.isEmpty else { return }
            for window in NSApp.windows where window.isVisible {
                guard let parent = window.contentView else { continue }
                let cover = NSView(frame: parent.bounds)
                cover.identifier = NSUserInterfaceItemIdentifier("app.privacy.shield")
                cover.autoresizingMask = [.width, .height]
                cover.wantsLayer = true
                cover.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                let icon = NSImageView(image: NSImage(systemSymbolName: "lock.fill", accessibilityDescription: AppLocalization.string("后台预览已保护"))!)
                icon.frame = NSRect(x: parent.bounds.midX - 16, y: parent.bounds.midY - 16, width: 32, height: 32)
                icon.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
                cover.addSubview(icon)
                parent.addSubview(cover, positioned: .above, relativeTo: nil)
                covers.append(cover)
            }
        }
        private func removeCovers() { covers.forEach { $0.removeFromSuperview() }; covers = [] }
        func stop() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []; removeCovers()
        }
    }
}
#endif

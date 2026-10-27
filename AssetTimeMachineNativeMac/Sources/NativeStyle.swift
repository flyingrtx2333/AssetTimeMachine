import AppKit
import SwiftUI

// macOS design system. Change visual roles here; keep page geometry and business rules in views.
// Black/gold and white/gold resolve through NativePalette with the window appearance.
enum NativeStyle {
    enum FontRole {
        static let caption = Font.system(size: 11)
        static let captionStrong = Font.system(size: 11, weight: .medium)
        static let body = Font.system(size: 13)
        static let action = Font.system(size: 13, weight: .medium)
        static let bodyStrong = Font.system(size: 13, weight: .semibold)
        static let section = Font.system(size: 14, weight: .medium)
        static let dialogTitle = Font.system(size: 14, weight: .semibold)
        static let pageTitle = Font.system(size: 16, weight: .semibold)
        static let display = Font.system(size: 28, weight: .medium)
        // Compatibility names map existing screens to the same semantic hierarchy.
        static let chartLabel = caption
        static let micro = caption
        static let microStrong = captionStrong
        static let input = body
        static let inputStrong = bodyStrong
        static let sectionStrong = section
        static let icon = Font.system(size: 15)
        static let iconLight = icon
        static let iconStrong = icon
        static let subheading = section
        static let subheadingStrong = section
        static let emphasis = section
        static let metric = Font.system(size: 18, weight: .medium)
        static let metricStrong = metric
        static let sectionTitle = section
        static let summary = metric
        static let brandSymbol = display
        static let displayRegular = display
        static let largeDisplay = display
    }
    enum Space {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 6
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let section: CGFloat = 24
        static let page: CGFloat = 28
        static let spacious: CGFloat = 32
        static let hero: CGFloat = 40
    }
    enum Radius {
        static let control: CGFloat = 6
        static let field: CGFloat = 8
        static let panel: CGFloat = 6
        static let dialog: CGFloat = 10
    }
    // Shared desktop density; chart drawing coordinates remain local to their views.
    enum Layout {
        static let pageInset: CGFloat = 24
        static let windowMinWidth: CGFloat = 800
        static let windowMinHeight: CGFloat = 580
        static let ledgerMaxWidth: CGFloat = 620
        static let quantityWidth: CGFloat = 72
        static let unitPriceWidth: CGFloat = 104
        static let amountWidth: CGFloat = 108
        static let sectionGap: CGFloat = 16
        static let sidebarWidth: CGFloat = 128
        static let brandHeight: CGFloat = 64
        static let navigationHeight: CGFloat = 34
        static let ledgerRowHeight: CGFloat = 28
        static let ledgerFieldHeight: CGFloat = 24
        static let ledgerGroupHeight: CGFloat = 24
        static let homeHeaderHeight: CGFloat = 80
        static let homeDetailsHeight: CGFloat = 174
        static let homeChartMaxHeight: CGFloat = 200
        static let emptyStateHeight: CGFloat = 80
    }
    enum Control {
        static let height: CGFloat = 28
        static let fieldHeight: CGFloat = 26
        static let accountFieldHeight: CGFloat = 26
        static let horizontalPadding: CGFloat = 12
    }
    enum Motion {
        static func quantTransition(_ reducedMotion: Bool) -> AnyTransition {
            .opacity
        }
        static let reduced = Animation.easeOut(duration: 0.08)
        static func home(_ reducedMotion: Bool) -> Animation {
            reducedMotion ? reduced : .easeOut(duration: 0.18)
        }
        static func records(_ reducedMotion: Bool) -> Animation {
            reducedMotion ? reduced : .easeOut(duration: 0.18)
        }
        static func quant(_ reducedMotion: Bool) -> Animation {
            reducedMotion ? reduced : .easeOut(duration: 0.18)
        }
    }
}

/// Keeps persisted asset identities visible in compact native rows.
struct NativeAssetIcon: View {
    let key: String?
    let group: AssetGroup?
    let title: String
    var size: CGFloat = 20

    private var parts: [String] { (key ?? "").split(separator: "|", omittingEmptySubsequences: false).map(String.init) }
    private var symbol: String {
        if let key, let definition = AssetIconRegistry.definition(for: key) { return definition.symbolName }
        if let key, !key.isEmpty, NSImage(systemSymbolName: key, accessibilityDescription: nil) != nil { return key }
        return AssetIconRegistry.symbolName(for: key ?? "", categoryGroup: group)
    }
    var body: some View {
        Group {
            if parts.count == 3, parts[0] == "market_asset" {
                MarketAssetLogoView(symbol: parts[2], sectionID: parts[1], title: title, size: size)
            } else if let key, let asset = AssetIconRegistry.definition(for: key)?.imageAssetName,
                      let image = NSImage(named: asset) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: symbol).font(.system(size: size * 0.75, weight: .medium))
                    .foregroundStyle(NativePalette.secondary)
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

enum NativePalette {
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((hex >> 16) & 255) / 255,
                           green: Double((hex >> 8) & 255) / 255,
                           blue: Double(hex & 255) / 255, alpha: 1)
        })
    }
    static let canvas = adaptive(light: 0xFFFFFF, dark: 0x1D1F23)
    static let sidebar = adaptive(light: 0xF3F4F6, dark: 0x25272B)
    static let surface = adaptive(light: 0xF5F6F8, dark: 0x25282D)
    static let line = adaptive(light: 0xE1E3E7, dark: 0x393C42)
    static let softGold = adaptive(light: 0xF4EFE4, dark: 0x3C3425)
    static let accent = adaptive(light: 0x9C7B38, dark: 0xD2AE68)
    static let text = adaptive(light: 0x20242B, dark: 0xECEEF2)
    static let secondary = adaptive(light: 0x747B85, dark: 0xA7ADB7)
    static let onAccent = adaptive(light: 0xFFFFFF, dark: 0x18140D)
    static let cash = adaptive(light: 0xC5C0B5, dark: 0x504B41)
    static let goldAllocation = adaptive(light: 0xDED3BC, dark: 0x645438)
    static let allocationLight = adaptive(light: 0xEDEAE3, dark: 0x2F2E29)
    static let allocationMedium = adaptive(light: 0xE0DDD5, dark: 0x3B3932)
    static let allocationDark = adaptive(light: 0xD6D1C5, dark: 0x484337)
    static let chartSecondary = adaptive(light: 0x9BA1AA, dark: 0xA8AFBA)
}

enum AssetTheme {
    static let gold = NativePalette.accent
    static let positive = NativePalette.adaptive(light: 0x32784B, dark: 0x68AF80)
    static let negative = NativePalette.adaptive(light: 0xAD413C, dark: 0xDB7770)
    static let goldSoft = NativePalette.accent.opacity(0.7)
    // Legacy shared-model role: a neutral comparison series, not a second gold line.
    static let accentBlue = NativePalette.chartSecondary
    static let accentOrange = Color.orange
    static let accentRed = Color.red
    static let textPrimary = NativeHomeStyle.text
    static let textSecondary = NativeHomeStyle.secondary
    static let border = NativeHomeStyle.line
    static let overlaySubtle = NativePalette.text.opacity(0.04)
}

// Existing native view names use these shared palette aliases. No page defines its own theme.
enum NativeHomeStyle {
    static var previewReduced: Bool { AppPreviewSession.isActive && ProcessInfo.processInfo.arguments.contains("-macHomeReduceMotion") }
    static let ink = NativePalette.canvas
    static let sidebar = NativePalette.sidebar
    static let accent = NativePalette.accent
    static let text = NativePalette.text
    static let secondary = NativePalette.secondary
    static let line = NativePalette.line
    static func amount(_ value: Double) -> String {
        value.formatted(.currency(code: "CNY").precision(.fractionLength(2)))
    }
}

struct NativeHomeButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    private let forcedReduced: Bool
    init(reduced: Bool = false) { forcedReduced = reduced }
    private var reduced: Bool { systemReduced || NativeHomeStyle.previewReduced || forcedReduced }
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false
    @Environment(\.isFocused) private var focused
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(NativeHomeStyle.text.opacity(configuration.isPressed ? 0.075 : (hovered ? 0.035 : 0)),
                        in: RoundedRectangle(cornerRadius: NativeStyle.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: NativeStyle.Radius.control).stroke(NativeHomeStyle.accent.opacity(focused ? 0.8 : 0), lineWidth: 1))

            .brightness(configuration.isPressed ? -0.08 : 0)
            .opacity(enabled ? 1 : 0.4)
            .onHover { hovered = $0 }
            .animation(NativeStyle.Motion.home(reduced), value: hovered)
            .animation(NativeStyle.Motion.home(reduced), value: configuration.isPressed)
    }
}

struct NativeWorkspaceSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.font(NativeStyle.FontRole.body).foregroundStyle(NativeHomeStyle.text).background(NativeHomeStyle.ink)
            .tint(NativePalette.text)
            .controlSize(.regular)
            .buttonStyle(.automatic)
    }
}

struct NativeWorkspacePrimary: ViewModifier {
    func body(content: Content) -> some View {
        content.font(NativeStyle.FontRole.action)
            .buttonStyle(.borderedProminent).tint(NativePalette.accent)
            .controlSize(.regular)
    }
}

typealias NativeRecordsButtonStyle = NativeHomeButtonStyle

struct NativeRecordsPrimary: ViewModifier {
    func body(content: Content) -> some View {
        content.modifier(NativeWorkspacePrimary())
    }
}

struct AccountFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.textFieldStyle(.roundedBorder).font(NativeStyle.FontRole.input)
            .frame(height: NativeStyle.Control.fieldHeight)
    }
}

typealias NativeQuantFeedback = NativeHomeButtonStyle

/// Include the real AppKit toolbar in evidence; never replace it with a drawn header.
@MainActor
enum NativeWindowCapture {
    static func png(_ window: NSWindow) -> Data? {
        guard let view = window.contentView?.superview ?? window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }
}

/// Common native sheet structure. Only long body content scrolls; actions stay reachable.
struct NativeSheet<Content: View, Footer: View>: View {
    let title: String
    var width: CGFloat = 416
    var height: CGFloat? = nil
    var close: (() -> Void)? = nil
    var cancel: (() -> Void)? = nil
    var hasFooter = true
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(AppLocalization.string(title)).font(NativeStyle.FontRole.dialogTitle)
                Spacer()
                if let close {
                    Button(AppLocalization.string("关闭"), action: close)
                        .keyboardShortcut(.cancelAction)
                }
            }.padding(.horizontal, 16).frame(height: 40)
            Divider()
            content.padding(16).frame(maxWidth: .infinity, maxHeight: height == nil ? nil : .infinity, alignment: .topLeading)
            if hasFooter {
                Divider()
                footer.padding(.horizontal, 16).frame(minHeight: 44)
            }
        }
        .frame(width: width, height: height)
        .modifier(NativeWorkspaceSurface())
        .controlSize(.regular)
        .background {
            if let action = close ?? cancel {
                NativeSheetExitHandler(cancel: action).frame(width: 0, height: 0)
            }
        }
    }
}

extension NativeSheet where Footer == EmptyView {
    init(_ title: String, width: CGFloat = 416, height: CGFloat? = nil,
         close: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.width = width; self.height = height; self.close = close
        self.hasFooter = false; self.content = content(); self.footer = EmptyView()
    }
}

struct NativeFormRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(AppLocalization.string(title)).foregroundStyle(NativePalette.secondary)
                .frame(width: 80, alignment: .leading)
            content.frame(maxWidth: .infinity, alignment: .leading).labelsHidden()
        }
        .font(NativeStyle.FontRole.body).frame(minHeight: 26)
    }
}

struct NativeSheetActions: View {
    let cancel: () -> Void
    let title: String
    let submit: () -> Void
    var disabled = false
    var body: some View {
        HStack(spacing: 12) {
            Spacer()
            Button(AppLocalization.string("取消"), action: cancel).keyboardShortcut(.cancelAction)
            Button(AppLocalization.string(title), action: submit)
                .modifier(NativeWorkspacePrimary()).disabled(disabled)
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// Standard AppKit popup control fills the same column as native text fields.
struct NativeFormPicker: NSViewRepresentable {
    let title: String
    let options: [String]
    let selectedIndex: Int
    let select: (Int) -> Void

    final class Coordinator: NSObject {
        var owner: NativeFormPicker
        init(_ owner: NativeFormPicker) { self.owner = owner }
        @objc func changed(_ sender: NSPopUpButton) { owner.select(sender.indexOfSelectedItem) }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator; button.action = #selector(Coordinator.changed(_:))
        button.font = .systemFont(ofSize: 13)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.owner = self
        if button.itemTitles != options { button.removeAllItems(); button.addItems(withTitles: options) }
        if options.indices.contains(selectedIndex) { button.selectItem(at: selectedIndex) }
        button.isEnabled = context.environment.isEnabled
        button.setAccessibilityLabel(AppLocalization.string(title))
    }
}

/// Handle Escape before a focused AppKit field consumes cancelOperation.
private struct NativeSheetExitHandler: NSViewRepresentable {
    let cancel: () -> Void
    func makeNSView(context: Context) -> ExitView { ExitView() }
    func updateNSView(_ view: ExitView, context: Context) { view.cancel = cancel }
    static func dismantleNSView(_ view: ExitView, coordinator: ()) { view.stop() }

    final class ExitView: NSView {
        var cancel: () -> Void = {}
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      event.keyCode == 53 else { return event }
                self.cancel()
                return nil
            }
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

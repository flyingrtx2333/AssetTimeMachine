import AppKit
import SwiftUI

// macOS design system. Change visual roles here; keep page geometry and business rules in views.
// Black/gold and white/gold resolve through NativePalette with the window appearance.
enum NativeStyle {
    enum FontRole {
        static let chartLabel = Font.system(size: 9)
        static let micro = Font.system(size: 10)
        static let microStrong = Font.system(size: 10, weight: .medium)
        static let caption = Font.system(size: 11)
        static let captionStrong = Font.system(size: 11, weight: .medium)
        static let body = Font.system(size: 12)
        static let action = Font.system(size: 12, weight: .medium)
        static let bodyStrong = Font.system(size: 12, weight: .semibold)
        static let input = Font.system(size: 13)
        static let inputStrong = Font.system(size: 13, weight: .medium)
        static let section = Font.system(size: 14)
        static let sectionStrong = Font.system(size: 14, weight: .semibold)
        static let icon = Font.system(size: 15)
        static let iconLight = Font.system(size: 15, weight: .light)
        static let iconStrong = Font.system(size: 15, weight: .medium)
        static let subheading = Font.system(size: 16)
        static let subheadingStrong = Font.system(size: 16, weight: .medium)
        static let emphasis = Font.system(size: 17)
        static let metric = Font.system(size: 18)
        static let metricStrong = Font.system(size: 18, weight: .medium)
        static let dialogTitle = Font.system(size: 20, weight: .semibold)
        static let sectionTitle = Font.system(size: 20, weight: .medium)
        static let pageTitle = Font.system(size: 24, weight: .medium)
        static let summary = Font.system(size: 24, weight: .semibold)
        static let brandSymbol = Font.system(size: 31)
        static let display = Font.system(size: 34, weight: .medium)
        static let displayRegular = Font.system(size: 34)
        static let largeDisplay = Font.system(size: 42)
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
        static let panel: CGFloat = 12
        static let dialog: CGFloat = 20
    }
    // Shared desktop density; chart drawing coordinates remain local to their views.
    enum Layout {
        static let pageInset: CGFloat = 20
        static let windowMinWidth: CGFloat = 800
        static let ledgerMaxWidth: CGFloat = 620
        static let quantityWidth: CGFloat = 72
        static let unitPriceWidth: CGFloat = 104
        static let amountWidth: CGFloat = 108
        static let sectionGap: CGFloat = 16
        static let sidebarWidth: CGFloat = 128
        static let brandHeight: CGFloat = 64
        static let navigationHeight: CGFloat = 34
        static let ledgerRowHeight: CGFloat = 30
        static let ledgerFieldHeight: CGFloat = 24
        static let ledgerGroupHeight: CGFloat = 28
        static let homeHeaderHeight: CGFloat = 80
        static let homeDetailsHeight: CGFloat = 174
        static let homeChartMaxHeight: CGFloat = 200
        static let emptyStateHeight: CGFloat = 80
    }
    enum Control {
        static let height: CGFloat = 30
        static let fieldHeight: CGFloat = 30
        static let accountFieldHeight: CGFloat = 40
        static let horizontalPadding: CGFloat = 14
    }
    enum Motion {
        static func quantTransition(_ reducedMotion: Bool) -> AnyTransition {
            reducedMotion ? .opacity : .scale(scale: 0.98, anchor: .topTrailing).combined(with: .opacity)
        }
        static let reduced = Animation.easeOut(duration: 0.08)
        static func home(_ reducedMotion: Bool) -> Animation {
            reducedMotion ? reduced : .spring(duration: 0.32, bounce: 0)
        }
        static func records(_ reducedMotion: Bool) -> Animation {
            reducedMotion ? reduced : .spring(duration: 0.30, bounce: 0)
        }
        static func quant(_ reducedMotion: Bool) -> Animation {
            reducedMotion ? reduced : .spring(duration: 0.38, bounce: 0.12)
        }
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
    static let canvas = adaptive(light: 0xFCFBF9, dark: 0x0B0B0A)
    static let sidebar = adaptive(light: 0xF3F1EC, dark: 0x111110)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x191917)
    static let line = adaptive(light: 0xDDD8CF, dark: 0x30302B)
    static let softGold = adaptive(light: 0xF0E8D8, dark: 0x2B2418)
    static let accent = adaptive(light: 0x896721, dark: 0xD0AA6A)
    static let text = adaptive(light: 0x26231D, dark: 0xECE9E2)
    static let secondary = adaptive(light: 0x716B60, dark: 0xAAA59A)
    static let onAccent = adaptive(light: 0xFFFFFF, dark: 0x18140D)
    static let cash = adaptive(light: 0xC5C0B5, dark: 0x504B41)
    static let goldAllocation = adaptive(light: 0xDED3BC, dark: 0x645438)
    static let allocationLight = adaptive(light: 0xEDEAE3, dark: 0x2F2E29)
    static let allocationMedium = adaptive(light: 0xE0DDD5, dark: 0x3B3932)
    static let allocationDark = adaptive(light: 0xD6D1C5, dark: 0x484337)
    static let chartSecondary = adaptive(light: 0x777268, dark: 0xBAB5A9)
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
    private var reduced: Bool { systemReduced || NativeHomeStyle.previewReduced }
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(NativeHomeStyle.text.opacity(configuration.isPressed ? 0.075 : (hovered ? 0.035 : 0)),
                        in: RoundedRectangle(cornerRadius: NativeStyle.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: NativeStyle.Radius.control).stroke(NativeHomeStyle.accent.opacity(hovered ? 0.3 : 0), lineWidth: 0.7))
            .scaleEffect(reduced ? 1 : (configuration.isPressed ? 0.975 : 1))
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
            .tint(NativeHomeStyle.accent)
            .buttonStyle(NativeHomeButtonStyle())
    }
}

struct NativeWorkspacePrimary: ViewModifier {
    func body(content: Content) -> some View {
        content.font(NativeStyle.FontRole.action).padding(.horizontal, NativeStyle.Control.horizontalPadding).frame(height: NativeStyle.Control.height)
            .foregroundStyle(NativePalette.onAccent).background(NativePalette.accent, in: RoundedRectangle(cornerRadius: NativeStyle.Radius.control))
            .buttonStyle(NativeHomeButtonStyle())
    }
}

struct NativeRecordsButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false
    private var reduced: Bool { systemReduced || NativeHomeStyle.previewReduced }
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(hovered ? 0.045 : 0)
            .opacity(enabled ? (configuration.isPressed ? 0.68 : 1) : 0.35)
            .scaleEffect(reduced ? 1 : (configuration.isPressed ? 0.985 : 1))
            .background(NativeHomeStyle.text.opacity(hovered ? 0.035 : 0), in: RoundedRectangle(cornerRadius: NativeStyle.Radius.control))
            .onHover { hovered = $0 }
            .animation(NativeStyle.Motion.records(reduced), value: hovered)
            .animation(NativeStyle.Motion.records(reduced), value: configuration.isPressed)
    }
}

struct NativeRecordsPrimary: ViewModifier {
    func body(content: Content) -> some View {
        content.font(NativeStyle.FontRole.action).padding(.horizontal, NativeStyle.Control.horizontalPadding).frame(height: NativeStyle.Control.height)
            .foregroundStyle(NativePalette.onAccent).background(NativeHomeStyle.accent, in: RoundedRectangle(cornerRadius: NativeStyle.Radius.control))
            .buttonStyle(NativeRecordsButtonStyle())
    }
}

struct AccountFieldStyle: ViewModifier {
    let isFocused: Bool
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(NativeStyle.FontRole.input)
            .padding(.horizontal, NativeStyle.Space.md)
            .frame(height: NativeStyle.Control.accountFieldHeight)
            .background(NativeHomeStyle.text.opacity(0.035), in: RoundedRectangle(cornerRadius: NativeStyle.Radius.field))
            .overlay {
                RoundedRectangle(cornerRadius: NativeStyle.Radius.field)
                    .strokeBorder(isFocused ? NativeHomeStyle.accent.opacity(0.7) : NativeHomeStyle.line)
            }
    }
}

struct NativeQuantFeedback: ButtonStyle {
    let reduced: Bool
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(NativePalette.accent.opacity(hovered ? 0.07 : 0), in: RoundedRectangle(cornerRadius: NativeStyle.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: NativeStyle.Radius.control).stroke(NativePalette.accent.opacity(focused ? 0.8 : 0), lineWidth: 1))
            .opacity(enabled ? (configuration.isPressed ? 0.66 : 1) : 0.4)
            .scaleEffect(reduced || !configuration.isPressed ? 1 : 0.97)
            .onHover { hovered = $0 }
            .animation(NativeStyle.Motion.quant(reduced), value: hovered)
            .animation(NativeStyle.Motion.quant(reduced), value: configuration.isPressed)
    }
}

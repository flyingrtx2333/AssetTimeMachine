import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

enum AssetTheme {
    #if canImport(UIKit)
    private static func uiColor(_ components: AssetRGBA) -> UIColor {
        UIColor(
            red: CGFloat(components.red),
            green: CGFloat(components.green),
            blue: CGFloat(components.blue),
            alpha: CGFloat(components.alpha)
        )
    }

    private static func dynamicUIColor(_ token: AssetAdaptiveColorToken) -> UIColor {
        UIColor { traits in
            uiColor(
                traits.userInterfaceStyle == .dark
                    ? token.darkGold
                    : token.daylightGold
            )
        }
    }

    // MARK: - Neutral surfaces

    static var backgroundUIColor: UIColor {
        dynamicUIColor(AssetColorPalette.background)
    }

    static var backgroundSecondaryUIColor: UIColor {
        dynamicUIColor(AssetColorPalette.backgroundSecondary)
    }

    static var surfaceUIColor: UIColor {
        dynamicUIColor(AssetColorPalette.surface)
    }

    static var surfaceRaisedUIColor: UIColor {
        dynamicUIColor(AssetColorPalette.surfaceRaised)
    }

    static var borderUIColor: UIColor {
        dynamicUIColor(AssetColorPalette.border)
    }

    // MARK: - Brand and semantic colors

    static var goldUIColor: UIColor {
        dynamicUIColor(AssetColorPalette.gold)
    }

    static var goldSoftUIColor: UIColor {
        dynamicUIColor(AssetColorPalette.goldSoft)
    }

    static var textPrimaryUIColor: UIColor {
        dynamicUIColor(AssetColorPalette.textPrimary)
    }

    static var textSecondaryUIColor: UIColor {
        dynamicUIColor(AssetColorPalette.textSecondary)
    }

    static var positiveUIColor: UIColor {
        dynamicUIColor(AssetColorPalette.positive)
    }

    static var negativeUIColor: UIColor {
        dynamicUIColor(AssetColorPalette.negative)
    }

    static var accentBlueUIColor: UIColor {
        dynamicUIColor(AssetColorPalette.accentBlue)
    }

    static var accentOrangeUIColor: UIColor {
        dynamicUIColor(AssetColorPalette.accentOrange)
    }

    static var accentRedUIColor: UIColor {
        dynamicUIColor(AssetColorPalette.accentRed)
    }

    // MARK: - Overlays and chart chrome

    static var overlayFaintUIColor: UIColor {
        dynamicUIColor(AssetColorPalette.overlayFaint)
    }

    static var overlaySoftUIColor: UIColor {
        dynamicUIColor(AssetColorPalette.overlaySoft)
    }

    static var overlaySubtleUIColor: UIColor {
        dynamicUIColor(AssetColorPalette.overlaySubtle)
    }

    static var overlayMediumUIColor: UIColor {
        dynamicUIColor(AssetColorPalette.overlayMedium)
    }

    static var overlayStrongUIColor: UIColor {
        dynamicUIColor(AssetColorPalette.overlayStrong)
    }

    static var chartGridUIColor: UIColor {
        dynamicUIColor(AssetColorPalette.chartGrid)
    }

    static var chartTickUIColor: UIColor {
        dynamicUIColor(AssetColorPalette.chartTick)
    }

    static var cardShadowUIColor: UIColor {
        dynamicUIColor(AssetColorPalette.cardShadow)
    }
    #endif

    static var background: Color { Color(uiColor: backgroundUIColor) }
    static var backgroundSecondary: Color { Color(uiColor: backgroundSecondaryUIColor) }
    static var surface: Color { Color(uiColor: surfaceUIColor) }
    static var surfaceRaised: Color { Color(uiColor: surfaceRaisedUIColor) }
    static var border: Color { Color(uiColor: borderUIColor) }
    static var gold: Color { Color(uiColor: goldUIColor) }
    static var goldSoft: Color { Color(uiColor: goldSoftUIColor) }
    static var textPrimary: Color { Color(uiColor: textPrimaryUIColor) }
    static var textSecondary: Color { Color(uiColor: textSecondaryUIColor) }
    static var positive: Color { Color(uiColor: positiveUIColor) }
    static var negative: Color { Color(uiColor: negativeUIColor) }
    static var accentBlue: Color { Color(uiColor: accentBlueUIColor) }
    static var accentOrange: Color { Color(uiColor: accentOrangeUIColor) }
    static var accentRed: Color { Color(uiColor: accentRedUIColor) }
    static var overlayFaint: Color { Color(uiColor: overlayFaintUIColor) }
    static var overlaySoft: Color { Color(uiColor: overlaySoftUIColor) }
    static var overlaySubtle: Color { Color(uiColor: overlaySubtleUIColor) }
    static var overlayMedium: Color { Color(uiColor: overlayMediumUIColor) }
    static var overlayStrong: Color { Color(uiColor: overlayStrongUIColor) }
    static var chartGrid: Color { Color(uiColor: chartGridUIColor) }
    static var chartTick: Color { Color(uiColor: chartTickUIColor) }
    static var cardShadow: Color { Color(uiColor: cardShadowUIColor) }

    static var pageGradient: LinearGradient {
        LinearGradient(
            colors: [background, backgroundSecondary],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    static var cardGradient: LinearGradient {
        LinearGradient(
            colors: [surfaceRaised, surface],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    static var heroGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(uiColor: dynamicUIColor(AssetColorPalette.heroStart)),
                Color(uiColor: dynamicUIColor(AssetColorPalette.heroEnd))
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static func configureSystemAppearance() {
        #if canImport(UIKit)
        let tabBarAppearance = UITabBarAppearance()
        tabBarAppearance.configureWithOpaqueBackground()
        tabBarAppearance.backgroundColor = backgroundUIColor
        tabBarAppearance.shadowColor = borderUIColor

        let normalColor = textSecondaryUIColor
        let selectedColor = goldUIColor

        tabBarAppearance.selectionIndicatorTintColor = dynamicUIColor(AssetColorPalette.selection)

        [tabBarAppearance.stackedLayoutAppearance,
         tabBarAppearance.inlineLayoutAppearance,
         tabBarAppearance.compactInlineLayoutAppearance].forEach { appearance in
            appearance.normal.iconColor = normalColor
            appearance.normal.titleTextAttributes = [
                .foregroundColor: normalColor,
                .font: UIFont.systemFont(ofSize: 10, weight: .regular)
            ]
            appearance.selected.iconColor = selectedColor
            appearance.selected.titleTextAttributes = [
                .foregroundColor: selectedColor,
                .font: UIFont.systemFont(ofSize: 10, weight: .medium)
            ]
        }

        UITabBar.appearance().standardAppearance = tabBarAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabBarAppearance

        let navigationAppearance = UINavigationBarAppearance()
        navigationAppearance.configureWithOpaqueBackground()
        navigationAppearance.backgroundColor = backgroundUIColor
        navigationAppearance.shadowColor = .clear
        navigationAppearance.largeTitleTextAttributes = [
            .foregroundColor: textPrimaryUIColor,
            .font: UIFont.systemFont(ofSize: 32, weight: .semibold)
        ]
        navigationAppearance.titleTextAttributes = [
            .foregroundColor: textPrimaryUIColor,
            .font: UIFont.systemFont(ofSize: 17, weight: .semibold)
        ]

        UINavigationBar.appearance().standardAppearance = navigationAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navigationAppearance
        UINavigationBar.appearance().compactAppearance = navigationAppearance
        #endif
    }
}

struct ATMCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(AssetTheme.cardGradient)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(AssetTheme.border.opacity(0.72), lineWidth: 0.5)
            )
            .shadow(color: AssetTheme.cardShadow, radius: 16, x: 0, y: 8)
    }
}

extension View {
    func atmCardStyle() -> some View {
        modifier(ATMCardModifier())
    }
}

enum AppAppearanceMode: String, CaseIterable, Identifiable {
    static let defaultsKey = "app.appearanceMode"

    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return AppLocalization.string("跟随系统")
        case .light: return AppLocalization.string("日间白金")
        case .dark: return AppLocalization.string("深色金")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

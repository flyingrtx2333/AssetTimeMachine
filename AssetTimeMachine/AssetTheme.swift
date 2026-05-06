import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

enum AssetTheme {
    #if canImport(UIKit)
    private static func rgba(_ red: Int, _ green: Int, _ blue: Int, alpha: CGFloat = 1) -> UIColor {
        UIColor(
            red: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: alpha
        )
    }

    private static func dynamicUIColor(light: UIColor, dark: UIColor) -> UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        }
    }

    static var backgroundUIColor: UIColor {
        dynamicUIColor(light: rgba(248, 244, 238), dark: rgba(12, 12, 15))
    }

    static var backgroundSecondaryUIColor: UIColor {
        dynamicUIColor(light: rgba(237, 230, 220), dark: rgba(24, 20, 17))
    }

    static var surfaceUIColor: UIColor {
        dynamicUIColor(light: rgba(255, 252, 247), dark: rgba(22, 22, 26))
    }

    static var surfaceRaisedUIColor: UIColor {
        dynamicUIColor(light: rgba(246, 239, 229), dark: rgba(30, 28, 24))
    }

    static var borderUIColor: UIColor {
        dynamicUIColor(light: rgba(122, 94, 58, alpha: 0.18), dark: rgba(92, 73, 44, alpha: 0.45))
    }

    static var goldUIColor: UIColor {
        dynamicUIColor(light: rgba(176, 128, 69), dark: rgba(212, 175, 127))
    }

    static var goldSoftUIColor: UIColor {
        dynamicUIColor(light: rgba(128, 93, 52), dark: rgba(244, 210, 161))
    }

    static var textPrimaryUIColor: UIColor {
        dynamicUIColor(light: rgba(39, 33, 28), dark: rgba(244, 236, 224))
    }

    static var textSecondaryUIColor: UIColor {
        dynamicUIColor(light: rgba(110, 100, 86), dark: rgba(167, 159, 145))
    }

    static var positiveUIColor: UIColor {
        dynamicUIColor(light: rgba(42, 139, 88), dark: rgba(99, 201, 140))
    }

    static var negativeUIColor: UIColor {
        dynamicUIColor(light: rgba(190, 78, 68), dark: rgba(222, 99, 90))
    }

    static var accentBlueUIColor: UIColor {
        dynamicUIColor(light: rgba(55, 117, 205), dark: rgba(74, 144, 226))
    }

    static var accentOrangeUIColor: UIColor {
        dynamicUIColor(light: rgba(212, 137, 36), dark: rgba(245, 166, 35))
    }

    static var accentRedUIColor: UIColor {
        dynamicUIColor(light: rgba(207, 102, 44), dark: rgba(231, 124, 60))
    }

    static var overlayFaintUIColor: UIColor {
        dynamicUIColor(light: rgba(32, 26, 20, alpha: 0.025), dark: rgba(255, 255, 255, alpha: 0.035))
    }

    static var overlaySoftUIColor: UIColor {
        dynamicUIColor(light: rgba(32, 26, 20, alpha: 0.03), dark: rgba(255, 255, 255, alpha: 0.03))
    }

    static var overlaySubtleUIColor: UIColor {
        dynamicUIColor(light: rgba(32, 26, 20, alpha: 0.04), dark: rgba(255, 255, 255, alpha: 0.04))
    }

    static var overlayMediumUIColor: UIColor {
        dynamicUIColor(light: rgba(32, 26, 20, alpha: 0.05), dark: rgba(255, 255, 255, alpha: 0.05))
    }

    static var overlayStrongUIColor: UIColor {
        dynamicUIColor(light: rgba(32, 26, 20, alpha: 0.08), dark: rgba(255, 255, 255, alpha: 0.08))
    }

    static var chartGridUIColor: UIColor {
        dynamicUIColor(light: rgba(39, 33, 28, alpha: 0.08), dark: rgba(255, 255, 255, alpha: 0.08))
    }

    static var chartTickUIColor: UIColor {
        dynamicUIColor(light: rgba(39, 33, 28, alpha: 0.15), dark: rgba(255, 255, 255, alpha: 0.15))
    }

    static var cardShadowUIColor: UIColor {
        dynamicUIColor(light: rgba(26, 22, 17, alpha: 0.10), dark: rgba(0, 0, 0, alpha: 0.22))
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
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var cardGradient: LinearGradient {
        LinearGradient(
            colors: [surfaceRaised, surface],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var heroGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(uiColor: dynamicUIColor(light: rgba(250, 243, 232), dark: rgba(39, 31, 22))),
                Color(uiColor: dynamicUIColor(light: rgba(239, 230, 218), dark: rgba(24, 22, 20)))
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

        tabBarAppearance.selectionIndicatorTintColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? rgba(212, 175, 127, alpha: 0.18)
                : rgba(176, 128, 69, alpha: 0.12)
        }

        [tabBarAppearance.stackedLayoutAppearance,
         tabBarAppearance.inlineLayoutAppearance,
         tabBarAppearance.compactInlineLayoutAppearance].forEach { appearance in
            appearance.normal.iconColor = normalColor
            appearance.normal.titleTextAttributes = [.foregroundColor: normalColor]
            appearance.selected.iconColor = selectedColor
            appearance.selected.titleTextAttributes = [.foregroundColor: selectedColor]
        }

        UITabBar.appearance().standardAppearance = tabBarAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabBarAppearance

        let navigationAppearance = UINavigationBarAppearance()
        navigationAppearance.configureWithOpaqueBackground()
        navigationAppearance.backgroundColor = backgroundUIColor
        navigationAppearance.shadowColor = .clear
        navigationAppearance.largeTitleTextAttributes = [.foregroundColor: textPrimaryUIColor]
        navigationAppearance.titleTextAttributes = [.foregroundColor: textPrimaryUIColor]

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
            .shadow(color: AssetTheme.cardShadow, radius: 24, x: 0, y: 12)
    }
}

extension View {
    func atmCardStyle() -> some View {
        modifier(ATMCardModifier())
    }
}

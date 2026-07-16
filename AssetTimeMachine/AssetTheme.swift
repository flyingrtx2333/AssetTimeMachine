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

    // MARK: - Neutral surfaces

    static var backgroundUIColor: UIColor {
        dynamicUIColor(light: rgba(246, 244, 240), dark: rgba(12, 13, 16))
    }

    static var backgroundSecondaryUIColor: UIColor {
        dynamicUIColor(light: rgba(241, 238, 233), dark: rgba(16, 17, 21))
    }

    static var surfaceUIColor: UIColor {
        dynamicUIColor(light: rgba(255, 255, 255), dark: rgba(20, 21, 25))
    }

    static var surfaceRaisedUIColor: UIColor {
        dynamicUIColor(light: rgba(249, 247, 243), dark: rgba(27, 28, 33))
    }

    static var borderUIColor: UIColor {
        dynamicUIColor(
            light: rgba(38, 35, 31, alpha: 0.10),
            dark: rgba(255, 255, 255, alpha: 0.09)
        )
    }

    // MARK: - Brand and semantic colors

    static var goldUIColor: UIColor {
        dynamicUIColor(light: rgba(171, 132, 79), dark: rgba(201, 164, 106))
    }

    static var goldSoftUIColor: UIColor {
        dynamicUIColor(light: rgba(125, 100, 67), dark: rgba(226, 194, 143))
    }

    static var textPrimaryUIColor: UIColor {
        dynamicUIColor(light: rgba(32, 31, 29), dark: rgba(241, 239, 234))
    }

    static var textSecondaryUIColor: UIColor {
        dynamicUIColor(light: rgba(105, 102, 96), dark: rgba(162, 160, 154))
    }

    static var positiveUIColor: UIColor {
        dynamicUIColor(light: rgba(43, 133, 84), dark: rgba(93, 183, 128))
    }

    static var negativeUIColor: UIColor {
        dynamicUIColor(light: rgba(183, 75, 68), dark: rgba(218, 102, 92))
    }

    static var accentBlueUIColor: UIColor {
        dynamicUIColor(light: rgba(75, 111, 156), dark: rgba(103, 146, 199))
    }

    static var accentOrangeUIColor: UIColor {
        dynamicUIColor(light: rgba(174, 119, 57), dark: rgba(211, 152, 80))
    }

    static var accentRedUIColor: UIColor {
        dynamicUIColor(light: rgba(172, 82, 62), dark: rgba(211, 112, 88))
    }

    // MARK: - Overlays and chart chrome

    static var overlayFaintUIColor: UIColor {
        dynamicUIColor(light: rgba(32, 31, 29, alpha: 0.018), dark: rgba(255, 255, 255, alpha: 0.025))
    }

    static var overlaySoftUIColor: UIColor {
        dynamicUIColor(light: rgba(32, 31, 29, alpha: 0.028), dark: rgba(255, 255, 255, alpha: 0.035))
    }

    static var overlaySubtleUIColor: UIColor {
        dynamicUIColor(light: rgba(32, 31, 29, alpha: 0.040), dark: rgba(255, 255, 255, alpha: 0.045))
    }

    static var overlayMediumUIColor: UIColor {
        dynamicUIColor(light: rgba(32, 31, 29, alpha: 0.055), dark: rgba(255, 255, 255, alpha: 0.060))
    }

    static var overlayStrongUIColor: UIColor {
        dynamicUIColor(light: rgba(32, 31, 29, alpha: 0.085), dark: rgba(255, 255, 255, alpha: 0.090))
    }

    static var chartGridUIColor: UIColor {
        dynamicUIColor(light: rgba(32, 31, 29, alpha: 0.055), dark: rgba(255, 255, 255, alpha: 0.060))
    }

    static var chartTickUIColor: UIColor {
        dynamicUIColor(light: rgba(32, 31, 29, alpha: 0.12), dark: rgba(255, 255, 255, alpha: 0.13))
    }

    static var cardShadowUIColor: UIColor {
        dynamicUIColor(light: rgba(26, 24, 21, alpha: 0.07), dark: rgba(0, 0, 0, alpha: 0.20))
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
                Color(uiColor: dynamicUIColor(light: rgba(250, 247, 241), dark: rgba(31, 28, 24))),
                Color(uiColor: dynamicUIColor(light: rgba(242, 237, 229), dark: rgba(20, 21, 25)))
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
                ? rgba(201, 164, 106, alpha: 0.13)
                : rgba(171, 132, 79, alpha: 0.09)
        }

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
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return AppLocalization.string("跟随系统")
        case .light: return AppLocalization.string("浅色")
        case .dark: return AppLocalization.string("深色")
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

import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

enum AssetTheme {
    static let background = Color(red: 12 / 255, green: 12 / 255, blue: 15 / 255)
    static let backgroundSecondary = Color(red: 24 / 255, green: 20 / 255, blue: 17 / 255)
    static let surface = Color(red: 22 / 255, green: 22 / 255, blue: 26 / 255)
    static let surfaceRaised = Color(red: 30 / 255, green: 28 / 255, blue: 24 / 255)
    static let border = Color(red: 92 / 255, green: 73 / 255, blue: 44 / 255).opacity(0.45)
    static let gold = Color(red: 212 / 255, green: 175 / 255, blue: 127 / 255)
    static let goldSoft = Color(red: 244 / 255, green: 210 / 255, blue: 161 / 255)
    static let textPrimary = Color(red: 244 / 255, green: 236 / 255, blue: 224 / 255)
    static let textSecondary = Color(red: 167 / 255, green: 159 / 255, blue: 145 / 255)
    static let positive = Color(red: 99 / 255, green: 201 / 255, blue: 140 / 255)
    static let negative = Color(red: 222 / 255, green: 99 / 255, blue: 90 / 255)
    static let accentBlue = Color(red: 74 / 255, green: 144 / 255, blue: 226 / 255)
    static let accentOrange = Color(red: 245 / 255, green: 166 / 255, blue: 35 / 255)
    static let accentRed = Color(red: 231 / 255, green: 124 / 255, blue: 60 / 255)

    static let pageGradient = LinearGradient(
        colors: [background, backgroundSecondary],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let cardGradient = LinearGradient(
        colors: [surfaceRaised, surface],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let heroGradient = LinearGradient(
        colors: [Color(red: 39 / 255, green: 31 / 255, blue: 22 / 255), Color(red: 24 / 255, green: 22 / 255, blue: 20 / 255)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static func configureSystemAppearance() {
        #if canImport(UIKit)
        let tabBarAppearance = UITabBarAppearance()
        tabBarAppearance.configureWithOpaqueBackground()
        tabBarAppearance.backgroundColor = UIColor(background)
        tabBarAppearance.shadowColor = UIColor(border)

        let normalColor = UIColor(textSecondary)
        let selectedColor = UIColor(gold)

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
        navigationAppearance.backgroundColor = UIColor(background)
        navigationAppearance.shadowColor = .clear
        navigationAppearance.largeTitleTextAttributes = [.foregroundColor: UIColor(textPrimary)]
        navigationAppearance.titleTextAttributes = [.foregroundColor: UIColor(textPrimary)]

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
                    .stroke(AssetTheme.border, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.22), radius: 24, x: 0, y: 12)
    }
}

extension View {
    func atmCardStyle() -> some View {
        modifier(ATMCardModifier())
    }
}

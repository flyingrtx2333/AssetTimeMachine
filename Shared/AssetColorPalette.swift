import Foundation

nonisolated struct AssetRGBA: Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    init(_ red: Int, _ green: Int, _ blue: Int, alpha: Double = 1) {
        self.red = Double(red) / 255
        self.green = Double(green) / 255
        self.blue = Double(blue) / 255
        self.alpha = alpha
    }
}

nonisolated struct AssetAdaptiveColorToken: Sendable {
    let daylightGold: AssetRGBA
    let darkGold: AssetRGBA
}

/// The single color source for the main app and WidgetKit extension.
/// Layout and typography stay independent from the selected palette.
nonisolated enum AssetColorPalette {
    static let background = AssetAdaptiveColorToken(
        daylightGold: AssetRGBA(255, 253, 248),
        darkGold: AssetRGBA(12, 13, 16)
    )
    static let backgroundSecondary = AssetAdaptiveColorToken(
        daylightGold: AssetRGBA(249, 245, 237),
        darkGold: AssetRGBA(16, 17, 21)
    )
    static let surface = AssetAdaptiveColorToken(
        daylightGold: AssetRGBA(255, 255, 255),
        darkGold: AssetRGBA(20, 21, 25)
    )
    static let surfaceRaised = AssetAdaptiveColorToken(
        daylightGold: AssetRGBA(255, 250, 241),
        darkGold: AssetRGBA(27, 28, 33)
    )
    static let border = AssetAdaptiveColorToken(
        daylightGold: AssetRGBA(151, 111, 53, alpha: 0.16),
        darkGold: AssetRGBA(255, 255, 255, alpha: 0.09)
    )

    static let gold = AssetAdaptiveColorToken(
        daylightGold: AssetRGBA(174, 126, 55),
        darkGold: AssetRGBA(201, 164, 106)
    )
    static let goldSoft = AssetAdaptiveColorToken(
        daylightGold: AssetRGBA(126, 89, 38),
        darkGold: AssetRGBA(226, 194, 143)
    )
    static let textPrimary = AssetAdaptiveColorToken(
        daylightGold: AssetRGBA(34, 29, 22),
        darkGold: AssetRGBA(241, 239, 234)
    )
    static let textSecondary = AssetAdaptiveColorToken(
        daylightGold: AssetRGBA(108, 99, 87),
        darkGold: AssetRGBA(162, 160, 154)
    )
    static let positive = AssetAdaptiveColorToken(
        daylightGold: AssetRGBA(43, 133, 84),
        darkGold: AssetRGBA(93, 183, 128)
    )
    static let negative = AssetAdaptiveColorToken(
        daylightGold: AssetRGBA(183, 75, 68),
        darkGold: AssetRGBA(218, 102, 92)
    )
    static let accentBlue = AssetAdaptiveColorToken(
        daylightGold: AssetRGBA(75, 111, 156),
        darkGold: AssetRGBA(103, 146, 199)
    )
    static let accentOrange = AssetAdaptiveColorToken(
        daylightGold: AssetRGBA(174, 119, 57),
        darkGold: AssetRGBA(211, 152, 80)
    )
    static let accentRed = AssetAdaptiveColorToken(
        daylightGold: AssetRGBA(172, 82, 62),
        darkGold: AssetRGBA(211, 112, 88)
    )

    static let overlayFaint = AssetAdaptiveColorToken(
        daylightGold: AssetRGBA(66, 50, 29, alpha: 0.020),
        darkGold: AssetRGBA(255, 255, 255, alpha: 0.025)
    )
    static let overlaySoft = AssetAdaptiveColorToken(
        daylightGold: AssetRGBA(118, 82, 34, alpha: 0.035),
        darkGold: AssetRGBA(255, 255, 255, alpha: 0.035)
    )
    static let overlaySubtle = AssetAdaptiveColorToken(
        daylightGold: AssetRGBA(118, 82, 34, alpha: 0.050),
        darkGold: AssetRGBA(255, 255, 255, alpha: 0.045)
    )
    static let overlayMedium = AssetAdaptiveColorToken(
        daylightGold: AssetRGBA(118, 82, 34, alpha: 0.070),
        darkGold: AssetRGBA(255, 255, 255, alpha: 0.060)
    )
    static let overlayStrong = AssetAdaptiveColorToken(
        daylightGold: AssetRGBA(118, 82, 34, alpha: 0.105),
        darkGold: AssetRGBA(255, 255, 255, alpha: 0.090)
    )
    static let chartGrid = AssetAdaptiveColorToken(
        daylightGold: AssetRGBA(91, 72, 45, alpha: 0.075),
        darkGold: AssetRGBA(255, 255, 255, alpha: 0.060)
    )
    static let chartTick = AssetAdaptiveColorToken(
        daylightGold: AssetRGBA(91, 72, 45, alpha: 0.15),
        darkGold: AssetRGBA(255, 255, 255, alpha: 0.13)
    )
    static let cardShadow = AssetAdaptiveColorToken(
        daylightGold: AssetRGBA(72, 48, 17, alpha: 0.08),
        darkGold: AssetRGBA(0, 0, 0, alpha: 0.20)
    )
    static let heroStart = AssetAdaptiveColorToken(
        daylightGold: AssetRGBA(255, 252, 245),
        darkGold: AssetRGBA(31, 28, 24)
    )
    static let heroEnd = AssetAdaptiveColorToken(
        daylightGold: AssetRGBA(248, 240, 226),
        darkGold: AssetRGBA(20, 21, 25)
    )
    static let selection = AssetAdaptiveColorToken(
        daylightGold: AssetRGBA(174, 126, 55, alpha: 0.10),
        darkGold: AssetRGBA(201, 164, 106, alpha: 0.13)
    )
}

import SwiftUI

enum AppTypography {
    private static func font(_ size: CGFloat, style: Font.TextStyle, weight: Font.Weight) -> Font {
        #if targetEnvironment(macCatalyst)
        .system(size: platformSize(size), weight: weight)
        #else
        .system(style, design: .default, weight: weight)
        #endif
    }
    private static func platformSize(_ iPhoneSize: CGFloat) -> CGFloat {
        #if targetEnvironment(macCatalyst)
        switch iPhoneSize {
        case 40...: return 28
        case 28..<40: return 22
        case 22..<28: return 18
        case 18..<22: return 14
        case 15..<18: return 13
        case 14..<15: return 12
        default: return iPhoneSize
        }
        #else
        return iPhoneSize
        #endif
    }

    // Editorial hierarchy: neutral SF Pro for structure, restrained weight for calm financial data.
    static let pageHero = font(30, style: .title, weight: .semibold)
    static let pageHeroMinor = font(18, style: .title3, weight: .medium)
    static let heroValue = font(42, style: .largeTitle, weight: .semibold)

    static let sectionTitle = font(20, style: .title3, weight: .semibold)
    static let blockTitleBold = font(17, style: .headline, weight: .semibold)
    static let blockTitle = font(17, style: .headline, weight: .medium)
    static let inputValue = font(17, style: .body, weight: .medium)

    static let rowTitle = font(16, style: .body, weight: .medium)
    static let rowValue = font(16, style: .body, weight: .semibold)
    static let metricValue = font(16, style: .body, weight: .semibold)
    static let body = font(15, style: .subheadline, weight: .regular)
    static let bodyStrong = font(15, style: .subheadline, weight: .medium)

    static let meta = font(14, style: .footnote, weight: .regular)
    static let metaStrong = font(14, style: .footnote, weight: .medium)
    static let eyebrow = font(12, style: .caption, weight: .semibold)
    static let caption = font(12, style: .caption, weight: .regular)
    static let captionStrong = font(12, style: .caption, weight: .medium)

    static let chip = font(12, style: .caption, weight: .medium)
    static let chipIcon = font(11, style: .caption, weight: .semibold)
    static let fieldLabel = font(12, style: .caption, weight: .medium)

    static let microLabel = font(10, style: .caption2, weight: .regular)
    static let microValue = font(13, style: .footnote, weight: .medium)

    static let chartLegend = font(11, style: .caption2, weight: .medium)
    static let chartLegendMedium = font(11, style: .caption2, weight: .regular)
    static let chartCaption = font(10.5, style: .caption2, weight: .regular)
    static let chartCaptionStrong = font(10.5, style: .caption2, weight: .medium)
    static let chartAxis = font(10, style: .caption2, weight: .regular)
    static let chartAxisCompact = font(9.5, style: .caption2, weight: .regular)
    static let chartAxisCompactStrong = font(9.5, style: .caption2, weight: .medium)
    static let chartAxisMini = font(9, style: .caption2, weight: .regular)
    static let chartAxisStrip = font(9, style: .caption2, weight: .medium)

    static let sheetTitle = font(22, style: .title2, weight: .semibold)
    static let sheetTitleSemibold = font(22, style: .title2, weight: .semibold)
    static let panelHero = font(28, style: .title, weight: .semibold)
}

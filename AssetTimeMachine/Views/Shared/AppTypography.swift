import SwiftUI

enum AppTypography {
    // Editorial hierarchy: neutral SF Pro for structure, restrained weight for calm financial data.
    static let pageHero = Font.system(size: 30, weight: .semibold, design: .default)
    static let pageHeroMinor = Font.system(size: 18, weight: .medium, design: .default)
    static let heroValue = Font.system(size: 42, weight: .semibold, design: .default)

    static let sectionTitle = Font.system(size: 20, weight: .semibold, design: .default)
    static let blockTitleBold = Font.system(size: 17, weight: .semibold, design: .default)
    static let blockTitle = Font.system(size: 17, weight: .medium, design: .default)
    static let inputValue = Font.system(size: 17, weight: .medium, design: .default)

    static let rowTitle = Font.system(size: 16, weight: .medium, design: .default)
    static let rowValue = Font.system(size: 16, weight: .semibold, design: .default)
    static let metricValue = Font.system(size: 16, weight: .semibold, design: .default)
    static let body = Font.system(size: 15, weight: .regular, design: .default)
    static let bodyStrong = Font.system(size: 15, weight: .medium, design: .default)

    static let meta = Font.system(size: 14, weight: .regular, design: .default)
    static let metaStrong = Font.system(size: 14, weight: .medium, design: .default)
    static let eyebrow = Font.system(size: 12, weight: .semibold, design: .default)
    static let caption = Font.system(size: 12, weight: .regular, design: .default)
    static let captionStrong = Font.system(size: 12, weight: .medium, design: .default)

    static let chip = Font.system(size: 12, weight: .medium, design: .default)
    static let chipIcon = Font.system(size: 11, weight: .semibold, design: .default)
    static let fieldLabel = Font.system(size: 12, weight: .medium, design: .default)

    static let microLabel = Font.system(size: 10, weight: .regular, design: .default)
    static let microValue = Font.system(size: 13, weight: .medium, design: .default)

    static let chartLegend = Font.system(size: 11, weight: .medium, design: .default)
    static let chartLegendMedium = Font.system(size: 11, weight: .regular, design: .default)
    static let chartCaption = Font.system(size: 10.5, weight: .regular, design: .default)
    static let chartCaptionStrong = Font.system(size: 10.5, weight: .medium, design: .default)
    static let chartAxis = Font.system(size: 10, weight: .regular, design: .default)
    static let chartAxisCompact = Font.system(size: 9.5, weight: .regular, design: .default)
    static let chartAxisCompactStrong = Font.system(size: 9.5, weight: .medium, design: .default)
    static let chartAxisMini = Font.system(size: 9, weight: .regular, design: .default)
    static let chartAxisStrip = Font.system(size: 9, weight: .medium, design: .default)

    static let sheetTitle = Font.system(size: 22, weight: .semibold, design: .default)
    static let sheetTitleSemibold = Font.system(size: 22, weight: .semibold, design: .default)
    static let panelHero = Font.system(size: 28, weight: .semibold, design: .default)
}

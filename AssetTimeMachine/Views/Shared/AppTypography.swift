import SwiftUI

enum AppTypography {
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
    static let pageHero = Font.system(size: platformSize(30), weight: .semibold, design: .default)
    static let pageHeroMinor = Font.system(size: platformSize(18), weight: .medium, design: .default)
    static let heroValue = Font.system(size: platformSize(42), weight: .semibold, design: .default)

    static let sectionTitle = Font.system(size: platformSize(20), weight: .semibold, design: .default)
    static let blockTitleBold = Font.system(size: platformSize(17), weight: .semibold, design: .default)
    static let blockTitle = Font.system(size: platformSize(17), weight: .medium, design: .default)
    static let inputValue = Font.system(size: platformSize(17), weight: .medium, design: .default)

    static let rowTitle = Font.system(size: platformSize(16), weight: .medium, design: .default)
    static let rowValue = Font.system(size: platformSize(16), weight: .semibold, design: .default)
    static let metricValue = Font.system(size: platformSize(16), weight: .semibold, design: .default)
    static let body = Font.system(size: platformSize(15), weight: .regular, design: .default)
    static let bodyStrong = Font.system(size: platformSize(15), weight: .medium, design: .default)

    static let meta = Font.system(size: platformSize(14), weight: .regular, design: .default)
    static let metaStrong = Font.system(size: platformSize(14), weight: .medium, design: .default)
    static let eyebrow = Font.system(size: platformSize(12), weight: .semibold, design: .default)
    static let caption = Font.system(size: platformSize(12), weight: .regular, design: .default)
    static let captionStrong = Font.system(size: platformSize(12), weight: .medium, design: .default)

    static let chip = Font.system(size: platformSize(12), weight: .medium, design: .default)
    static let chipIcon = Font.system(size: platformSize(11), weight: .semibold, design: .default)
    static let fieldLabel = Font.system(size: platformSize(12), weight: .medium, design: .default)

    static let microLabel = Font.system(size: platformSize(10), weight: .regular, design: .default)
    static let microValue = Font.system(size: platformSize(13), weight: .medium, design: .default)

    static let chartLegend = Font.system(size: platformSize(11), weight: .medium, design: .default)
    static let chartLegendMedium = Font.system(size: platformSize(11), weight: .regular, design: .default)
    static let chartCaption = Font.system(size: platformSize(10.5), weight: .regular, design: .default)
    static let chartCaptionStrong = Font.system(size: platformSize(10.5), weight: .medium, design: .default)
    static let chartAxis = Font.system(size: platformSize(10), weight: .regular, design: .default)
    static let chartAxisCompact = Font.system(size: platformSize(9.5), weight: .regular, design: .default)
    static let chartAxisCompactStrong = Font.system(size: platformSize(9.5), weight: .medium, design: .default)
    static let chartAxisMini = Font.system(size: platformSize(9), weight: .regular, design: .default)
    static let chartAxisStrip = Font.system(size: platformSize(9), weight: .medium, design: .default)

    static let sheetTitle = Font.system(size: platformSize(22), weight: .semibold, design: .default)
    static let sheetTitleSemibold = Font.system(size: platformSize(22), weight: .semibold, design: .default)
    static let panelHero = Font.system(size: platformSize(28), weight: .semibold, design: .default)
}

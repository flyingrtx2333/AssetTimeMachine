import AppKit
import Foundation
import SwiftUI

enum NativePalette {
    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    static let canvas = adaptive(
        light: NSColor(calibratedRed: 0.992, green: 0.984, blue: 0.969, alpha: 1),
        dark: NSColor(calibratedRed: 0.064, green: 0.071, blue: 0.083, alpha: 1)
    )
    static let sidebar = adaptive(
        light: NSColor(calibratedRed: 0.959, green: 0.946, blue: 0.922, alpha: 1),
        dark: NSColor(calibratedRed: 0.083, green: 0.092, blue: 0.107, alpha: 1)
    )
    static let surface = adaptive(
        light: NSColor(calibratedRed: 0.999, green: 0.995, blue: 0.985, alpha: 1),
        dark: NSColor(calibratedRed: 0.087, green: 0.098, blue: 0.116, alpha: 1)
    )
    static let line = adaptive(
        light: NSColor(calibratedRed: 0.884, green: 0.864, blue: 0.827, alpha: 1),
        dark: NSColor(calibratedRed: 0.164, green: 0.179, blue: 0.202, alpha: 1)
    )
    static let softGold = adaptive(
        light: NSColor(calibratedRed: 0.944, green: 0.907, blue: 0.832, alpha: 1),
        dark: NSColor(calibratedRed: 0.204, green: 0.174, blue: 0.138, alpha: 1)
    )
}

enum AssetTheme {
    static let gold = Color(red: 0.75, green: 0.58, blue: 0.36)
    static let positive = Color(red: 0.33, green: 0.68, blue: 0.47)
    static let negative = Color(red: 0.81, green: 0.35, blue: 0.35)
}

enum RemoteMarketClient {
    static let baseURL = URL(string: "https://api.flyingrtx.com")!
}

nonisolated enum BacktestAssetSymbol {
    static func normalized(_ symbol: String) -> String {
        switch symbol.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "gold": return "gold_cny"
        case "nasdaq_composite", "nasdaq": return "nasdaq"
        case "hang_seng", "hsi": return "hsi"
        case "nikkei225", "nikkei": return "nikkei"
        case "oil_wti", "oil_wti_cny", "wti": return "oil_wti_cny"
        case "dow_jones", "dowjones": return "dowjones"
        case "cn_10y", "china_10y", "china_10y_yield", "cgb_10y", "cn_10y_yield": return "cn_10y_yield"
        case "us10y", "us_10y", "treasury_10y", "us_treasury_10y", "us_10y_yield": return "us_10y_yield"
        case "us2y", "us_2y", "us_2y_yield": return "us_2y_yield"
        case "us3m", "us_3m", "us_3m_yield": return "us_3m_yield"
        case let value: return value
        }
    }
}

enum MacMemoryRelief {
    static func scheduleAfterHeavyOperation() {}
}

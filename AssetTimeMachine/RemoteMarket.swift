import Combine
import Foundation
import SwiftUI

struct PublicMarketPrice: Codable, Identifiable {
    let success: Bool
    let symbol: String
    let price: Double
    let currency: String
    let unit: String
    let source: String
    let fetchedAt: Date
    let recordDate: String?

    var id: String { symbol }

    enum CodingKeys: String, CodingKey {
        case success
        case symbol
        case price
        case currency
        case unit
        case source
        case fetchedAt = "fetched_at"
        case recordDate = "record_date"
    }
}

struct PublicMarketOverview: Codable {
    let success: Bool
    let markets: [PublicMarketPrice]
    let updateIntervalHours: Int?

    enum CodingKeys: String, CodingKey {
        case success
        case markets
        case updateIntervalHours = "update_interval_hours"
    }
}

struct MarketEndpointDoc: Identifiable {
    let title: String
    let path: String
    let description: String
    let symbol: String?

    var id: String { path }
}

enum RemoteMarketClient {
    static let baseURL = URL(string: "https://api.flyingrtx.com")!

    static let endpointDocs: [MarketEndpointDoc] = [
        .init(
            title: "黄金价格",
            path: "/api/v1/money/public/gold-price",
            description: "返回人民币计价的黄金单价，单位 gram。",
            symbol: "gold"
        ),
        .init(
            title: "BTC 价格",
            path: "/api/v1/money/public/btc-price",
            description: "返回 Binance 的 BTCUSDT 最新价格。",
            symbol: "btc"
        ),
        .init(
            title: "纳指参考价格",
            path: "/api/v1/money/public/nasdaq-price",
            description: "当前使用 QQQ 作为纳指代理锚点，返回美元价格。",
            symbol: "nasdaq"
        ),
        .init(
            title: "行情概览",
            path: "/api/v1/money/public/market-overview",
            description: "汇总返回 gold、btc、nasdaq 三个锚点。",
            symbol: nil
        ),
    ]

    static func fetchOverview() async throws -> PublicMarketOverview {
        let url = url(for: "/api/v1/money/public/market-overview")
        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response: response, data: data)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PublicMarketOverview.self, from: data)
    }

    static func url(for path: String) -> URL {
        URL(string: path, relativeTo: baseURL)!.absoluteURL
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "RemoteMarketClient",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: body.isEmpty ? "接口请求失败" : body]
            )
        }
    }
}

@MainActor
final class RemoteMarketStore: ObservableObject {
    @Published var overview: PublicMarketOverview?
    @Published var isLoading = false
    @Published var errorMessage: String?

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let overview = try await RemoteMarketClient.fetchOverview()
            self.overview = overview
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func market(for symbol: String) -> PublicMarketPrice? {
        overview?.markets.first(where: { $0.symbol == symbol })
    }
}

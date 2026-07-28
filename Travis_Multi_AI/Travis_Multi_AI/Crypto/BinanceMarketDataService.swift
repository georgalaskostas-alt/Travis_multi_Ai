import Foundation

enum BinanceAPIError: LocalizedError {
    case invalidURL
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Μη έγκυρο URL Binance"
        case .invalidResponse: return "Μη έγκυρη απάντηση από Binance"
        }
    }
}

/// Reads public Binance market data (no API key required). Used for both
/// paper and live trading decisions.
actor BinanceMarketDataService {
    private let baseURL = "https://api.binance.com"
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchTicker(symbol: String) async throws -> MarketTicker {
        guard var components = URLComponents(string: "\(baseURL)/api/v3/ticker/24hr") else {
            throw BinanceAPIError.invalidURL
        }
        components.queryItems = [URLQueryItem(name: "symbol", value: symbol)]
        guard let url = components.url else { throw BinanceAPIError.invalidURL }

        let (data, response) = try await session.data(from: url)
        try Self.validate(response)

        let raw = try JSONDecoder().decode(BinanceTickerResponse.self, from: data)
        return MarketTicker(
            symbol: raw.symbol,
            lastPrice: Double(raw.lastPrice) ?? 0,
            priceChangePercent: Double(raw.priceChangePercent) ?? 0,
            highPrice: Double(raw.highPrice) ?? 0,
            lowPrice: Double(raw.lowPrice) ?? 0,
            volume: Double(raw.volume) ?? 0,
            updatedAt: Date()
        )
    }

    func fetchCandles(symbol: String, interval: String = "5m", limit: Int = 100) async throws -> [Candle] {
        guard var components = URLComponents(string: "\(baseURL)/api/v3/klines") else {
            throw BinanceAPIError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "symbol", value: symbol),
            URLQueryItem(name: "interval", value: interval),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        guard let url = components.url else { throw BinanceAPIError.invalidURL }

        let (data, response) = try await session.data(from: url)
        try Self.validate(response)

        guard let raw = try JSONSerialization.jsonObject(with: data) as? [[Any]] else {
            throw BinanceAPIError.invalidResponse
        }

        return raw.compactMap { entry -> Candle? in
            guard entry.count >= 6,
                  let openTimeMs = (entry[0] as? NSNumber)?.doubleValue,
                  let openStr = entry[1] as? String,
                  let highStr = entry[2] as? String,
                  let lowStr = entry[3] as? String,
                  let closeStr = entry[4] as? String,
                  let volumeStr = entry[5] as? String
            else { return nil }

            return Candle(
                openTime: Date(timeIntervalSince1970: openTimeMs / 1000),
                open: Double(openStr) ?? 0,
                high: Double(highStr) ?? 0,
                low: Double(lowStr) ?? 0,
                close: Double(closeStr) ?? 0,
                volume: Double(volumeStr) ?? 0
            )
        }
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw BinanceAPIError.invalidResponse
        }
    }
}

private struct BinanceTickerResponse: Decodable {
    let symbol: String
    let lastPrice: String
    let priceChangePercent: String
    let highPrice: String
    let lowPrice: String
    let volume: String
}

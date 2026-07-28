import Foundation
import CryptoKit

struct BinanceCredentials {
    var apiKey: String
    var apiSecret: String
}

enum TradingServiceError: LocalizedError {
    case liveCredentialsMissing
    case invalidURL
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .liveCredentialsMissing: return "Λείπουν τα κλειδιά Binance API για live trading"
        case .invalidURL: return "Μη έγκυρο URL Binance"
        case .requestFailed(let message): return message
        }
    }
}

/// Places orders. Paper fills are simulated locally with no network call.
/// Live orders are signed and sent to Binance, but are only ever invoked
/// from an explicit, user-confirmed action — never from the automated
/// trading loop, which runs in paper mode only.
final class BinanceTradingService {
    private let baseURL = "https://api.binance.com"
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func paperFill(symbol: String, side: OrderSide, quantity: Double, atPrice price: Double, stopLossPrice: Double) -> CryptoPosition {
        CryptoPosition(
            symbol: symbol,
            side: side,
            entryPrice: price,
            quantity: quantity,
            stopLossPrice: stopLossPrice
        )
    }

    func placeLiveOrder(
        symbol: String,
        side: OrderSide,
        quantity: Double,
        credentials: BinanceCredentials
    ) async throws {
        guard !credentials.apiKey.isEmpty, !credentials.apiSecret.isEmpty else {
            throw TradingServiceError.liveCredentialsMissing
        }

        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let params: [(String, String)] = [
            ("symbol", symbol),
            ("side", side == .buy ? "BUY" : "SELL"),
            ("type", "MARKET"),
            ("quantity", String(quantity)),
            ("timestamp", String(timestamp))
        ]

        let query = params.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
        let signature = Self.sign(query: query, secret: credentials.apiSecret)
        let body = "\(query)&signature=\(signature)"

        guard let url = URL(string: "\(baseURL)/api/v3/order") else {
            throw TradingServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(credentials.apiKey, forHTTPHeaderField: "X-MBX-APIKEY")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let message = String(data: data, encoding: .utf8) ?? "Άγνωστο σφάλμα Binance"
            throw TradingServiceError.requestFailed(message)
        }
    }

    private static func sign(query: String, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let signature = HMAC<SHA256>.authenticationCode(for: Data(query.utf8), using: key)
        return signature.map { String(format: "%02x", $0) }.joined()
    }
}

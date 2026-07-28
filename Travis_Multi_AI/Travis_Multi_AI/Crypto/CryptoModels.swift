import Foundation

enum TradingMode: String, Codable, CaseIterable, Identifiable {
    case paper
    case live

    var id: String { rawValue }

    var title: String {
        switch self {
        case .paper: return "Χαρτί (Paper)"
        case .live: return "Live"
        }
    }
}

enum OrderSide: String, Codable, CaseIterable {
    case buy
    case sell
}

enum StrategySignal: String, Codable {
    case buy
    case sell
    case hold
}

enum TradeExitReason: String, Codable {
    case stopLoss = "Stop-Loss"
    case takeProfit = "Take-Profit"
    case strategySignal = "Στρατηγική"
    case circuitBreaker = "Circuit Breaker"
    case manual = "Χειροκίνητο"
}

struct CryptoSymbol: Identifiable, Codable, Hashable {
    var id: String { symbol }
    let symbol: String
    let baseAsset: String
    let quoteAsset: String

    static let watchlist: [CryptoSymbol] = [
        CryptoSymbol(symbol: "BTCUSDT", baseAsset: "BTC", quoteAsset: "USDT"),
        CryptoSymbol(symbol: "ETHUSDT", baseAsset: "ETH", quoteAsset: "USDT"),
        CryptoSymbol(symbol: "SOLUSDT", baseAsset: "SOL", quoteAsset: "USDT"),
        CryptoSymbol(symbol: "BNBUSDT", baseAsset: "BNB", quoteAsset: "USDT")
    ]
}

struct MarketTicker: Codable, Hashable {
    let symbol: String
    let lastPrice: Double
    let priceChangePercent: Double
    let highPrice: Double
    let lowPrice: Double
    let volume: Double
    let updatedAt: Date
}

struct Candle: Codable, Hashable, Identifiable {
    var id: Date { openTime }
    let openTime: Date
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    let volume: Double
}

struct CryptoPosition: Identifiable, Codable, Hashable {
    let id: UUID
    var symbol: String
    var side: OrderSide
    var entryPrice: Double
    var quantity: Double
    var stopLossPrice: Double
    var takeProfitPrice: Double?
    var openedAt: Date

    init(
        id: UUID = UUID(),
        symbol: String,
        side: OrderSide,
        entryPrice: Double,
        quantity: Double,
        stopLossPrice: Double,
        takeProfitPrice: Double? = nil,
        openedAt: Date = Date()
    ) {
        self.id = id
        self.symbol = symbol
        self.side = side
        self.entryPrice = entryPrice
        self.quantity = quantity
        self.stopLossPrice = stopLossPrice
        self.takeProfitPrice = takeProfitPrice
        self.openedAt = openedAt
    }

    func unrealizedPnL(at price: Double) -> Double {
        let diff = side == .buy ? (price - entryPrice) : (entryPrice - price)
        return diff * quantity
    }
}

struct CryptoTrade: Identifiable, Codable, Hashable {
    let id: UUID
    var symbol: String
    var side: OrderSide
    var entryPrice: Double
    var exitPrice: Double
    var quantity: Double
    var openedAt: Date
    var closedAt: Date
    var exitReason: TradeExitReason
    var strategyId: String

    init(
        id: UUID = UUID(),
        symbol: String,
        side: OrderSide,
        entryPrice: Double,
        exitPrice: Double,
        quantity: Double,
        openedAt: Date,
        closedAt: Date = Date(),
        exitReason: TradeExitReason,
        strategyId: String
    ) {
        self.id = id
        self.symbol = symbol
        self.side = side
        self.entryPrice = entryPrice
        self.exitPrice = exitPrice
        self.quantity = quantity
        self.openedAt = openedAt
        self.closedAt = closedAt
        self.exitReason = exitReason
        self.strategyId = strategyId
    }

    var realizedPnL: Double {
        let diff = side == .buy ? (exitPrice - entryPrice) : (entryPrice - exitPrice)
        return diff * quantity
    }

    var isWin: Bool { realizedPnL > 0 }
}

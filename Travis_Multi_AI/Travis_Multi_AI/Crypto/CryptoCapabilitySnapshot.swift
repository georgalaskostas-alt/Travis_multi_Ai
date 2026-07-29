import Foundation

/// A full, self-contained snapshot of the crypto capability's state, used
/// to sync it across devices as a single record. Applying a remote
/// snapshot is last-writer-wins by design — this module doesn't (yet)
/// coordinate which device is allowed to actively auto-trade, so running
/// automated trading on more than one device at once can still cause a
/// duplicate order. Only run active auto-trading on one device at a time.
struct CryptoCapabilitySnapshot: Codable {
    var tradingMode: TradingMode
    var isAutoTradingEnabled: Bool
    var selectedSymbol: String
    var openPositions: [CryptoPosition]
    var tradeHistory: [CryptoTrade]
    var paperCashBalance: Double
    var paperStartingBalance: Double
    var maxRiskPerTradePercent: Double
    var maxDailyLossPercent: Double
    var mandatoryStopLossPercent: Double
    var maxOpenPositions: Int
}

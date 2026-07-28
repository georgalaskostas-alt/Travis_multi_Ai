import Foundation
import Observation

/// Owns the crypto trading module's state and orchestrates market data
/// refresh, strategy evaluation, risk checks, and paper order execution.
/// Trading starts in paper mode; automated trading only ever runs in
/// paper mode, and live orders always require an explicit manual action.
@Observable
final class CryptoTradingState {
    var tradingMode: TradingMode = .paper
    var isAutoTradingEnabled: Bool = false
    var selectedSymbol: String = "BTCUSDT"
    var watchlist: [CryptoSymbol] = CryptoSymbol.watchlist

    var tickers: [String: MarketTicker] = [:]
    var candles: [String: [Candle]] = [:]
    var openPositions: [CryptoPosition] = []
    var tradeHistory: [CryptoTrade] = []

    var paperStartingBalance: Double = 10_000
    var paperCashBalance: Double = 10_000

    var lastError: String?
    var lastStrategyDecision: StrategyDecision?
    var isRefreshing: Bool = false

    let riskManager: CryptoRiskManager
    let strategyEngine = AdaptiveStrategyEngine()
    private let marketDataService = BinanceMarketDataService()
    private let tradingService = BinanceTradingService()

    private var refreshTask: Task<Void, Never>?

    init() {
        self.riskManager = CryptoRiskManager(startingEquity: paperStartingBalance)
    }

    var equity: Double {
        let openPnL = openPositions.reduce(0) { total, position in
            total + position.unrealizedPnL(at: tickers[position.symbol]?.lastPrice ?? position.entryPrice)
        }
        return paperCashBalance + openPnL
    }

    var isCircuitBreakerTripped: Bool { riskManager.isCircuitBreakerTripped }

    func startAutoRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refresh()
                try? await Task.sleep(nanoseconds: 15 * 1_000_000_000)
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    @MainActor
    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        riskManager.rolloverDayIfNeeded(currentEquity: equity)

        for entry in watchlist {
            do {
                let ticker = try await marketDataService.fetchTicker(symbol: entry.symbol)
                tickers[entry.symbol] = ticker

                let recentCandles = try await marketDataService.fetchCandles(symbol: entry.symbol, interval: "5m", limit: 60)
                candles[entry.symbol] = recentCandles
            } catch {
                lastError = "Σφάλμα Binance για \(entry.symbol): \(error.localizedDescription)"
            }
        }

        checkOpenPositionsForExit()

        guard let selectedCandles = candles[selectedSymbol] else { return }
        let decision = strategyEngine.evaluate(candles: selectedCandles)
        lastStrategyDecision = decision

        guard isAutoTradingEnabled, tradingMode == .paper else { return }
        guard riskManager.canOpenNewPosition(openPositionsCount: openPositions.count) else { return }
        guard !openPositions.contains(where: { $0.symbol == selectedSymbol }) else { return }
        guard let price = tickers[selectedSymbol]?.lastPrice, price > 0 else { return }

        switch decision.signal {
        case .buy:
            openPaperPosition(symbol: selectedSymbol, side: .buy, price: price)
        case .sell:
            openPaperPosition(symbol: selectedSymbol, side: .sell, price: price)
        case .hold:
            break
        }
    }

    func manualOpenPosition(side: OrderSide) {
        guard tradingMode == .paper else { return }
        guard riskManager.canOpenNewPosition(openPositionsCount: openPositions.count) else { return }
        guard !openPositions.contains(where: { $0.symbol == selectedSymbol }) else { return }
        guard let price = tickers[selectedSymbol]?.lastPrice, price > 0 else { return }
        openPaperPosition(symbol: selectedSymbol, side: side, price: price)
    }

    func manualClosePosition(_ position: CryptoPosition) {
        guard let index = openPositions.firstIndex(where: { $0.id == position.id }) else { return }
        let price = tickers[position.symbol]?.lastPrice ?? position.entryPrice
        openPositions.remove(at: index)
        settle(position, exitPrice: price, reason: .manual)
    }

    private func openPaperPosition(symbol: String, side: OrderSide, price: Double) {
        // Every position gets a mandatory stop-loss before it is ever opened.
        let stopLoss = riskManager.mandatoryStopLoss(entryPrice: price, side: side)
        let quantity = riskManager.positionSize(equity: equity, entryPrice: price, stopLossPrice: stopLoss)
        guard quantity > 0 else { return }

        let position = tradingService.paperFill(
            symbol: symbol,
            side: side,
            quantity: quantity,
            atPrice: price,
            stopLossPrice: stopLoss
        )
        openPositions.append(position)
    }

    private func checkOpenPositionsForExit() {
        guard !openPositions.isEmpty else { return }

        var remaining: [CryptoPosition] = []
        for position in openPositions {
            guard let price = tickers[position.symbol]?.lastPrice else {
                remaining.append(position)
                continue
            }

            let stopHit = position.side == .buy ? price <= position.stopLossPrice : price >= position.stopLossPrice
            if stopHit {
                settle(position, exitPrice: position.stopLossPrice, reason: .stopLoss)
            } else {
                remaining.append(position)
            }
        }
        openPositions = remaining

        if riskManager.isCircuitBreakerTripped, !openPositions.isEmpty {
            let toClose = openPositions
            openPositions = []
            for position in toClose {
                let price = tickers[position.symbol]?.lastPrice ?? position.entryPrice
                settle(position, exitPrice: price, reason: .circuitBreaker)
            }
        }
    }

    private func settle(_ position: CryptoPosition, exitPrice: Double, reason: TradeExitReason) {
        let trade = CryptoTrade(
            symbol: position.symbol,
            side: position.side,
            entryPrice: position.entryPrice,
            exitPrice: exitPrice,
            quantity: position.quantity,
            openedAt: position.openedAt,
            exitReason: reason,
            strategyId: "adaptive-ma-cross"
        )

        paperCashBalance += trade.realizedPnL
        tradeHistory.insert(trade, at: 0)
        riskManager.recordRealizedPnL(trade.realizedPnL, equity: equity)
        strategyEngine.recordOutcome(isWin: trade.isWin)
    }
}

import Foundation
import Observation

/// Enforces position sizing, a mandatory stop-loss on every trade, and a
/// daily-loss circuit breaker that halts trading once the day's realized
/// losses cross a configurable threshold.
@Observable
final class CryptoRiskManager {
    var maxRiskPerTradePercent: Double = 1.0
    var maxDailyLossPercent: Double = 3.0
    var mandatoryStopLossPercent: Double = 2.0
    var maxOpenPositions: Int = 3

    private(set) var dailyStartEquity: Double
    private(set) var dailyRealizedPnL: Double = 0
    private(set) var isCircuitBreakerTripped: Bool = false
    private(set) var circuitBreakerTrippedAt: Date?
    private var currentTradingDay: Date

    init(startingEquity: Double) {
        self.dailyStartEquity = startingEquity
        self.currentTradingDay = Calendar.current.startOfDay(for: Date())
    }

    func rolloverDayIfNeeded(currentEquity: Double) {
        let today = Calendar.current.startOfDay(for: Date())
        guard today != currentTradingDay else { return }
        currentTradingDay = today
        dailyStartEquity = currentEquity
        dailyRealizedPnL = 0
        isCircuitBreakerTripped = false
        circuitBreakerTrippedAt = nil
    }

    func canOpenNewPosition(openPositionsCount: Int) -> Bool {
        guard !isCircuitBreakerTripped else { return false }
        return openPositionsCount < maxOpenPositions
    }

    /// Sizes a position so that hitting the stop-loss loses no more than
    /// `maxRiskPerTradePercent` of current equity.
    func positionSize(equity: Double, entryPrice: Double, stopLossPrice: Double) -> Double {
        guard entryPrice > 0, stopLossPrice > 0, entryPrice != stopLossPrice else { return 0 }
        let riskAmount = equity * (maxRiskPerTradePercent / 100)
        let riskPerUnit = abs(entryPrice - stopLossPrice)
        guard riskPerUnit > 0 else { return 0 }
        return riskAmount / riskPerUnit
    }

    /// Every position TRAVIS opens gets this stop-loss — there is no
    /// code path that opens a position without one.
    func mandatoryStopLoss(entryPrice: Double, side: OrderSide) -> Double {
        let offset = entryPrice * (mandatoryStopLossPercent / 100)
        return side == .buy ? entryPrice - offset : entryPrice + offset
    }

    func recordRealizedPnL(_ pnl: Double, equity: Double) {
        rolloverDayIfNeeded(currentEquity: equity)
        dailyRealizedPnL += pnl
        evaluateCircuitBreaker()
    }

    private func evaluateCircuitBreaker() {
        guard dailyStartEquity > 0 else { return }
        let lossPercent = (-dailyRealizedPnL / dailyStartEquity) * 100
        if lossPercent >= maxDailyLossPercent, !isCircuitBreakerTripped {
            isCircuitBreakerTripped = true
            circuitBreakerTrippedAt = Date()
        }
    }

    /// Manual override, e.g. for testing. Automated trading never calls this.
    func resetCircuitBreaker() {
        isCircuitBreakerTripped = false
        circuitBreakerTrippedAt = nil
    }

    var dailyLossPercentUsed: Double {
        guard dailyStartEquity > 0 else { return 0 }
        return max(0, (-dailyRealizedPnL / dailyStartEquity) * 100)
    }
}

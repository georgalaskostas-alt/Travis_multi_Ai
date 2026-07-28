import Foundation
import Observation

struct StrategyDecision {
    let signal: StrategySignal
    let confidence: Double
    let reason: String
}

/// A moving-average-crossover / RSI strategy that adapts its own parameters
/// from feedback: after every `adaptationWindow` closed trades it looks at
/// the recent win rate and widens/tightens itself accordingly.
@Observable
final class AdaptiveStrategyEngine {
    private(set) var fastPeriod: Int = 9
    private(set) var slowPeriod: Int = 21
    private(set) var confidenceThreshold: Double = 0.55

    private(set) var recentOutcomes: [Bool] = []
    private let maxHistory = 30
    private let adaptationWindow = 8

    var winRate: Double {
        guard !recentOutcomes.isEmpty else { return 0 }
        let wins = recentOutcomes.filter { $0 }.count
        return Double(wins) / Double(recentOutcomes.count)
    }

    func evaluate(candles: [Candle]) -> StrategyDecision {
        guard candles.count >= slowPeriod + 1 else {
            return StrategyDecision(signal: .hold, confidence: 0, reason: "Ανεπαρκή δεδομένα")
        }

        let closes = candles.map { $0.close }
        let fastMA = Self.movingAverage(closes, period: fastPeriod)
        let slowMA = Self.movingAverage(closes, period: slowPeriod)
        let prevFastMA = Self.movingAverage(Array(closes.dropLast()), period: fastPeriod)
        let prevSlowMA = Self.movingAverage(Array(closes.dropLast()), period: slowPeriod)

        let rsi = Self.rsi(closes, period: 14)
        let momentum = abs(fastMA - slowMA) / max(slowMA, 0.0001)
        let confidence = min(0.95, 0.5 + momentum * 10)

        let bullishCross = prevFastMA <= prevSlowMA && fastMA > slowMA
        let bearishCross = prevFastMA >= prevSlowMA && fastMA < slowMA

        if bullishCross, rsi < 70, confidence >= confidenceThreshold {
            return StrategyDecision(
                signal: .buy,
                confidence: confidence,
                reason: "MA(\(fastPeriod)) διέσχισε πάνω από MA(\(slowPeriod)), RSI \(Int(rsi))"
            )
        }

        if bearishCross, rsi > 30, confidence >= confidenceThreshold {
            return StrategyDecision(
                signal: .sell,
                confidence: confidence,
                reason: "MA(\(fastPeriod)) διέσχισε κάτω από MA(\(slowPeriod)), RSI \(Int(rsi))"
            )
        }

        return StrategyDecision(signal: .hold, confidence: confidence, reason: "Καμία σαφής τάση")
    }

    /// Feeds a closed trade's outcome back into the engine so it can adapt.
    func recordOutcome(isWin: Bool) {
        recentOutcomes.append(isWin)
        if recentOutcomes.count > maxHistory {
            recentOutcomes.removeFirst()
        }
        guard recentOutcomes.count >= adaptationWindow, recentOutcomes.count % adaptationWindow == 0 else { return }

        let recentWindow = recentOutcomes.suffix(adaptationWindow)
        let windowWinRate = Double(recentWindow.filter { $0 }.count) / Double(adaptationWindow)

        if windowWinRate < 0.4 {
            // Losing streak: widen the moving averages to filter out noise and demand more confidence.
            slowPeriod = min(50, slowPeriod + 2)
            fastPeriod = min(slowPeriod - 2, fastPeriod + 1)
            confidenceThreshold = min(0.8, confidenceThreshold + 0.03)
        } else if windowWinRate > 0.65 {
            // Winning streak: tighten periods slightly to react faster, within safe bounds.
            slowPeriod = max(fastPeriod + 4, slowPeriod - 1)
            fastPeriod = max(5, fastPeriod)
            confidenceThreshold = max(0.5, confidenceThreshold - 0.01)
        }
    }

    private static func movingAverage(_ values: [Double], period: Int) -> Double {
        guard values.count >= period, period > 0 else { return values.last ?? 0 }
        let slice = values.suffix(period)
        return slice.reduce(0, +) / Double(period)
    }

    private static func rsi(_ values: [Double], period: Int) -> Double {
        guard values.count > period else { return 50 }
        let recent = values.suffix(period + 1)
        var gains = 0.0
        var losses = 0.0
        var previous: Double?
        for value in recent {
            if let previous {
                let change = value - previous
                if change >= 0 { gains += change } else { losses -= change }
            }
            previous = value
        }
        guard losses > 0 else { return 100 }
        let rs = gains / losses
        return 100 - (100 / (1 + rs))
    }
}

import Foundation
import Observation

/// What a pending `ProposedAction` from this capability actually does once
/// approved. Kept locally (keyed by `ProposedAction.id`) instead of on the
/// shared model, since only this capability needs to interpret its own
/// proposals — the shared kernel type stays generic and human-readable.
private enum CryptoProposalKind {
    case openPosition(symbol: String, side: OrderSide)
    case closeAllPositions
    case setAutoTrading(Bool)
    case setTradingMode(TradingMode)
}

/// Owns the crypto trading module's state and orchestrates market data
/// refresh, strategy evaluation, risk checks, and order execution.
///
/// Conforms to `AgentCapability`: it never acts on its own initiative.
/// Every strategy-driven signal and every chat-initiated command becomes a
/// `ProposedAction` that goes through the shared `ApprovalGateService`.
/// The one exception is paper-mode auto-trading, which is zero real risk
/// and may execute immediately — but even then the decision is logged to
/// the gate's history as if it had been proposed, so the audit trail is
/// the same regardless of mode. Testnet/live mode never executes anything
/// without an explicit approval.
@MainActor
@Observable
final class CryptoTradingState: AgentCapability {
    let id: String = "crypto-trading"
    var name: String { "Crypto Trading" }
    var capabilityDescription: String {
        "Trading κρυπτονομισμάτων μέσω Binance: παρακολουθεί τιμές, προτείνει buy/sell συναλλαγές μέσω μιας προσαρμοστικής στρατηγικής, και διαχειρίζεται το ρίσκο (mandatory stop-loss, daily-loss circuit breaker)."
    }
    var status: AgentCapabilityStatus {
        if riskManager.isCircuitBreakerTripped { return .paused }
        return isAutoTradingEnabled ? .running : .idle
    }

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

    /// Binance API credentials for live order placement. Nil by default —
    /// there is intentionally no UI/Keychain storage wired up yet, so any
    /// approved live-mode action safely fails with a clear error instead
    /// of silently doing nothing or trading with the wrong credentials.
    var liveCredentials: BinanceCredentials?

    var lastError: String?
    var lastStrategyDecision: StrategyDecision?
    var isRefreshing: Bool = false

    /// Fired after position/trade/mode state changes, so `SyncService` can
    /// push the update without this type needing to know sync exists.
    var onStateChanged: (() -> Void)?

    let riskManager: CryptoRiskManager
    let strategyEngine = AdaptiveStrategyEngine()
    private let marketDataService = BinanceMarketDataService()
    private let tradingService = BinanceTradingService()
    private let approvalGate: ApprovalGateService

    /// Proposals this capability currently has pending in the approval
    /// gate, so `resolve(_:)` knows what to actually do once a human
    /// decides. Entries are removed as soon as they're resolved.
    private var pendingProposals: [UUID: CryptoProposalKind] = [:]

    private var refreshTask: Task<Void, Never>?

    init(approvalGate: ApprovalGateService) {
        self.approvalGate = approvalGate
        self.riskManager = CryptoRiskManager(startingEquity: paperStartingBalance)
    }

    var equity: Double {
        let openPnL = openPositions.reduce(0) { total, position in
            total + position.unrealizedPnL(at: tickers[position.symbol]?.lastPrice ?? position.entryPrice)
        }
        return paperCashBalance + openPnL
    }

    var isCircuitBreakerTripped: Bool { riskManager.isCircuitBreakerTripped }

    /// Single read/write surface `SyncService` uses to snapshot and restore
    /// this capability's state, without reaching into its internals.
    var syncSnapshot: CryptoCapabilitySnapshot {
        get {
            CryptoCapabilitySnapshot(
                tradingMode: tradingMode,
                isAutoTradingEnabled: isAutoTradingEnabled,
                selectedSymbol: selectedSymbol,
                openPositions: openPositions,
                tradeHistory: tradeHistory,
                paperCashBalance: paperCashBalance,
                paperStartingBalance: paperStartingBalance,
                maxRiskPerTradePercent: riskManager.maxRiskPerTradePercent,
                maxDailyLossPercent: riskManager.maxDailyLossPercent,
                mandatoryStopLossPercent: riskManager.mandatoryStopLossPercent,
                maxOpenPositions: riskManager.maxOpenPositions
            )
        }
        set {
            tradingMode = newValue.tradingMode
            isAutoTradingEnabled = newValue.isAutoTradingEnabled
            selectedSymbol = newValue.selectedSymbol
            openPositions = newValue.openPositions
            tradeHistory = newValue.tradeHistory
            paperCashBalance = newValue.paperCashBalance
            paperStartingBalance = newValue.paperStartingBalance
            riskManager.maxRiskPerTradePercent = newValue.maxRiskPerTradePercent
            riskManager.maxDailyLossPercent = newValue.maxDailyLossPercent
            riskManager.mandatoryStopLossPercent = newValue.mandatoryStopLossPercent
            riskManager.maxOpenPositions = newValue.maxOpenPositions
        }
    }

    /// Applies a snapshot received from another device via sync.
    /// Last-writer-wins — see the caveat on `CryptoCapabilitySnapshot`.
    /// Never fires `onStateChanged`, so this doesn't echo straight back.
    func applyRemoteSnapshot(_ snapshot: CryptoCapabilitySnapshot) {
        syncSnapshot = snapshot
    }

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

        guard isAutoTradingEnabled, decision.signal != .hold else { return }
        guard riskManager.canOpenNewPosition(openPositionsCount: openPositions.count) else { return }
        guard !openPositions.contains(where: { $0.symbol == selectedSymbol }) else { return }
        guard let price = tickers[selectedSymbol]?.lastPrice, price > 0 else { return }

        let side: OrderSide = decision.signal == .buy ? .buy : .sell
        actOnStrategySignal(symbol: selectedSymbol, side: side, price: price, reason: decision.reason)
    }

    // MARK: - AgentCapability

    /// Interprets a natural-language chat command. Matching today is a
    /// pragmatic keyword heuristic (Greek + English) — a placeholder for
    /// real intent parsing (e.g. via `AIService`) later. Every branch
    /// returns a *pending* proposal; chat-initiated actions always wait
    /// for explicit approval, regardless of trading mode.
    func handle(command: String) async -> ProposedAction? {
        let normalized = command.lowercased()

        if containsAny(normalized, ["σταμάτα", "σταματα", "παύση", "παυση", "pause"]) {
            return proposeAutoTradingChange(enable: false, reason: "Ζητήθηκε παύση του αυτόματου trading μέσω chat.")
        }
        if containsAny(normalized, ["ξεκίνα", "ξεκινα", "ενεργοποίησε", "ενεργοποιησε", "resume auto", "start auto"]) {
            return proposeAutoTradingChange(enable: true, reason: "Ζητήθηκε ενεργοποίηση του αυτόματου trading μέσω chat.")
        }
        if containsAny(normalized, ["live", "testnet", "πραγματικ"]) {
            return proposeModeChange(to: .live, reason: "Ζητήθηκε αλλαγή σε live trading μέσω chat.")
        }
        if containsAny(normalized, ["paper", "χαρτ", "προσομοίωση", "προσομοιωση"]) {
            return proposeModeChange(to: .paper, reason: "Ζητήθηκε επιστροφή σε paper trading μέσω chat.")
        }
        if containsAny(normalized, ["κλείσε", "κλεισε", "close all", "close position"]) {
            return proposeCloseAll(reason: "Ζητήθηκε κλείσιμο όλων των ανοιχτών θέσεων μέσω chat.")
        }
        if containsAny(normalized, ["αγόρασε", "αγορασε", "buy", "long"]) {
            return proposeManualEntry(side: .buy, reason: "Ζητήθηκε χειροκίνητο buy μέσω chat.")
        }
        if containsAny(normalized, ["πούλησε", "πουλησε", "sell", "short"]) {
            return proposeManualEntry(side: .sell, reason: "Ζητήθηκε χειροκίνητο sell μέσω chat.")
        }

        return nil
    }

    /// Called by `ApprovalGateService` once a proposal from this capability
    /// is approved or rejected. Rejections are simply dropped — the
    /// gate's history already keeps the record.
    func resolve(_ action: ProposedAction) {
        guard let kind = pendingProposals.removeValue(forKey: action.id) else { return }
        guard action.status == .approved else { return }

        switch kind {
        case .openPosition(let symbol, let side):
            executeApprovedEntry(symbol: symbol, side: side)
        case .closeAllPositions:
            for position in openPositions {
                manualClosePosition(position)
            }
        case .setAutoTrading(let enabled):
            isAutoTradingEnabled = enabled
        case .setTradingMode(let mode):
            tradingMode = mode
        }
        onStateChanged?()
    }

    // MARK: - Manual controls (direct human action inside the Crypto tab)

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

    // MARK: - Approval-gated execution

    /// Routes an autonomous strategy signal through the approval pipeline.
    /// Paper mode executes immediately (zero real risk) but still logs
    /// what was proposed; live/testnet mode always waits for approval.
    private func actOnStrategySignal(symbol: String, side: OrderSide, price: Double, reason: String) {
        let action = ProposedAction(
            capabilityId: id,
            summary: "\(side == .buy ? "Άνοιγμα Long" : "Άνοιγμα Short") σε \(symbol) στα \(price) (αυτόματο σήμα στρατηγικής)",
            reasoning: reason,
            expectedImpact: "Νέα \(side == .buy ? "Long" : "Short") θέση σε \(symbol) με υποχρεωτικό stop-loss \(riskManager.mandatoryStopLossPercent)%."
        )

        switch tradingMode {
        case .paper:
            openPaperPosition(symbol: symbol, side: side, price: price)
            approvalGate.recordAutoApproved(action)
        case .live:
            pendingProposals[action.id] = .openPosition(symbol: symbol, side: side)
            approvalGate.submit(action)
        }
    }

    private func executeApprovedEntry(symbol: String, side: OrderSide) {
        guard riskManager.canOpenNewPosition(openPositionsCount: openPositions.count) else { return }
        guard !openPositions.contains(where: { $0.symbol == symbol }) else { return }
        guard let price = tickers[symbol]?.lastPrice, price > 0 else { return }

        switch tradingMode {
        case .paper:
            openPaperPosition(symbol: symbol, side: side, price: price)
        case .live:
            executeLiveEntry(symbol: symbol, side: side, price: price)
        }
    }

    private func executeLiveEntry(symbol: String, side: OrderSide, price: Double) {
        let stopLoss = riskManager.mandatoryStopLoss(entryPrice: price, side: side)
        let quantity = riskManager.positionSize(equity: equity, entryPrice: price, stopLossPrice: stopLoss)
        guard quantity > 0 else { return }

        guard let credentials = liveCredentials else {
            lastError = "Δεν ήταν δυνατή η live εκτέλεση: λείπουν τα κλειδιά Binance API."
            return
        }

        Task {
            do {
                try await tradingService.placeLiveOrder(symbol: symbol, side: side, quantity: quantity, credentials: credentials)
                // The order was accepted; record the position locally at the
                // approved price. Reconciling the exact fill from Binance's
                // response is future work once live trading is fully wired up.
                let position = tradingService.paperFill(symbol: symbol, side: side, quantity: quantity, atPrice: price, stopLossPrice: stopLoss)
                openPositions.append(position)
                onStateChanged?()
            } catch {
                lastError = "Η live εντολή απέτυχε: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Chat proposal builders

    private func proposeAutoTradingChange(enable: Bool, reason: String) -> ProposedAction {
        let action = ProposedAction(
            capabilityId: id,
            summary: enable ? "Ενεργοποίηση αυτόματου trading" : "Παύση αυτόματου trading",
            reasoning: reason,
            expectedImpact: enable
                ? "Η στρατηγική θα αρχίσει να προτείνει νέες θέσεις σύμφωνα με τους κανόνες ρίσκου."
                : "Καμία νέα αυτόματη πρόταση θέσης μέχρι νέα ενεργοποίηση."
        )
        pendingProposals[action.id] = .setAutoTrading(enable)
        return action
    }

    private func proposeModeChange(to mode: TradingMode, reason: String) -> ProposedAction {
        let action = ProposedAction(
            capabilityId: id,
            summary: "Αλλαγή σε \(mode.title)",
            reasoning: reason,
            expectedImpact: mode == .live
                ? "Οι επόμενες εγκεκριμένες συναλλαγές θα στέλνονται στο πραγματικό Binance API."
                : "Επιστροφή σε προσομοίωση χωρίς πραγματικό ρίσκο."
        )
        pendingProposals[action.id] = .setTradingMode(mode)
        return action
    }

    private func proposeManualEntry(side: OrderSide, reason: String) -> ProposedAction? {
        guard let price = tickers[selectedSymbol]?.lastPrice, price > 0 else { return nil }
        let action = ProposedAction(
            capabilityId: id,
            summary: "\(side == .buy ? "Buy" : "Sell") σε \(selectedSymbol) στα \(price)",
            reasoning: reason,
            expectedImpact: "Νέα \(side == .buy ? "Long" : "Short") θέση σε \(selectedSymbol) με υποχρεωτικό stop-loss \(riskManager.mandatoryStopLossPercent)%."
        )
        pendingProposals[action.id] = .openPosition(symbol: selectedSymbol, side: side)
        return action
    }

    private func proposeCloseAll(reason: String) -> ProposedAction? {
        guard !openPositions.isEmpty else { return nil }
        let action = ProposedAction(
            capabilityId: id,
            summary: "Κλείσιμο \(openPositions.count) ανοιχτών θέσεων",
            reasoning: reason,
            expectedImpact: "Όλες οι ανοιχτές θέσεις θα κλείσουν στην τρέχουσα τιμή αγοράς."
        )
        pendingProposals[action.id] = .closeAllPositions
        return action
    }

    private func containsAny(_ text: String, _ keywords: [String]) -> Bool {
        keywords.contains { text.contains($0) }
    }

    // MARK: - Execution primitives

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
        onStateChanged?()
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
        onStateChanged?()
    }
}

import SwiftUI

struct CryptoTradingView: View {
    @Bindable var appState: TRAVISAppState

    private var state: CryptoTradingState { appState.cryptoTradingState }
    private var risk: CryptoRiskManager { state.riskManager }

    var body: some View {
        Form {
            modeSection
            if risk.isCircuitBreakerTripped {
                circuitBreakerBanner
            }
            watchlistSection
            selectedSymbolSection
            openPositionsSection
            riskSettingsSection
            strategySection
            tradeHistorySection
        }
        .formStyle(.grouped)
        .navigationTitle("Crypto Trading")
        .task {
            state.startAutoRefresh()
        }
        .onDisappear {
            state.stopAutoRefresh()
        }
    }

    private var modeSection: some View {
        Section("Λειτουργία") {
            Picker("Mode", selection: $appState.cryptoTradingState.tradingMode) {
                ForEach(TradingMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if state.tradingMode == .live {
                Label(
                    "Το live trading απαιτεί χειροκίνητη επιβεβαίωση κάθε εντολής και τα δικά σου κλειδιά Binance API. Το auto-trading λειτουργεί μόνο σε Paper mode.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            Toggle("Αυτόματο Trading (Paper)", isOn: $appState.cryptoTradingState.isAutoTradingEnabled)
                .disabled(state.tradingMode == .live)

            HStack {
                Text("Equity")
                Spacer()
                Text(state.equity, format: .currency(code: "USD"))
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Ημερήσιο όριο ζημιάς")
                Spacer()
                Text("\(risk.dailyLossPercentUsed, specifier: "%.2f")% / \(risk.maxDailyLossPercent, specifier: "%.1f")%")
                    .foregroundStyle(risk.dailyLossPercentUsed >= risk.maxDailyLossPercent ? .red : .secondary)
            }
        }
    }

    private var circuitBreakerBanner: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Circuit Breaker ενεργό", systemImage: "octagon.fill")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text("Το ημερήσιο όριο ζημιάς ξεπεράστηκε. Όλες οι θέσεις έκλεισαν και το auto-trading σταμάτησε μέχρι την επόμενη ημέρα.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Χειροκίνητη επαναφορά (προσοχή)", role: .destructive) {
                    risk.resetCircuitBreaker()
                }
                .font(.caption)
            }
        }
    }

    private var watchlistSection: some View {
        Section("Watchlist") {
            ForEach(state.watchlist) { symbol in
                Button {
                    state.selectedSymbol = symbol.symbol
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(symbol.symbol).font(.headline)
                            if let ticker = state.tickers[symbol.symbol] {
                                Text("Vol \(ticker.volume, specifier: "%.0f")")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if let ticker = state.tickers[symbol.symbol] {
                            VStack(alignment: .trailing) {
                                Text(ticker.lastPrice, format: .currency(code: "USD"))
                                Text("\(ticker.priceChangePercent >= 0 ? "+" : "")\(ticker.priceChangePercent, specifier: "%.2f")%")
                                    .font(.caption)
                                    .foregroundStyle(ticker.priceChangePercent >= 0 ? .green : .red)
                            }
                        } else {
                            ProgressView()
                        }
                    }
                }
                .buttonStyle(.plain)
                .listRowBackground(symbol.symbol == state.selectedSymbol ? Color.accentColor.opacity(0.15) : nil)
            }
        }
    }

    private var selectedSymbolSection: some View {
        Section("Σήμα Στρατηγικής — \(state.selectedSymbol)") {
            if let decision = state.lastStrategyDecision {
                HStack {
                    Text(signalTitle(decision.signal))
                        .font(.headline)
                        .foregroundStyle(signalColor(decision.signal))
                    Spacer()
                    Text("Εμπιστοσύνη \(Int(decision.confidence * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(decision.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Αναμονή δεδομένων αγοράς...")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Χειροκίνητο Buy") {
                    state.manualOpenPosition(side: .buy)
                }
                .disabled(risk.isCircuitBreakerTripped || state.tradingMode == .live)

                Button("Χειροκίνητο Sell") {
                    state.manualOpenPosition(side: .sell)
                }
                .disabled(risk.isCircuitBreakerTripped || state.tradingMode == .live)
            }
        }
    }

    private var openPositionsSection: some View {
        Section("Ανοιχτές Θέσεις") {
            if state.openPositions.isEmpty {
                Text("Καμία ανοιχτή θέση")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(state.openPositions) { position in
                    let currentPrice = state.tickers[position.symbol]?.lastPrice ?? position.entryPrice
                    let pnl = position.unrealizedPnL(at: currentPrice)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("\(position.symbol) • \(position.side == .buy ? "Long" : "Short")")
                                .font(.headline)
                            Spacer()
                            Button("Κλείσιμο") {
                                state.manualClosePosition(position)
                            }
                            .font(.caption)
                        }
                        Text("Είσοδος \(position.entryPrice, specifier: "%.2f") • Stop-Loss \(position.stopLossPrice, specifier: "%.2f")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Μη πραγματοποιηθέν P&L: \(pnl, specifier: "%.2f") USD")
                            .font(.caption)
                            .foregroundStyle(pnl >= 0 ? .green : .red)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var riskSettingsSection: some View {
        Section("Διαχείριση Ρίσκου") {
            Stepper(
                "Ρίσκο ανά συναλλαγή: \(risk.maxRiskPerTradePercent, specifier: "%.2f")%",
                value: $appState.cryptoTradingState.riskManager.maxRiskPerTradePercent,
                in: 0.25...5,
                step: 0.25
            )
            Stepper(
                "Υποχρεωτικό Stop-Loss: \(risk.mandatoryStopLossPercent, specifier: "%.1f")%",
                value: $appState.cryptoTradingState.riskManager.mandatoryStopLossPercent,
                in: 0.5...10,
                step: 0.5
            )
            Stepper(
                "Ημερήσιο όριο ζημιάς: \(risk.maxDailyLossPercent, specifier: "%.1f")%",
                value: $appState.cryptoTradingState.riskManager.maxDailyLossPercent,
                in: 1...15,
                step: 0.5
            )
            Stepper(
                "Μέγιστες ταυτόχρονες θέσεις: \(risk.maxOpenPositions)",
                value: $appState.cryptoTradingState.riskManager.maxOpenPositions,
                in: 1...10
            )
        }
    }

    private var strategySection: some View {
        Section("Adaptive Learning Engine") {
            HStack {
                Text("Win rate (τελευταίες \(state.strategyEngine.recentOutcomes.count) συναλλαγές)")
                Spacer()
                Text("\(Int(state.strategyEngine.winRate * 100))%")
            }
            HStack {
                Text("MA γρήγορο / αργό")
                Spacer()
                Text("\(state.strategyEngine.fastPeriod) / \(state.strategyEngine.slowPeriod)")
            }
            HStack {
                Text("Όριο εμπιστοσύνης")
                Spacer()
                Text("\(Int(state.strategyEngine.confidenceThreshold * 100))%")
            }
            Text("Η στρατηγική προσαρμόζει αυτόματα τις παραμέτρους της κάθε 8 συναλλαγές ανάλογα με το πρόσφατο win rate.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var tradeHistorySection: some View {
        Section("Ιστορικό Συναλλαγών") {
            if state.tradeHistory.isEmpty {
                Text("Δεν έχουν κλείσει συναλλαγές ακόμα")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(state.tradeHistory.prefix(20)) { trade in
                    HStack {
                        VStack(alignment: .leading) {
                            Text("\(trade.symbol) • \(trade.side == .buy ? "Long" : "Short")")
                            Text(trade.exitReason.rawValue)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(trade.realizedPnL >= 0 ? "+" : "")\(trade.realizedPnL, specifier: "%.2f")")
                            .foregroundStyle(trade.realizedPnL >= 0 ? .green : .red)
                    }
                }
            }
        }
    }

    private func signalTitle(_ signal: StrategySignal) -> String {
        switch signal {
        case .buy: return "BUY"
        case .sell: return "SELL"
        case .hold: return "HOLD"
        }
    }

    private func signalColor(_ signal: StrategySignal) -> Color {
        switch signal {
        case .buy: return .green
        case .sell: return .red
        case .hold: return .secondary
        }
    }
}

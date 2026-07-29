import SwiftUI

struct ChatView: View {
    @Bindable var appState: TRAVISAppState
    @State private var draft: String = ""

    var body: some View {
        VStack(spacing: 20) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    pendingApprovalsSection
                    transcriptSection
                }
            }

            inputBar

            HStack(spacing: 14) {
                Button(appState.isListening ? "Stop Listening" : "Start Listening") {
                    appState.toggleListening()
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)

                Button("Demo: Crypto") {
                    appState.sendCommand("Σταμάτα το αυτόματο trading")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(
            LinearGradient(
                colors: [Color.black, Color.blue.opacity(0.45), Color.black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var header: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.cyan.opacity(0.95),
                                Color.blue.opacity(0.65),
                                Color.blue.opacity(0.15),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 8,
                            endRadius: 140
                        )
                    )
                    .frame(width: 180, height: 180)
                    .blur(radius: 2)

                Circle()
                    .stroke(Color.cyan.opacity(0.8), lineWidth: 2)
                    .frame(width: 220, height: 220)

                Circle()
                    .stroke(Color.blue.opacity(0.45), lineWidth: 12)
                    .frame(width: 170, height: 170)

                VStack(spacing: 8) {
                    Text(appState.assistantName.uppercased())
                        .font(.headline)
                        .foregroundStyle(.white)

                    Text(appState.currentDeviceState.title)
                        .font(.caption)
                        .foregroundStyle(.cyan.opacity(0.9))
                }
            }

            Text(appState.lastResponseSummary)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.82))
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding(.top)
    }

    @ViewBuilder
    private var pendingApprovalsSection: some View {
        if !appState.approvalGate.pendingActions.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Εκκρεμείς Εγκρίσεις")
                    .font(.headline)
                    .foregroundStyle(.white)

                ForEach(appState.approvalGate.pendingActions) { action in
                    approvalCard(for: action)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color.orange.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 18))
        }
    }

    private func approvalCard(for action: ProposedAction) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(capabilityName(for: action.capabilityId))
                .font(.caption.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.cyan.opacity(0.2))
                .clipShape(Capsule())
                .foregroundStyle(.cyan)

            Text(action.summary)
                .font(.subheadline.bold())
                .foregroundStyle(.white)

            Text(action.reasoning)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))

            Text(action.expectedImpact)
                .font(.caption)
                .foregroundStyle(.orange.opacity(0.9))

            HStack(spacing: 12) {
                Button("Approve") {
                    appState.approvalGate.approve(action.id)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

                Button("Reject") {
                    appState.approvalGate.reject(action.id)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
        }
        .padding()
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Συνομιλία")
                .font(.headline)
                .foregroundStyle(.white)

            if appState.orchestrator.transcript.isEmpty {
                Text("Δεν υπάρχουν ακόμα μηνύματα.")
                    .foregroundStyle(.white.opacity(0.65))
            } else {
                ForEach(appState.orchestrator.transcript.suffix(30)) { entry in
                    transcriptRow(for: entry)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private func transcriptRow(for entry: OrchestratorTranscriptEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if entry.role == .capability, let capabilityId = entry.capabilityId {
                Text(capabilityName(for: capabilityId).uppercased())
                    .font(.caption2.bold())
                    .foregroundStyle(.cyan)
            } else if entry.role == .system {
                Text("SYSTEM")
                    .font(.caption2.bold())
                    .foregroundStyle(.orange)
            }

            Text(entry.text)
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: entry.role == .user ? .trailing : .leading)
        .padding()
        .background(Color.white.opacity(entry.role == .user ? 0.10 : 0.06))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var inputBar: some View {
        HStack(spacing: 12) {
            TextField("Δώσε εντολή στον Travis...", text: $draft)
                .textFieldStyle(.plain)
                .padding()
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(.white)

            Button {
                appState.sendCommand(draft)
                draft = ""
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.cyan)
            }
            .buttonStyle(.plain)
        }
    }

    private func capabilityName(for id: String) -> String {
        appState.orchestrator.capabilities.first(where: { $0.id == id })?.name ?? id
    }
}

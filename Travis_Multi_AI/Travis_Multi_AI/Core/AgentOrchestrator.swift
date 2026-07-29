import Foundation
import Observation

/// Keeps the list of every registered `AgentCapability`, receives messages
/// from the chat, decides which capability the message concerns, and
/// forwards it. Any `ProposedAction` a capability returns is submitted to
/// the approval gate — the orchestrator itself never executes anything.
@MainActor
@Observable
final class AgentOrchestrator {
    private(set) var capabilities: [AgentCapability] = []
    let approvalGate: ApprovalGateService

    init(approvalGate: ApprovalGateService = ApprovalGateService()) {
        self.approvalGate = approvalGate
    }

    func register(_ capability: AgentCapability) {
        capabilities.append(capability)
        approvalGate.register(capability)
    }

    /// Routes a natural-language message to the capability it concerns and
    /// submits whatever `ProposedAction` comes back to the approval gate.
    @discardableResult
    func route(_ message: String) async -> ProposedAction? {
        guard let capability = resolveCapability(for: message) else { return nil }
        guard let action = await capability.handle(command: message) else { return nil }

        approvalGate.submit(action)
        return action
    }

    /// Naive keyword match against each capability's name/description.
    /// Placeholder for real intent classification (e.g. via `AIService`)
    /// once that exists — swap this method's body out when it does.
    private func resolveCapability(for message: String) -> AgentCapability? {
        let normalized = message.lowercased()

        return capabilities.first { capability in
            [capability.name, capability.capabilityDescription].contains { text in
                text
                    .lowercased()
                    .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                    .contains { word in normalized.contains(word) }
            }
        }
    }
}

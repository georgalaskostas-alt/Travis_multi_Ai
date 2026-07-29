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
    private(set) var transcript: [OrchestratorTranscriptEntry] = []
    let approvalGate: ApprovalGateService

    /// Fired after the transcript changes, so `SyncService` can push the
    /// update without the orchestrator needing to know sync exists.
    var onChange: (() -> Void)?

    init(approvalGate: ApprovalGateService = ApprovalGateService()) {
        self.approvalGate = approvalGate
    }

    func register(_ capability: AgentCapability) {
        capabilities.append(capability)
        approvalGate.register(capability)
    }

    /// Routes a natural-language message to the capability it concerns,
    /// submits whatever `ProposedAction` comes back to the approval gate,
    /// and logs the exchange to the transcript for the chat UI.
    @discardableResult
    func route(_ message: String) async -> ProposedAction? {
        appendTranscript(OrchestratorTranscriptEntry(role: .user, text: message))

        guard let capability = resolveCapability(for: message) else {
            appendTranscript(OrchestratorTranscriptEntry(
                role: .system,
                text: "Καμία δραστηριότητα δεν αναγνώρισε αυτό το μήνυμα."
            ))
            return nil
        }

        guard let action = await capability.handle(command: message) else {
            appendTranscript(OrchestratorTranscriptEntry(
                role: .capability,
                text: "Δεν προέκυψε κάποια ενέργεια από αυτό το μήνυμα.",
                capabilityId: capability.id
            ))
            return nil
        }

        approvalGate.submit(action)
        appendTranscript(OrchestratorTranscriptEntry(
            role: .capability,
            text: action.summary,
            capabilityId: capability.id,
            proposedActionId: action.id
        ))
        return action
    }

    /// Merges a transcript entry received from another device via sync.
    /// Dedupes by id and keeps chronological order; never re-fires
    /// `onChange`, so applying a remote entry doesn't echo it right back.
    func mergeRemoteTranscriptEntry(_ entry: OrchestratorTranscriptEntry) {
        guard !transcript.contains(where: { $0.id == entry.id }) else { return }
        transcript.append(entry)
        transcript.sort { $0.createdAt < $1.createdAt }
    }

    private func appendTranscript(_ entry: OrchestratorTranscriptEntry) {
        transcript.append(entry)
        onChange?()
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

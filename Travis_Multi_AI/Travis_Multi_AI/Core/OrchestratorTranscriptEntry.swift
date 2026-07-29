import Foundation

enum TranscriptRole: String, Codable {
    case user
    case capability
    case system
}

/// One entry in the orchestrator's conversation log: a user message, a
/// capability's tagged response, or a system note (e.g. "no capability
/// matched"). This is what the unified chat UI renders, and what gets
/// synced across devices as "chat history with the orchestrator."
struct OrchestratorTranscriptEntry: Identifiable, Codable, Hashable {
    let id: UUID
    var role: TranscriptRole
    var text: String
    var capabilityId: String?
    var proposedActionId: UUID?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        role: TranscriptRole,
        text: String,
        capabilityId: String? = nil,
        proposedActionId: UUID? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.capabilityId = capabilityId
        self.proposedActionId = proposedActionId
        self.createdAt = createdAt
    }
}

import Foundation

enum ProposedActionStatus: String, Codable, CaseIterable {
    case pending
    case approved
    case rejected
}

/// Something a capability wants to do, awaiting human approval before it
/// takes effect. This is the only channel through which a capability's
/// decisions — including anything an adaptive/learning engine has
/// "learned" — reach the outside world.
struct ProposedAction: Identifiable, Codable, Hashable {
    let id: UUID
    var capabilityId: String
    var summary: String
    var reasoning: String
    var expectedImpact: String
    var status: ProposedActionStatus
    var createdAt: Date
    var resolvedAt: Date?
    var rejectionReason: String?

    init(
        id: UUID = UUID(),
        capabilityId: String,
        summary: String,
        reasoning: String,
        expectedImpact: String,
        status: ProposedActionStatus = .pending,
        createdAt: Date = Date(),
        resolvedAt: Date? = nil,
        rejectionReason: String? = nil
    ) {
        self.id = id
        self.capabilityId = capabilityId
        self.summary = summary
        self.reasoning = reasoning
        self.expectedImpact = expectedImpact
        self.status = status
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
        self.rejectionReason = rejectionReason
    }
}

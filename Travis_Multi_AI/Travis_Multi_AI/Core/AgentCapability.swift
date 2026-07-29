import Foundation

enum AgentCapabilityStatus: String, Codable, CaseIterable {
    case idle
    case running
    case paused
}

/// A single "activity" TRAVIS can perform (crypto trading today, others
/// later). Capabilities never act autonomously and never fold in anything
/// they've "learned" directly — every consequential decision is expressed
/// as a `ProposedAction` and must pass through the `ApprovalGateService`.
///
/// The protocol is globally isolated to the main actor so that routing,
/// approval resolution, and any future CloudKit-driven updates all happen
/// on a single, predictable thread.
@MainActor
protocol AgentCapability: AnyObject {
    /// Stable identifier used to register with the orchestrator and the
    /// approval gate, e.g. "crypto-trading". Not user-facing.
    var id: String { get }

    var name: String { get }
    var capabilityDescription: String { get }
    var status: AgentCapabilityStatus { get }

    /// Interprets a natural-language command from the user. Returns a
    /// `ProposedAction` describing what the capability wants to do, or nil
    /// if the message isn't relevant to this capability.
    func handle(command: String) async -> ProposedAction?

    /// Called by `ApprovalGateService` once a proposed action from this
    /// capability has been approved or rejected, so it can proceed or
    /// cancel accordingly.
    func resolve(_ action: ProposedAction)
}

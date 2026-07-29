import Foundation
import Observation

/// Holds the queue of pending `ProposedAction`s from every capability and
/// the record of what was approved or rejected. This is the single choke
/// point a capability's proposal must pass through before it can have any
/// effect. Isolated to the main actor so `pendingActions`/`history` never
/// see concurrent mutation — including from a future CloudKit sync engine.
@MainActor
@Observable
final class ApprovalGateService {
    private(set) var pendingActions: [ProposedAction] = []
    private(set) var history: [ProposedAction] = []

    private var registry: [String: WeakCapabilityBox] = [:]

    /// Fired after `pendingActions`/`history` change, so `SyncService` can
    /// push the update without this type needing to know sync exists.
    var onChange: (() -> Void)?

    func register(_ capability: AgentCapability) {
        registry[capability.id] = WeakCapabilityBox(capability)
    }

    func submit(_ action: ProposedAction) {
        pendingActions.append(action)
        onChange?()
    }

    /// Records an action a capability already executed without waiting for
    /// approval (e.g. a zero-risk paper-trading fill). It never enters the
    /// pending queue and never calls back into the capability — it's
    /// logged straight into history as approved, purely for visibility.
    func recordAutoApproved(_ action: ProposedAction) {
        var resolved = action
        resolved.status = .approved
        resolved.resolvedAt = resolved.resolvedAt ?? Date()
        history.insert(resolved, at: 0)
        onChange?()
    }

    @discardableResult
    func approve(_ actionId: UUID) -> ProposedAction? {
        resolve(actionId, to: .approved, rejectionReason: nil)
    }

    @discardableResult
    func reject(_ actionId: UUID, reason: String? = nil) -> ProposedAction? {
        resolve(actionId, to: .rejected, rejectionReason: reason)
    }

    /// Merges a `ProposedAction` received from another device via sync.
    /// Only updates local bookkeeping — it deliberately never calls back
    /// into the capability, since the device that actually resolved the
    /// action already triggered the real effect there; that capability's
    /// own state (e.g. crypto's positions) syncs separately. Never fires
    /// `onChange`, so applying a remote update doesn't echo it right back.
    func mergeRemote(_ action: ProposedAction) {
        if let index = pendingActions.firstIndex(where: { $0.id == action.id }) {
            if action.status == .pending {
                pendingActions[index] = action
            } else {
                pendingActions.remove(at: index)
                history.insert(action, at: 0)
            }
            return
        }

        if let index = history.firstIndex(where: { $0.id == action.id }) {
            history[index] = action
            return
        }

        if action.status == .pending {
            pendingActions.append(action)
        } else {
            history.insert(action, at: 0)
        }
    }

    @discardableResult
    private func resolve(_ actionId: UUID, to status: ProposedActionStatus, rejectionReason: String?) -> ProposedAction? {
        guard let index = pendingActions.firstIndex(where: { $0.id == actionId }) else { return nil }

        var action = pendingActions.remove(at: index)
        action.status = status
        action.resolvedAt = Date()
        action.rejectionReason = rejectionReason
        history.insert(action, at: 0)

        registry[action.capabilityId]?.value?.resolve(action)
        onChange?()
        return action
    }
}

/// Non-owning box so the registry never keeps a capability alive.
private final class WeakCapabilityBox {
    weak var value: AgentCapability?
    init(_ value: AgentCapability) { self.value = value }
}

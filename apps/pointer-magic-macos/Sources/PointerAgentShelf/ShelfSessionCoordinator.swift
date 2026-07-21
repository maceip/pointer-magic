import Foundation
import PointerShelfContracts

/// Owns follow / park / dismiss / restore / focus phase for the companion shelf.
///
/// Display-ready shelf documents arrive from outside; this type never imports
/// discovery or host modules so providers can reuse the same session machine.
@MainActor
public final class ShelfSessionCoordinator {
    public enum Phase: Equatable, Sendable {
        case idle
        case following(ShelfItemIdentity)
        case parked(ShelfItemIdentity)
        case dismissed(ShelfDismissKey)
        case focusing(ShelfItemIdentity)
    }

    public let controller: AgentShelfController

    public private(set) var phase: Phase = .idle
    public private(set) var lastPresentation: ShelfDocument?
    public private(set) var stickyIdentity: ShelfItemIdentity?

    /// Resolves the identity and document to park or summon.
    public var parkTargetProvider:
        (() -> (identity: ShelfItemIdentity, presentation: ShelfDocument)?)?
    /// Resolves a live follower target for corner restore.
    public var restoreTargetProvider:
        (() -> (identity: ShelfItemIdentity, presentation: ShelfDocument)?)?
    public var isEnabled: (() -> Bool)?
    public var isFocusInFlight: (() -> Bool)?
    public var onActivate: ((ShelfItemIdentity) -> Void)?
    public var onAction: ((String) -> Void)?
    public var onStatusChange: ((String) -> Void)?
    public var onNeedsMenuRebuild: (() -> Void)?
    public var onParked: (() -> Void)?
    public var onReleased: (() -> Void)?

    public init(controller: AgentShelfController = AgentShelfController()) {
        self.controller = controller
        wireController()
    }

    public var isParked: Bool {
        if case .parked = phase { return true }
        return controller.isLockedForInteraction
    }

    public var activeIdentity: ShelfItemIdentity? {
        switch phase {
        case let .following(identity), let .parked(identity), let .focusing(identity):
            return identity
        case let .dismissed(key):
            return key.identity
        case .idle:
            return stickyIdentity
        }
    }

    public func start() {
        controller.start()
    }

    public func stop() {
        controller.stop()
        phase = .idle
        lastPresentation = nil
        stickyIdentity = nil
    }

    /// Applies a provider update while unlocked. Locked interaction freezes identity.
    public func applyUpdate(
        identity: ShelfItemIdentity,
        presentation: ShelfDocument
    ) {
        guard !controller.isLockedForInteraction else { return }
        guard !presentation.isEmpty else {
            clearFollowerKeepingDismissal()
            return
        }

        let displayKey = ShelfDismissKey(
            identity: identity,
            state: presentation.dismissFingerprint
        )
        let previousKey: ShelfDismissKey?
        if let stickyIdentity, let lastPresentation {
            previousKey = ShelfDismissKey(
                identity: stickyIdentity,
                state: lastPresentation.dismissFingerprint
            )
        } else {
            previousKey = nil
        }
        let significance: AgentShelfUpdateSignificance = displayKey == previousKey
            ? .passive
            : .meaningful

        if case let .dismissed(dismissed) = phase, dismissed == displayKey {
            if controller.isVisible {
                controller.hide()
            }
            lastPresentation = presentation
            stickyIdentity = identity
            phase = .dismissed(dismissed)
            return
        }
        if case .dismissed = phase {
            // Identity or rendered state changed past the dismissed key.
            phase = .idle
        }

        let presentationChanged = presentation != lastPresentation
        if !controller.isVisible {
            controller.show(presentation, significance: significance)
        } else if presentationChanged || significance == .meaningful {
            controller.update(presentation, significance: significance)
        }
        lastPresentation = presentation
        stickyIdentity = identity
        phase = .following(identity)
    }

    /// Compatibility path for compact agent presentations.
    public func applyUpdate(
        identity: ShelfItemIdentity,
        presentation: AgentShelfPresentation
    ) {
        applyUpdate(
            identity: identity,
            presentation: presentation.asShelfDocument(id: identity.rawValue)
        )
    }

    /// Passive commit from the enrichment mailbox. Never opens/hides the shelf,
    /// never starts a meaningful reveal lease, and never runs while parked.
    /// Pointer follow ignores late enrichment entirely via the caller's generation fence.
    public func applyEnrichment(
        identity: ShelfItemIdentity,
        presentation: ShelfDocument
    ) {
        guard !controller.isLockedForInteraction else { return }
        guard !presentation.isEmpty else { return }
        guard controller.isVisible else { return }
        if case .dismissed = phase { return }

        if presentation != lastPresentation {
            controller.update(presentation, significance: .passive)
            lastPresentation = presentation
        }
        // Keep the present-lane identity (usually the agent). Enrichment must not
        // retarget sticky identity to a sample document id.
        if stickyIdentity == nil {
            stickyIdentity = identity
        }
        if case .idle = phase {
            phase = .following(stickyIdentity ?? identity)
        }
    }

    /// Attention briefly vanished. Keep the last follower while `stickyStillLive`.
    public func noteAttentionGap(stickyStillLive: Bool) {
        guard !controller.isLockedForInteraction else { return }
        if stickyStillLive {
            return
        }
        clearFollowerKeepingDismissal()
    }

    @discardableResult
    public func tryPark() -> Bool {
        guard isEnabled?() ?? true else {
            publishStatus("Pointer Magic is off")
            return false
        }
        guard !(isFocusInFlight?() ?? false) else {
            publishStatus("Already switching")
            return false
        }
        if controller.isLockedForInteraction {
            return true
        }
        guard let target = parkTargetProvider?() else {
            publishStatus("No active item to park")
            return false
        }

        if !controller.isVisible {
            controller.show(target.presentation, significance: .passive)
            lastPresentation = target.presentation
            stickyIdentity = target.identity
        }

        controller.lockForInteraction()
        guard controller.isLockedForInteraction else {
            publishStatus("Could not lock the shelf")
            return false
        }
        phase = .parked(target.identity)
        stickyIdentity = target.identity
        publishStatus("Shelf locked — click to open")
        onParked?()
        return true
    }

    @discardableResult
    public func releasePark() -> Bool {
        guard controller.isLockedForInteraction,
              !(isFocusInFlight?() ?? false)
        else { return false }
        finishPark()
        if let stickyIdentity, lastPresentation != nil {
            phase = .following(stickyIdentity)
        } else {
            phase = .idle
        }
        publishStatus("Shelf following the pointer")
        onReleased?()
        onNeedsMenuRebuild?()
        return true
    }

    @discardableResult
    public func restoreFollower() -> Bool {
        guard isEnabled?() ?? true else {
            publishStatus("Pointer Magic is off")
            return false
        }
        guard !(isFocusInFlight?() ?? false) else {
            publishStatus("Already switching")
            return false
        }
        guard let target = restoreTargetProvider?() else {
            publishStatus("No active item to follow")
            onNeedsMenuRebuild?()
            return false
        }

        if controller.isLockedForInteraction {
            finishPark()
            onReleased?()
        }
        phase = .following(target.identity)
        stickyIdentity = target.identity
        lastPresentation = target.presentation
        if controller.isVisible {
            controller.update(target.presentation, significance: .passive)
        } else {
            controller.show(target.presentation, significance: .passive)
        }
        publishStatus("Shelf following the pointer")
        onNeedsMenuRebuild?()
        return controller.isVisible && !controller.isLockedForInteraction
    }

    public func dismissParked() {
        guard controller.isLockedForInteraction,
              case let .parked(identity) = phase,
              let presentation = lastPresentation,
              stickyIdentity == identity
        else { return }

        let key = ShelfDismissKey(
            identity: identity,
            state: presentation.dismissFingerprint
        )
        phase = .dismissed(key)
        finishPark()
        onReleased?()
        publishStatus("Hidden until this item changes")
        controller.hide()
    }

    public func beginFocus() -> ShelfItemIdentity? {
        guard controller.isLockedForInteraction,
              !(isFocusInFlight?() ?? false)
        else { return nil }
        let identity: ShelfItemIdentity?
        switch phase {
        case let .parked(value), let .focusing(value):
            identity = value
        case .following, .dismissed, .idle:
            identity = stickyIdentity
        }
        guard let identity else { return nil }
        phase = .focusing(identity)
        controller.suspendInteractionLease()
        return identity
    }

    /// Successful activation: return to the click-through follower.
    public func endFocus(restoreFollow: Bool) {
        controller.resumeInteractionLease()
        finishPark()
        onReleased?()
        if restoreFollow, let stickyIdentity {
            phase = .following(stickyIdentity)
        } else if case .focusing = phase {
            phase = stickyIdentity.map { .following($0) } ?? .idle
        }
    }

    /// Failed activation: keep the shelf parked so the person can retry or dismiss.
    public func cancelFocusKeepParked(status: String? = nil) {
        guard case let .focusing(identity) = phase else { return }
        phase = .parked(identity)
        if let status {
            showInteractionStatus(status)
        }
        if controller.isLockedForInteraction {
            controller.resumeInteractionLease()
        } else {
            controller.lockForInteraction()
        }
    }

    public func noteParkLeaseExpired() {
        if case .parked = phase, let stickyIdentity {
            phase = .following(stickyIdentity)
        } else if case .parked = phase {
            phase = .idle
        }
        onReleased?()
        publishStatus("Click ✦ to park the shelf")
        onNeedsMenuRebuild?()
    }

    public func showInteractionStatus(_ status: String) {
        controller.showInteractionStatus(status)
        publishStatus(status)
    }

    public func toggleParkFromMenu() {
        if controller.isLockedForInteraction {
            _ = releasePark()
            publishStatus("Click ✦ to park the shelf")
        } else {
            _ = tryPark()
        }
        onNeedsMenuRebuild?()
    }

    private func wireController() {
        controller.onParkRequested = { [weak self] in
            self?.tryPark() ?? false
        }
        controller.onReleaseRequested = { [weak self] in
            self?.releasePark() ?? false
        }
        controller.onFollowerRestoreRequested = { [weak self] in
            self?.restoreFollower() ?? false
        }
        controller.onInteractionExpired = { [weak self] in
            self?.noteParkLeaseExpired()
        }
        controller.onClick = { [weak self] in
            guard let self else { return }
            // Expanded context shelves activate through action pills only.
            if self.lastPresentation?.usesExpandedLayout == true {
                return
            }
            guard let identity = self.beginFocus() else { return }
            self.onActivate?(identity)
        }
        controller.onAction = { [weak self] actionID in
            self?.onAction?(actionID)
        }
        controller.onDismiss = { [weak self] in
            self?.dismissParked()
        }
    }

    private func finishPark() {
        controller.unlockInteraction()
    }

    private func clearFollowerKeepingDismissal() {
        if controller.isVisible {
            controller.hide()
        }
        if case .dismissed = phase {
            // Keep the dismissed key across transient observer gaps.
            return
        }
        phase = .idle
    }

    private func publishStatus(_ message: String) {
        onStatusChange?(message)
    }
}

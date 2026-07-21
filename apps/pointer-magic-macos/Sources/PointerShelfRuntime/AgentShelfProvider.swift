import Foundation
import os
import PointerShelfContracts

/// Provider #0 — emits the compact agent shelf document from host-supplied snapshots.
public final class AgentShelfProvider: ShelfProviding, Sendable {
    public static let providerID = "agent"

    public let id = AgentShelfProvider.providerID
    public let priority = 100
    public let interests = ShelfProviderInterests.any

    public struct Snapshot: Sendable, Hashable {
        public var identityKey: String
        public var provider: String
        public var providerMark: String
        public var directoryName: String
        public var state: String
        public var revision: UInt64

        public init(
            identityKey: String,
            provider: String,
            providerMark: String,
            directoryName: String,
            state: String,
            revision: UInt64
        ) {
            self.identityKey = identityKey
            self.provider = provider
            self.providerMark = providerMark
            self.directoryName = directoryName
            self.state = state
            self.revision = revision
        }
    }

    private struct State: Sendable {
        var snapshot: Snapshot?
        var activateHandler: (@Sendable (String) async -> ShelfActionResult)?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public func publish(_ snapshot: Snapshot?) {
        state.withLock { $0.snapshot = snapshot }
    }

    public func setActivateHandler(
        _ handler: (@Sendable (String) async -> ShelfActionResult)?
    ) {
        state.withLock { $0.activateHandler = handler }
    }

    public func propose(packet: PointerContextPacket) async -> ShelfProposal {
        let snapshot = state.withLock { $0.snapshot }
        guard let snapshot else { return .decline }
        return .document(
            ShelfDocument.compact(
                id: snapshot.identityKey,
                providerId: id,
                revision: snapshot.revision,
                provider: snapshot.provider,
                state: snapshot.state,
                directoryName: snapshot.directoryName,
                providerMark: snapshot.providerMark,
                contextRevision: packet.revision
            )
        )
    }

    public func invoke(
        actionId: String,
        packet: PointerContextPacket,
        grant: ShelfCapabilityGrant
    ) async -> ShelfActionResult {
        let (snapshot, handler) = state.withLock { ($0.snapshot, $0.activateHandler) }
        guard actionId == ShelfProviderRuntime.primaryActivateActionID || actionId == "activate"
        else {
            return .unavailable("Unknown agent action")
        }
        guard let snapshot else {
            return .unavailable("That agent is no longer available")
        }
        if let handler {
            return await handler(snapshot.identityKey)
        }
        return .completed("Activate \(snapshot.provider)")
    }
}

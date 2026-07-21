import Foundation
import PointerShelfContracts

/// Developer-facing shelf provider. Returns declarative documents; never draws UI.
public protocol ShelfProviding: AnyObject, Sendable {
    var id: String { get }
    var priority: Int { get }
    var interests: ShelfProviderInterests { get }

    func propose(packet: PointerContextPacket) async -> ShelfProposal
    func invoke(
        actionId: String,
        packet: PointerContextPacket,
        grant: ShelfCapabilityGrant
    ) async -> ShelfActionResult
}

/// Default invoke for providers that only propose content.
open class DecliningShelfProvider: ShelfProviding, @unchecked Sendable {
    public let id: String
    public let priority: Int
    public let interests: ShelfProviderInterests

    public init(
        id: String,
        priority: Int = 0,
        interests: ShelfProviderInterests = .any
    ) {
        self.id = id
        self.priority = priority
        self.interests = interests
    }

    open func propose(packet: PointerContextPacket) async -> ShelfProposal {
        .decline
    }

    open func invoke(
        actionId: String,
        packet: PointerContextPacket,
        grant: ShelfCapabilityGrant
    ) async -> ShelfActionResult {
        .unavailable("Action \(actionId) is not implemented")
    }
}

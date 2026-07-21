import Foundation
import PointerShelfContracts

/// Hosts in-process providers, merges proposals, and freezes context for parked invokes.
public actor ShelfProviderRuntime {
    public struct Configuration: Sendable {
        public var proposeTimeoutNanoseconds: UInt64
        public var maximumProvidersPerPropose: Int
        public var maximumVisibleActions: Int

        public init(
            proposeTimeoutNanoseconds: UInt64 = 120_000_000,
            maximumProvidersPerPropose: Int = 4,
            maximumVisibleActions: Int = ShelfDocument.maximumVisibleActions
        ) {
            self.proposeTimeoutNanoseconds = proposeTimeoutNanoseconds
            self.maximumProvidersPerPropose = maximumProvidersPerPropose
            self.maximumVisibleActions = maximumVisibleActions
        }
    }

    private let configuration: Configuration
    private var providers: [String: any ShelfProviding] = [:]
    private var frozenPacket: PointerContextPacket?
    private var frozenDocument: ShelfDocument?
    private var latestPacket: PointerContextPacket?
    private var latestDocument: ShelfDocument?
    private var proposeGeneration: UInt64 = 0

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func register(_ provider: any ShelfProviding) {
        providers[provider.id] = provider
    }

    public func unregister(id: String) {
        providers.removeValue(forKey: id)
    }

    public var currentPacket: PointerContextPacket? { latestPacket }
    public var currentDocument: ShelfDocument? { latestDocument }
    public var parkedPacket: PointerContextPacket? { frozenPacket }
    public var parkedDocument: ShelfDocument? { frozenDocument }

    public func propose(using packet: PointerContextPacket) async -> ShelfDocument? {
        latestPacket = packet
        proposeGeneration &+= 1
        let generation = proposeGeneration

        let ranked = providers.values
            .filter { $0.interests.matches(packet) }
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
                return lhs.id < rhs.id
            }
            .prefix(configuration.maximumProvidersPerPropose)

        var documents: [ShelfDocument] = []
        documents.reserveCapacity(ranked.count)

        await withTaskGroup(of: ShelfProposal?.self) { group in
            for provider in ranked {
                let timeout = configuration.proposeTimeoutNanoseconds
                group.addTask {
                    await Self.proposeWithTimeout(provider: provider, packet: packet, timeoutNs: timeout)
                }
            }
            for await proposal in group {
                if let document = proposal?.document, !document.isEmpty {
                    documents.append(document)
                }
            }
        }

        guard generation == proposeGeneration else {
            return latestDocument
        }

        let merged = Self.merge(
            documents: documents,
            contextRevision: packet.revision,
            maximumActions: configuration.maximumVisibleActions
        )
        latestDocument = merged
        return merged
    }

    /// Freezes the packet/document used for invoke while the shelf is parked.
    public func park(document: ShelfDocument? = nil) {
        frozenPacket = latestPacket
        frozenDocument = document ?? latestDocument
    }

    public func releasePark() {
        frozenPacket = nil
        frozenDocument = nil
    }

    public func invoke(
        actionId: String,
        requestedCapabilities: [ShelfCapability] = [.focusTarget, .readSelection]
    ) async -> ShelfActionResult {
        guard let packet = frozenPacket ?? latestPacket else {
            return .unavailable("No context is available")
        }
        guard packet.authorizesActions else {
            return .denied("Context is not fresh enough to authorize an action")
        }
        guard let document = frozenDocument ?? latestDocument else {
            return .unavailable("No shelf document is available")
        }
        if actionId == Self.primaryActivateActionID {
            return await invokePrimary(
                document: document,
                packet: packet,
                requestedCapabilities: requestedCapabilities
            )
        }

        guard let action = document.actions.first(where: { $0.id == actionId }), action.enabled
        else {
            return .unavailable("Unknown action")
        }

        let providerID = action.providerHint(in: document)
        guard let provider = providers[providerID] else {
            return .unavailable("Provider is unavailable")
        }

        let localActionId = action.localActionID()
        let grant = ShelfCapabilityGrant(
            capabilities: requestedCapabilities,
            contextRevision: packet.revision,
            documentRevision: document.revision,
            actionId: localActionId
        )
        return await provider.invoke(actionId: localActionId, packet: packet, grant: grant)
    }

    public static let primaryActivateActionID = "__primary_activate__"

    private func invokePrimary(
        document: ShelfDocument,
        packet: PointerContextPacket,
        requestedCapabilities: [ShelfCapability]
    ) async -> ShelfActionResult {
        guard let provider = providers[document.providerId] else {
            return .unavailable("Provider is unavailable")
        }
        let grant = ShelfCapabilityGrant(
            capabilities: requestedCapabilities,
            contextRevision: packet.revision,
            documentRevision: document.revision,
            actionId: Self.primaryActivateActionID
        )
        return await provider.invoke(
            actionId: Self.primaryActivateActionID,
            packet: packet,
            grant: grant
        )
    }

    private static func proposeWithTimeout(
        provider: any ShelfProviding,
        packet: PointerContextPacket,
        timeoutNs: UInt64
    ) async -> ShelfProposal? {
        await withTaskGroup(of: ShelfProposal?.self) { group in
            group.addTask {
                await provider.propose(packet: packet)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNs)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? nil
        }
    }

    public static func merge(
        documents: [ShelfDocument],
        contextRevision: UInt64,
        maximumActions: Int = ShelfDocument.maximumVisibleActions
    ) -> ShelfDocument? {
        guard !documents.isEmpty else { return nil }

        let primaryOwner = documents.first(where: { $0.primary != nil }) ?? documents.first
        guard let primaryOwner else { return nil }

        var actions: [ShelfActionPill] = []
        var seenActionIDs = Set<String>()
        for document in documents {
            for action in document.actions where action.enabled {
                let namespaced = action.id.contains("::")
                    ? action.id
                    : "\(document.providerId)::\(action.id)"
                guard !seenActionIDs.contains(namespaced) else { continue }
                seenActionIDs.insert(namespaced)
                actions.append(
                    ShelfActionPill(
                        id: namespaced,
                        title: action.title,
                        icon: action.icon,
                        enabled: action.enabled,
                        rank: action.rank
                    )
                )
            }
        }

        actions.sort { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            return lhs.id < rhs.id
        }
        if actions.count > maximumActions {
            actions = Array(actions.prefix(maximumActions))
        }

        let fallback = primaryOwner.fallback
            ?? documents.first(where: { $0.fallback != nil })?.fallback

        if primaryOwner.primary == nil, actions.isEmpty, let fallback, !fallback.isEmpty {
            return ShelfDocument.compact(
                id: primaryOwner.id,
                providerId: primaryOwner.providerId,
                revision: primaryOwner.revision,
                provider: fallback.provider,
                state: fallback.state,
                directoryName: fallback.directoryName,
                providerMark: fallback.providerMark,
                contextRevision: contextRevision
            )
        }

        return ShelfDocument(
            id: primaryOwner.id,
            providerId: primaryOwner.providerId,
            revision: primaryOwner.revision,
            contextRevision: contextRevision,
            ttlMs: primaryOwner.ttlMs,
            primary: primaryOwner.primary,
            actions: actions,
            fallback: primaryOwner.primary == nil ? fallback : nil
        )
    }
}

private extension ShelfActionPill {
    func providerHint(in document: ShelfDocument) -> String {
        if let separator = id.range(of: "::") {
            return String(id[..<separator.lowerBound])
        }
        return document.providerId
    }

    func localActionID() -> String {
        if let separator = id.range(of: "::") {
            return String(id[separator.upperBound...])
        }
        return id
    }
}

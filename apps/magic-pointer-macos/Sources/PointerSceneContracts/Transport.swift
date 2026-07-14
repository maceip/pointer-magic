/// Why a transport stopped. This is operational state only; it does not alter a
/// receiver's coverage or freshness by itself. The host adapter must close the
/// registered source so the receiver records the corresponding coverage break.
public enum SceneBatchChannelCloseReason: String, Codable, Hashable, Sendable {
    case localShutdown
    case remoteShutdown
    case authenticationLost
    case protocolViolation
    case transportFailure
}

/// Pull-based framing boundary for a future local IPC or network adapter.
///
/// The presented manifest and every batch are untrusted transport data. A host
/// authenticates the peer, derives a receiver-owned grant policy, registers the
/// manifest, and retains the resulting non-Codable `SceneSourceHandle` locally.
/// The handle is never sent through this channel. Pulling one batch at a time gives
/// the host explicit backpressure instead of accepting an unbounded event stream.
///
/// This protocol intentionally says nothing about sockets, discovery, credentials,
/// encryption, or serialization. Those belong to a concrete adapter; none is part
/// of the local Magic Pointer runtime today.
public protocol SceneEventBatchChannel: Sendable {
    var presentedManifest: SceneSourceManifest { get }

    /// Returns nil only after an orderly remote end-of-stream.
    func nextBatch() async throws -> SceneEventBatch?

    /// Sends the receiver's exact result for the most recently pulled batch.
    func acknowledge(_ receipt: IngestReceipt) async throws

    func close(reason: SceneBatchChannelCloseReason) async
}

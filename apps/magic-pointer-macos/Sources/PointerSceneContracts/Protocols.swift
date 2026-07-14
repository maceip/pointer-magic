/// Transport-neutral ingestion boundary. Authentication and handle issuance happen
/// before this call; producer payloads cannot contain a `SceneSourceHandle`.
public protocol SceneEventSink: Sendable {
    func ingest(
        _ batch: SceneEventBatch,
        through source: SceneSourceHandle
    ) async -> IngestReceipt
}

public protocol SceneDiscoverySource: Sendable {
    var manifest: SceneSourceManifest { get }

    func start(
        handle: SceneSourceHandle,
        sink: any SceneEventSink
    ) async throws

    func refresh(_ request: RefreshRequest) async -> RefreshDisposition

    func stop() async
}


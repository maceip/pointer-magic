import Foundation
import PointerSceneContracts
import Testing

@Suite("Transport-neutral remote boundary")
struct TransportBoundaryTests {
    @Test("A channel carries manifests, batches, and receipts but no source handle")
    func pullAndAcknowledge() async throws {
        let epoch = SceneSourceEpoch(source: SceneSourceIdentity(
            device: DevicePrincipalID(),
            source: SceneSourceID()
        ))
        let session = SceneSessionID()
        let manifest = try SceneSourceManifest(
            sourceEpoch: epoch,
            sessionID: session,
            displayName: "Remote fixture",
            kind: .remoteDevice,
            capabilities: [.checkpoints]
        )
        let field = try SceneFieldKey("object.kind")
        let observation = try SceneObservation(
            subject: SourceObjectKey(sourceEpoch: epoch, objectID: SourceObjectID()),
            observedAtSourceMonotonicNs: 1,
            claims: [try SceneFieldClaim(
                field: field,
                value: .text("fixture"),
                knowledge: .observed,
                confidence: 1,
                sensitivity: .ordinary,
                evidence: [try SceneEvidence(kind: .applicationAdapter)]
            )]
        )
        let envelope = try SceneEventEnvelope(
            revision: SourceRevision(sourceEpoch: epoch, sequence: 1),
            emittedAtSourceMonotonicNs: 1,
            payload: .checkpoint(try SceneCheckpoint(observations: [observation]))
        )
        let batch = try SceneEventBatch(events: [envelope])
        let channel = FixtureSceneBatchChannel(manifest: manifest, batch: batch)

        #expect(channel.presentedManifest == manifest)
        let received = await channel.nextBatch()
        #expect(received == batch)
        let receipt = try IngestReceipt(
            batchID: batch.batchID,
            status: .accepted,
            acceptedThrough: envelope.revision
        )
        await channel.acknowledge(receipt)
        #expect(await channel.receipt() == receipt)
        #expect(await channel.nextBatch() == nil)
    }
}

private actor FixtureSceneBatchChannel: SceneEventBatchChannel {
    nonisolated let presentedManifest: SceneSourceManifest
    private var batch: SceneEventBatch?
    private var acknowledgedReceipt: IngestReceipt?

    init(manifest: SceneSourceManifest, batch: SceneEventBatch) {
        self.presentedManifest = manifest
        self.batch = batch
    }

    func nextBatch() -> SceneEventBatch? {
        defer { batch = nil }
        return batch
    }

    func acknowledge(_ receipt: IngestReceipt) {
        acknowledgedReceipt = receipt
    }

    func close(reason _: SceneBatchChannelCloseReason) {}

    func receipt() -> IngestReceipt? { acknowledgedReceipt }
}

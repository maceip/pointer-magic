import Foundation
import PointerMacSceneDiscovery
@testable import PointerSceneContracts
import Testing

@Suite("scene source emitter")
struct SceneSourceEmitterTests {
    @Test("source and coverage sequences are monotonic and have separate lifetimes")
    func monotonicSequences() async throws {
        let device = DevicePrincipalID(rawValue: UUID(
            uuidString: "00000000-0000-0000-0000-000000000001"
        )!)
        let sourceEpoch = SceneSourceEpoch(
            source: SceneSourceIdentity(
                device: device,
                source: SceneSourceID(rawValue: UUID(
                    uuidString: "00000000-0000-0000-0000-000000000002"
                )!)
            ),
            epochID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        )
        let sessionID = SceneSessionID(rawValue: UUID(
            uuidString: "00000000-0000-0000-0000-000000000004"
        )!)
        let grantID = SceneSourceGrantID(rawValue: UUID(
            uuidString: "00000000-0000-0000-0000-000000000005"
        )!)
        let handle = SceneSourceHandle(
            receiverIssuedID: SceneSourceHandleID(rawValue: UUID(
                uuidString: "00000000-0000-0000-0000-000000000006"
            )!),
            sourceEpoch: sourceEpoch,
            sessionID: sessionID,
            grantID: grantID
        )
        let sink = RecordingSceneSink()
        let emitter = try SceneSourceEmitter(
            sourceEpoch: sourceEpoch,
            handle: handle,
            sink: sink,
            clock: FixedSceneClock(value: 44)
        )
        let scope = SceneCoverageScope.sourceProjection(sourceEpoch)

        _ = try await emitter.emit([
            .checkpoint(try SceneCheckpoint(observations: [])),
            .checkpoint(try SceneCheckpoint(observations: [])),
        ])
        _ = try await emitter.beginBestEffortCoverage(scope: scope)
        _ = try await emitter.heartbeatCoverage()
        _ = try await emitter.gapCoverage(.sourceBackpressure)
        #expect(!(await emitter.hasActiveCoverage()))
        #expect(await emitter.hasOpenCoverageStream())
        _ = try await emitter.endCoverage(.producerPaused)
        _ = try await emitter.beginBestEffortCoverage(scope: scope)

        let events = await sink.events()
        #expect(events.map(\.revision.sequence) == [1, 2, 3, 4, 5, 6, 7])
        #expect(events.allSatisfy { $0.emittedAtSourceMonotonicNs == 44 })

        let coverage = events.compactMap { event -> CoverageReport? in
            if case let .coverage(report) = event.payload { return report }
            return nil
        }
        #expect(coverage.map(\.continuitySequence) == [1, 2, 3, 4, 1])
        #expect(coverage[0].streamID == coverage[3].streamID)
        #expect(coverage[4].streamID != coverage[3].streamID)
        #expect(coverage.allSatisfy { $0.guarantee == .bestEffort })
        #expect(await emitter.currentSourceSequence() == 7)
    }
}

private struct FixedSceneClock: SceneSourceMonotonicClock {
    let value: UInt64
    func nowNanoseconds() -> UInt64 { value }
}

private actor RecordingSceneSink: SceneEventSink {
    private var received: [SceneEventEnvelope] = []

    func ingest(
        _ batch: SceneEventBatch,
        through _: SceneSourceHandle
    ) async -> IngestReceipt {
        received.append(contentsOf: batch.events)
        return try! IngestReceipt(
            batchID: batch.batchID,
            status: .accepted,
            acceptedThrough: batch.events.last?.revision
        )
    }

    func events() -> [SceneEventEnvelope] { received }
}

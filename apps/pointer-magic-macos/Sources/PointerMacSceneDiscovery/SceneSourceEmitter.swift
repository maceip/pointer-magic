import Dispatch
import Foundation
import PointerSceneContracts

public protocol SceneSourceMonotonicClock: Sendable {
    func nowNanoseconds() -> UInt64
}

public struct SystemSceneSourceMonotonicClock: SceneSourceMonotonicClock {
    public init() {}
    public func nowNanoseconds() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
}

public enum SceneSourceEmitterError: Error, Equatable, Sendable {
    case sourceHandleMismatch
    case sequenceExhausted
    case coverageAlreadyActive
    case coverageNotActive
}

/// Serializes every producer event through one monotonic source-revision counter.
/// Coverage continuity has its own counter and is never inferred from source revisions.
public actor SceneSourceEmitter {
    private struct ActiveCoverage: Sendable {
        var streamID: CoverageStreamID
        var continuitySequence: UInt64
        let scope: SceneCoverageScope
        let maximumSilenceNs: UInt64
        var isCurrent: Bool
    }

    public nonisolated let sourceEpoch: SceneSourceEpoch
    public nonisolated let handle: SceneSourceHandle

    private let sink: any SceneEventSink
    private let clock: any SceneSourceMonotonicClock
    private var sourceSequence: UInt64 = 0
    private var coverageLifecycle: ActiveCoverage?

    public init(
        sourceEpoch: SceneSourceEpoch,
        handle: SceneSourceHandle,
        sink: any SceneEventSink,
        clock: any SceneSourceMonotonicClock = SystemSceneSourceMonotonicClock()
    ) throws {
        guard handle.sourceEpoch == sourceEpoch else {
            throw SceneSourceEmitterError.sourceHandleMismatch
        }
        self.sourceEpoch = sourceEpoch
        self.handle = handle
        self.sink = sink
        self.clock = clock
    }

    @discardableResult
    public func emit(_ payload: SceneEventPayload) async throws -> IngestReceipt {
        try await emit([payload])
    }

    @discardableResult
    public func emit(_ payloads: [SceneEventPayload]) async throws -> IngestReceipt {
        var envelopes: [SceneEventEnvelope] = []
        envelopes.reserveCapacity(payloads.count)
        var candidateSequence = sourceSequence
        for payload in payloads {
            guard candidateSequence < UInt64.max else {
                throw SceneSourceEmitterError.sequenceExhausted
            }
            candidateSequence += 1
            let revision = try SourceRevision(
                sourceEpoch: sourceEpoch,
                sequence: candidateSequence
            )
            envelopes.append(try SceneEventEnvelope(
                revision: revision,
                emittedAtSourceMonotonicNs: clock.nowNanoseconds(),
                payload: payload
            ))
        }
        let batch = try SceneEventBatch(events: envelopes)
        // Do not burn revisions for locally invalid payloads. Once a valid batch reaches
        // the sink, its revision is consumed even if the receiver rejects it.
        sourceSequence = candidateSequence
        return await sink.ingest(batch, through: handle)
    }

    @discardableResult
    public func beginBestEffortCoverage(
        scope: SceneCoverageScope,
        maximumSilenceNs: UInt64 = 15_000_000_000
    ) async throws -> IngestReceipt {
        guard coverageLifecycle == nil else {
            throw SceneSourceEmitterError.coverageAlreadyActive
        }
        let coverage = ActiveCoverage(
            streamID: CoverageStreamID(),
            continuitySequence: 1,
            scope: scope,
            maximumSilenceNs: maximumSilenceNs,
            isCurrent: true
        )
        let report = try makeCoverageReport(
            coverage,
            state: .started(maximumSilenceNs: maximumSilenceNs)
        )
        coverageLifecycle = coverage
        return try await emit(.coverage(report))
    }

    @discardableResult
    public func heartbeatCoverage() async throws -> IngestReceipt {
        guard var coverage = coverageLifecycle, coverage.isCurrent else {
            throw SceneSourceEmitterError.coverageNotActive
        }
        guard coverage.continuitySequence < UInt64.max else {
            throw SceneSourceEmitterError.sequenceExhausted
        }
        coverage.continuitySequence += 1
        let report = try makeCoverageReport(coverage, state: .heartbeat)
        coverageLifecycle = coverage
        return try await emit(.coverage(report))
    }

    /// Breaks the current lease. A later resynchronization must call
    /// `beginBestEffortCoverage`, which creates a new stream identity.
    @discardableResult
    public func gapCoverage(_ reason: CoverageGapReason) async throws -> IngestReceipt {
        guard var coverage = coverageLifecycle, coverage.isCurrent else {
            throw SceneSourceEmitterError.coverageNotActive
        }
        guard coverage.continuitySequence < UInt64.max else {
            throw SceneSourceEmitterError.sequenceExhausted
        }
        coverage.continuitySequence += 1
        coverage.isCurrent = false
        let report = try makeCoverageReport(coverage, state: .gap(reason))
        coverageLifecycle = coverage
        return try await emit(.coverage(report))
    }

    @discardableResult
    public func endCoverage(_ reason: CoverageGapReason) async throws -> IngestReceipt {
        guard var coverage = coverageLifecycle else {
            throw SceneSourceEmitterError.coverageNotActive
        }
        guard coverage.continuitySequence < UInt64.max else {
            throw SceneSourceEmitterError.sequenceExhausted
        }
        coverage.continuitySequence += 1
        let report = try makeCoverageReport(coverage, state: .ended(reason))
        coverageLifecycle = nil
        return try await emit(.coverage(report))
    }

    public func currentSourceSequence() -> UInt64 { sourceSequence }
    public func hasActiveCoverage() -> Bool { coverageLifecycle?.isCurrent == true }
    public func hasOpenCoverageStream() -> Bool { coverageLifecycle != nil }

    private func makeCoverageReport(
        _ coverage: ActiveCoverage,
        state: CoverageReportState
    ) throws -> CoverageReport {
        try CoverageReport(
            streamID: coverage.streamID,
            scope: coverage.scope,
            continuitySequence: coverage.continuitySequence,
            state: state,
            guarantee: .bestEffort,
            coveredFields: [],
            coveredEvidenceKinds: [],
            observedAtSourceMonotonicNs: clock.nowNanoseconds()
        )
    }
}

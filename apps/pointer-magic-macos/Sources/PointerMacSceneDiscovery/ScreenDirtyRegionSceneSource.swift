@preconcurrency import CoreGraphics
@preconcurrency import CoreMedia
import Dispatch
import Foundation
import PointerSceneContracts
@preconcurrency import ScreenCaptureKit

enum ScreenDirtyRegionSourceToken: Hashable, Sendable {
    case frame(ScreenDirtyRegionFrame)
    case streamStopped(displayID: UInt32)
    case explicitRefresh
    case heartbeat
}

protocol ScreenDirtyRegionCaptureSession: Sendable {
    func stop() async
}

protocol ScreenDirtyRegionCaptureProviding: Sendable {
    /// This API is preflight-only and must never request Screen Recording access.
    func hasScreenRecordingPermission() -> Bool

    func startCapture(
        coordinateSnapshot: MacDesktopCoordinateSnapshot,
        mailbox: BoundedSceneTokenMailbox<ScreenDirtyRegionSourceToken>,
        maximumRectsPerFrame: Int
    ) async throws -> any ScreenDirtyRegionCaptureSession
}

public enum ScreenDirtyRegionSceneSourceError: Error, Equatable, Sendable {
    case alreadyStarted
    case stopped
    case sourceHandleMismatch
    case coordinateRegistryDeviceMismatch
    case sinkRejected(IngestRejectionCode?)
    case dirtyRevisionExhausted
}

private enum ScreenDirtyRegionUnavailability: Hashable, Sendable {
    case permissionDenied
    case topologyUnavailable
    case captureFailed
}

/// A metadata-only ScreenCaptureKit source. Screen frames exist only inside the
/// framework callback; this actor receives bounded dirty-rectangle value tokens and
/// never receives, stores, or analyzes pixel buffers.
public actor ScreenDirtyRegionSceneSource: SceneDiscoverySource {
    private enum Lifecycle: Sendable {
        case idle
        case starting
        case running
        case stopping
        case stopped
    }

    public nonisolated let manifest: SceneSourceManifest

    private let coordinateRegistry: MacDesktopCoordinateRegistry
    private let captureProvider: any ScreenDirtyRegionCaptureProviding
    private let clock: any SceneSourceMonotonicClock
    private let mailbox: BoundedSceneTokenMailbox<ScreenDirtyRegionSourceToken>
    private let normalizationPolicy: ScreenDirtyRegionNormalizationPolicy
    private let heartbeatInterval: DispatchTimeInterval
    private let maximumCoverageSilenceNs: UInt64

    private var lifecycle: Lifecycle = .idle
    private var emitter: SceneSourceEmitter?
    private var captureSession: (any ScreenDirtyRegionCaptureSession)?
    private var activeCoordinateSnapshot: MacDesktopCoordinateSnapshot?
    private var heartbeat: ScreenDirtyRegionHeartbeat?
    private var mailboxWorker: ScreenDirtyRegionMailboxWorker?
    private var drainConsumer: Task<Void, Never>?
    private var dirtyRevisions: [SourceObjectID: UInt64] = [:]
    private var unavailable: ScreenDirtyRegionUnavailability?

    public init(
        device: DevicePrincipalID,
        sessionID: SceneSessionID,
        coordinateRegistry: MacDesktopCoordinateRegistry,
        sourceID: SceneSourceID = SceneSourceID(
            rawValue: UUID(uuidString: "4D505343-5343-5245-454E-444952545901")!
        ),
        mailboxCapacity: Int = 8,
        normalizationPolicy: ScreenDirtyRegionNormalizationPolicy = .default,
        heartbeatInterval: DispatchTimeInterval = .seconds(5),
        maximumCoverageSilenceNs: UInt64 = 15_000_000_000,
        clock: any SceneSourceMonotonicClock = SystemSceneSourceMonotonicClock()
    ) throws {
        try self.init(
            device: device,
            sessionID: sessionID,
            coordinateRegistry: coordinateRegistry,
            sourceID: sourceID,
            mailboxCapacity: mailboxCapacity,
            normalizationPolicy: normalizationPolicy,
            heartbeatInterval: heartbeatInterval,
            maximumCoverageSilenceNs: maximumCoverageSilenceNs,
            clock: clock,
            captureProvider: SystemScreenDirtyRegionCaptureProvider()
        )
    }

    init(
        device: DevicePrincipalID,
        sessionID: SceneSessionID,
        coordinateRegistry: MacDesktopCoordinateRegistry,
        sourceID: SceneSourceID = SceneSourceID(),
        mailboxCapacity: Int = 8,
        normalizationPolicy: ScreenDirtyRegionNormalizationPolicy = .default,
        heartbeatInterval: DispatchTimeInterval = .seconds(5),
        maximumCoverageSilenceNs: UInt64 = 15_000_000_000,
        clock: any SceneSourceMonotonicClock = SystemSceneSourceMonotonicClock(),
        captureProvider: any ScreenDirtyRegionCaptureProviding
    ) throws {
        guard coordinateRegistry.device == device else {
            throw ScreenDirtyRegionSceneSourceError.coordinateRegistryDeviceMismatch
        }
        let sourceEpoch = SceneSourceEpoch(
            source: SceneSourceIdentity(device: device, source: sourceID)
        )
        self.manifest = try SceneSourceManifest(
            sourceEpoch: sourceEpoch,
            sessionID: sessionID,
            displayName: "macOS screen dirty-region metadata",
            kind: .screenPixels,
            capabilities: [
                .dirtyRegions,
                .coverageReporting,
                .onDemandRefresh,
                .checkpoints,
            ]
        )
        self.coordinateRegistry = coordinateRegistry
        self.captureProvider = captureProvider
        self.clock = clock
        self.mailbox = BoundedSceneTokenMailbox(capacity: mailboxCapacity)
        self.normalizationPolicy = normalizationPolicy
        self.heartbeatInterval = Self.rateLimitedHeartbeatInterval(heartbeatInterval)
        self.maximumCoverageSilenceNs = maximumCoverageSilenceNs
    }

    public func start(
        handle: SceneSourceHandle,
        sink: any SceneEventSink
    ) async throws {
        switch lifecycle {
        case .idle:
            break
        case .starting, .running, .stopping:
            throw ScreenDirtyRegionSceneSourceError.alreadyStarted
        case .stopped:
            throw ScreenDirtyRegionSceneSourceError.stopped
        }
        guard handle.sourceEpoch == manifest.sourceEpoch,
              handle.sessionID == manifest.sessionID
        else {
            throw ScreenDirtyRegionSceneSourceError.sourceHandleMismatch
        }

        lifecycle = .starting
        let emitter = try SceneSourceEmitter(
            sourceEpoch: manifest.sourceEpoch,
            handle: handle,
            sink: sink,
            clock: clock
        )
        self.emitter = emitter

        do {
            heartbeat = ScreenDirtyRegionHeartbeat(
                mailbox: mailbox,
                interval: heartbeatInterval
            )
            let mailboxWorker = ScreenDirtyRegionMailboxWorker(mailbox: mailbox)
            self.mailboxWorker = mailboxWorker
            drainConsumer = Task(priority: .utility) { [weak self, mailboxWorker] in
                for await work in mailboxWorker.drains {
                    await self?.process(work.drain)
                    work.acknowledge()
                }
            }

            // A denied preflight cannot substantiate screen-pixel evidence. Publish
            // an empty baseline, then the explicit permission-loss invalidation/gap.
            let initialPermission = captureProvider.hasScreenRecordingPermission()
            let initialSnapshot = initialPermission ? coordinateRegistry.snapshot() : nil
            try ensureAccepted(try await emitCheckpoint(using: initialSnapshot))
            try ensureAccepted(await emitter.beginBestEffortCoverage(
                scope: .sourceProjection(manifest.sourceEpoch),
                maximumSilenceNs: maximumCoverageSilenceNs
            ))
            guard case .starting = lifecycle else {
                throw ScreenDirtyRegionSceneSourceError.stopped
            }
            lifecycle = .running
            await activateInitialCapture(
                using: initialSnapshot,
                permissionGranted: initialPermission,
                emitter: emitter
            )
            guard case .running = lifecycle else {
                throw ScreenDirtyRegionSceneSourceError.stopped
            }
            // Capture callbacks may begin before `startCapture` returns. Keep them in
            // the bounded mailbox until the session and coordinate snapshot have been
            // committed, then start the sole consumer. Overflow remains an explicit
            // recovery fact rather than silently dropping a pre-commit frame.
            mailboxWorker.start()
        } catch {
            // `stop()` may have cleared `self.emitter` while one of the startup
            // publications was suspended. The local emitter still owns any coverage
            // lease opened after that cleanup, so close it before tearing down the
            // remaining producer state. Querying the emitter makes this idempotent
            // with a concurrent stop that already ended the same lease.
            if await emitter.hasOpenCoverageStream() {
                _ = try? await emitter.endCoverage(.producerPaused)
            }
            await shutDownProducer(endCoverage: false)
            lifecycle = .stopped
            throw error
        }
    }

    public func refresh(_ request: RefreshRequest) async -> RefreshDisposition {
        guard lifecycle == .running,
              request.sessionID == manifest.sessionID
        else {
            return .rejected
        }
        switch request.scope {
        case let .sourceProjection(source) where source != manifest.sourceEpoch:
            return .unsupported
        case let .object(object) where object.sourceEpoch != manifest.sourceEpoch:
            return .unsupported
        case let .surface(surface)
            where surface.device != manifest.sourceEpoch.source.device:
            return .unsupported
        case let .region(region)
            where region.coordinateSpace.surface.device != manifest.sourceEpoch.source.device:
            return .unsupported
        default:
            break
        }
        _ = mailbox.offer(.explicitRefresh)
        return .accepted
    }

    public func stop() async {
        switch lifecycle {
        case .starting, .running:
            break
        case .idle, .stopping, .stopped:
            return
        }
        lifecycle = .stopping
        await shutDownProducer(endCoverage: true)
        lifecycle = .stopped
    }

    private func process(
        _ drain: SceneTokenMailboxDrain<ScreenDirtyRegionSourceToken>
    ) async {
        guard lifecycle == .running, let emitter else { return }

        if drain.overflowed {
            await breakAndRecover(
                gap: .sourceBackpressure,
                invalidationReason: .coverageGap,
                emitter: emitter
            )
            return
        }

        for token in drain.tokens {
            guard lifecycle == .running else { return }
            switch token {
            case let .frame(frame):
                do {
                    try await emitDirtyFrame(frame, emitter: emitter)
                } catch {
                    let topologyChanged = coordinateRegistry.snapshot()?.topologyRevision !=
                        activeCoordinateSnapshot?.topologyRevision
                    await breakAndRecover(
                        gap: topologyChanged ? .sourceRestarted : .sourceBackpressure,
                        invalidationReason: topologyChanged
                            ? .geometryChanged
                            : .coverageGap,
                        emitter: emitter,
                        retryImmediately: topologyChanged
                    )
                    return
                }
            case .streamStopped:
                let permission = captureProvider.hasScreenRecordingPermission()
                await breakAndRecover(
                    gap: permission ? .unknown : .permissionLost,
                    invalidationReason: permission ? .unknown : .permissionChanged,
                    emitter: emitter,
                    retryImmediately: false
                )
                return
            case .explicitRefresh:
                await breakAndRecover(
                    gap: .producerPaused,
                    invalidationReason: .unknown,
                    emitter: emitter,
                    retryImmediately: true
                )
                return
            case .heartbeat:
                if let activeCoordinateSnapshot {
                    let currentRevision = coordinateRegistry.snapshot()?.topologyRevision
                    if currentRevision != activeCoordinateSnapshot.topologyRevision {
                        await breakAndRecover(
                            gap: .sourceRestarted,
                            invalidationReason: .geometryChanged,
                            emitter: emitter,
                            retryImmediately: true
                        )
                        return
                    }
                    if await emitter.hasActiveCoverage() {
                        _ = try? await emitter.heartbeatCoverage()
                    }
                } else {
                    switch unavailable {
                    case .topologyUnavailable, .captureFailed:
                        await attemptResynchronization(emitter: emitter)
                    case .permissionDenied, .none:
                        break
                    }
                }
            }
        }
    }

    private func activateInitialCapture(
        using snapshot: MacDesktopCoordinateSnapshot?,
        permissionGranted: Bool,
        emitter: SceneSourceEmitter
    ) async {
        guard lifecycle == .running else { return }
        guard permissionGranted else {
            unavailable = .permissionDenied
            await publishLoss(
                gap: .permissionLost,
                invalidationReason: .permissionChanged,
                emitter: emitter
            )
            return
        }
        guard let snapshot else {
            unavailable = .topologyUnavailable
            await publishLoss(
                gap: .unknown,
                invalidationReason: .geometryChanged,
                emitter: emitter
            )
            return
        }

        do {
            try await startAndCommitCapture(
                using: snapshot,
                emitter: emitter,
                publishCheckpointAndCoverage: false
            )
        } catch {
            guard lifecycle == .running else { return }
            unavailable = captureProvider.hasScreenRecordingPermission()
                ? .captureFailed
                : .permissionDenied
            await publishLoss(
                gap: unavailable == .permissionDenied ? .permissionLost : .unknown,
                invalidationReason: unavailable == .permissionDenied
                    ? .permissionChanged
                    : .unknown,
                emitter: emitter
            )
        }
    }

    private func breakAndRecover(
        gap: CoverageGapReason,
        invalidationReason: SceneInvalidationReason,
        emitter: SceneSourceEmitter,
        retryImmediately: Bool = false
    ) async {
        if let captureSession {
            await captureSession.stop()
        }
        captureSession = nil
        activeCoordinateSnapshot = nil
        await publishLoss(
            gap: gap,
            invalidationReason: invalidationReason,
            emitter: emitter
        )
        unavailable = captureProvider.hasScreenRecordingPermission()
            ? (coordinateRegistry.snapshot() == nil
                ? .topologyUnavailable
                : .captureFailed)
            : .permissionDenied
        if retryImmediately {
            await attemptResynchronization(emitter: emitter)
        }
    }

    private func publishLoss(
        gap: CoverageGapReason,
        invalidationReason: SceneInvalidationReason,
        emitter: SceneSourceEmitter
    ) async {
        if await emitter.hasActiveCoverage() {
            _ = try? await emitter.gapCoverage(gap)
        }
        let invalidation = try? SceneInvalidation(
            scope: .sourceProjection(manifest.sourceEpoch),
            fields: [MacSceneSourceSchema.screenDirtyRevisionField],
            reason: invalidationReason,
            observedAtSourceMonotonicNs: clock.nowNanoseconds()
        )
        if let invalidation {
            _ = try? await emitter.emit(.invalidation(invalidation))
        }
    }

    private func attemptResynchronization(emitter: SceneSourceEmitter) async {
        guard lifecycle == .running else { return }
        if let captureSession {
            await captureSession.stop()
        }
        captureSession = nil
        activeCoordinateSnapshot = nil

        if await emitter.hasOpenCoverageStream() {
            _ = try? await emitter.endCoverage(.producerPaused)
        }

        guard captureProvider.hasScreenRecordingPermission() else {
            unavailable = .permissionDenied
            return
        }
        guard let snapshot = coordinateRegistry.snapshot() else {
            unavailable = .topologyUnavailable
            return
        }

        do {
            try await startAndCommitCapture(
                using: snapshot,
                emitter: emitter,
                publishCheckpointAndCoverage: true
            )
        } catch {
            guard lifecycle == .running else { return }
            unavailable = captureProvider.hasScreenRecordingPermission()
                ? .captureFailed
                : .permissionDenied
        }
    }

    /// A newly created capture session remains local ownership until every required
    /// sink publication is accepted. Any error, rejection, cancellation, or lifecycle
    /// race stops that uncommitted session before the error leaves this helper.
    private func startAndCommitCapture(
        using snapshot: MacDesktopCoordinateSnapshot,
        emitter: SceneSourceEmitter,
        publishCheckpointAndCoverage: Bool
    ) async throws {
        let session = try await captureProvider.startCapture(
            coordinateSnapshot: snapshot,
            mailbox: mailbox,
            maximumRectsPerFrame: normalizationPolicy.maximumInputRects
        )

        do {
            guard case .running = lifecycle, !Task.isCancelled else {
                throw ScreenDirtyRegionSceneSourceError.stopped
            }
            if publishCheckpointAndCoverage {
                try ensureAccepted(try await emitCheckpoint(using: snapshot))
                guard case .running = lifecycle, !Task.isCancelled else {
                    throw ScreenDirtyRegionSceneSourceError.stopped
                }
                try ensureAccepted(await emitter.beginBestEffortCoverage(
                    scope: .sourceProjection(manifest.sourceEpoch),
                    maximumSilenceNs: maximumCoverageSilenceNs
                ))
                guard case .running = lifecycle, !Task.isCancelled else {
                    throw ScreenDirtyRegionSceneSourceError.stopped
                }
            }

            captureSession = session
            activeCoordinateSnapshot = snapshot
            unavailable = nil
        } catch {
            await session.stop()
            throw error
        }
    }

    private func emitDirtyFrame(
        _ frame: ScreenDirtyRegionFrame,
        emitter: SceneSourceEmitter
    ) async throws {
        guard let snapshot = activeCoordinateSnapshot else { return }
        guard coordinateRegistry.snapshot()?.topologyRevision == frame.topologyRevision else {
            throw ScreenDirtyRegionNormalizationError.coordinateRevisionMismatch(
                expected: coordinateRegistry.snapshot()?.topologyRevision ?? 0,
                actual: frame.topologyRevision
            )
        }
        let result = try ScreenDirtyRegionNormalizer.normalize(
            frame,
            through: snapshot,
            policy: normalizationPolicy
        )
        guard !result.regions.isEmpty,
              let mapping = snapshot.displayMappings.first(where: {
                  $0.display.displayID == frame.displayID
              })
        else {
            return
        }
        let object = sentinelObject(for: mapping)
        let priorRevision = dirtyRevisions[object.objectID, default: 0]
        guard priorRevision < UInt64.max else {
            throw ScreenDirtyRegionSceneSourceError.dirtyRevisionExhausted
        }
        let nextRevision = priorRevision + 1
        let observedAt = clock.nowNanoseconds()
        var payloads = try result.regions.map { region in
            SceneEventPayload.invalidation(try SceneInvalidation(
                scope: .region(region),
                fields: [MacSceneSourceSchema.screenDirtyRevisionField],
                reason: .contentDirty,
                observedAtSourceMonotonicNs: observedAt
            ))
        }
        payloads.append(.observation(try sentinelObservation(
            mapping: mapping,
            snapshot: snapshot,
            dirtyRevision: nextRevision,
            observedAt: observedAt
        )))
        try ensureAccepted(try await emitter.emit(payloads))
        dirtyRevisions[object.objectID] = nextRevision
    }

    private func emitCheckpoint(
        using snapshot: MacDesktopCoordinateSnapshot?
    ) async throws -> IngestReceipt {
        guard let emitter else { throw ScreenDirtyRegionSceneSourceError.stopped }
        let observedAt = clock.nowNanoseconds()
        let reconciledRevisions = reconciledDirtyRevisions(using: snapshot)
        let observations: [SceneObservation]
        if let snapshot {
            observations = try snapshot.displayMappings.map { mapping in
                let object = sentinelObject(for: mapping)
                return try sentinelObservation(
                    mapping: mapping,
                    snapshot: snapshot,
                    dirtyRevision: reconciledRevisions[object.objectID, default: 0],
                    observedAt: observedAt
                )
            }
        } else {
            observations = []
        }
        let checkpoint = try SceneCheckpoint(observations: observations)

        // The ledger is exactly the projection represented by this checkpoint.
        // Existing display sentinels retain their revision; removed or replaced
        // fallback surfaces are dropped, and newly observed sentinels begin at zero.
        // Stage before the await so readers cannot observe an accepted checkpoint
        // paired with the preceding topology, but roll back a rejected emission.
        let precedingRevisions = dirtyRevisions
        dirtyRevisions = reconciledRevisions
        do {
            let receipt = try await emitter.emit(.checkpoint(checkpoint))
            if receipt.status == .rejected {
                dirtyRevisions = precedingRevisions
            }
            return receipt
        } catch {
            dirtyRevisions = precedingRevisions
            throw error
        }
    }

    private func reconciledDirtyRevisions(
        using snapshot: MacDesktopCoordinateSnapshot?
    ) -> [SourceObjectID: UInt64] {
        guard let snapshot else { return [:] }
        var current: [SourceObjectID: UInt64] = [:]
        current.reserveCapacity(snapshot.displayMappings.count)
        for mapping in snapshot.displayMappings {
            let objectID = sentinelObject(for: mapping).objectID
            current[objectID] = dirtyRevisions[objectID, default: 0]
        }
        return current
    }

    /// Bounded state exposed to diagnostics and focused source tests. This contains
    /// exactly one entry per sentinel in the most recently emitted checkpoint.
    func dirtyRevisionStateForDiagnostics() -> [SourceObjectID: UInt64] {
        dirtyRevisions
    }

    private func sentinelObject(
        for mapping: MacDesktopCoordinateMapper.DisplayMapping
    ) -> SourceObjectKey {
        SourceObjectKey(
            sourceEpoch: manifest.sourceEpoch,
            objectID: SceneStableIdentifiers.screenDirtySentinel(
                surface: mapping.surface,
                device: manifest.sourceEpoch.source.device
            )
        )
    }

    private func sentinelObservation(
        mapping: MacDesktopCoordinateMapper.DisplayMapping,
        snapshot: MacDesktopCoordinateSnapshot,
        dirtyRevision: UInt64,
        observedAt: UInt64
    ) throws -> SceneObservation {
        guard let bounds = snapshot.mapQuartzGlobalRect(mapping.display.globalBounds) else {
            throw ScreenDirtyRegionNormalizationError.unknownDisplay(
                mapping.display.displayID
            )
        }
        let evidence = [try SceneEvidence(kind: .screenPixels)]
        func claim(
            _ field: SceneFieldKey,
            _ value: SceneFieldValue
        ) throws -> SceneFieldClaim {
            try SceneFieldClaim(
                field: field,
                value: value,
                knowledge: .observed,
                confidence: 1,
                sensitivity: .ordinary,
                evidence: evidence
            )
        }
        return try SceneObservation(
            subject: sentinelObject(for: mapping),
            observedAtSourceMonotonicNs: observedAt,
            claims: [
                try claim(MacSceneSourceSchema.objectKindField, .text("screenDirtySentinel")),
                try claim(
                    MacSceneSourceSchema.screenDirtyDisplayBoundsField,
                    .region(bounds)
                ),
                try claim(
                    MacSceneSourceSchema.displayIDField,
                    .unsignedInteger(UInt64(mapping.display.displayID))
                ),
                try claim(
                    MacSceneSourceSchema.screenDirtyRevisionField,
                    .unsignedInteger(dirtyRevision)
                ),
            ]
        )
    }

    private func ensureAccepted(_ receipt: IngestReceipt) throws {
        guard receipt.status != .rejected else {
            throw ScreenDirtyRegionSceneSourceError.sinkRejected(receipt.rejection)
        }
    }

    /// Capture failures retry no faster than five seconds in production. Tests may
    /// choose a slower interval, but cannot accidentally create a hot restart loop.
    private static func rateLimitedHeartbeatInterval(
        _ interval: DispatchTimeInterval
    ) -> DispatchTimeInterval {
        switch interval {
        case let .seconds(value):
            return .seconds(max(5, value))
        case let .milliseconds(value):
            return value >= 5_000 ? interval : .seconds(5)
        case let .microseconds(value):
            return value >= 5_000_000 ? interval : .seconds(5)
        case let .nanoseconds(value):
            return value >= 5_000_000_000 ? interval : .seconds(5)
        case .never:
            return .seconds(5)
        @unknown default:
            return .seconds(5)
        }
    }

    private func shutDownProducer(endCoverage: Bool) async {
        heartbeat?.stop()
        heartbeat = nil
        mailboxWorker?.stop()
        if let captureSession {
            await captureSession.stop()
        }
        captureSession = nil
        activeCoordinateSnapshot = nil
        if let drainConsumer { await drainConsumer.value }
        self.drainConsumer = nil
        mailboxWorker = nil
        if endCoverage, let emitter, await emitter.hasOpenCoverageStream() {
            _ = try? await emitter.endCoverage(.producerPaused)
        }
        emitter = nil
    }
}

struct ScreenDirtyRegionMailboxWork: @unchecked Sendable {
    let drain: SceneTokenMailboxDrain<ScreenDirtyRegionSourceToken>
    private let acknowledgement = DispatchSemaphore(value: 0)

    init(drain: SceneTokenMailboxDrain<ScreenDirtyRegionSourceToken>) {
        self.drain = drain
    }

    func acknowledge() { acknowledgement.signal() }
    fileprivate func waitForAcknowledgement() { acknowledgement.wait() }
}

/// The mailbox wait is intentionally performed on an owned utility Thread, never on
/// Swift's cooperative executor. The thread waits for each drain to be acknowledged,
/// so at most one bounded drain can be in flight and no Task is created per callback.
private final class ScreenDirtyRegionMailboxWorker: @unchecked Sendable {
    let drains: AsyncStream<ScreenDirtyRegionMailboxWork>

    private let mailbox: BoundedSceneTokenMailbox<ScreenDirtyRegionSourceToken>
    private let continuation: AsyncStream<ScreenDirtyRegionMailboxWork>.Continuation
    private let thread: Thread
    private let lock = NSLock()
    private var started = false
    private var stopped = false

    init(mailbox: BoundedSceneTokenMailbox<ScreenDirtyRegionSourceToken>) {
        self.mailbox = mailbox
        var continuation: AsyncStream<ScreenDirtyRegionMailboxWork>.Continuation!
        self.drains = AsyncStream(bufferingPolicy: .bufferingOldest(1)) {
            continuation = $0
        }
        self.continuation = continuation
        let runner = ScreenDirtyRegionMailboxThreadRunner(
            mailbox: mailbox,
            continuation: continuation
        )
        self.thread = Thread { runner.run() }
        self.thread.name = "PointerMagic.ScreenDirtyRegionMailbox"
        self.thread.qualityOfService = .utility
    }

    func start() {
        lock.lock()
        guard !started, !stopped else {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()
        thread.start()
    }

    func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        let didStart = started
        lock.unlock()
        mailbox.close()
        if !didStart { continuation.finish() }
    }
}

private final class ScreenDirtyRegionMailboxThreadRunner: @unchecked Sendable {
    private let mailbox: BoundedSceneTokenMailbox<ScreenDirtyRegionSourceToken>
    private let continuation: AsyncStream<ScreenDirtyRegionMailboxWork>.Continuation

    init(
        mailbox: BoundedSceneTokenMailbox<ScreenDirtyRegionSourceToken>,
        continuation: AsyncStream<ScreenDirtyRegionMailboxWork>.Continuation
    ) {
        self.mailbox = mailbox
        self.continuation = continuation
    }

    func run() {
        while true {
            switch mailbox.waitAndDrain() {
            case .closed:
                continuation.finish()
                return
            case let .drained(drain):
                let work = ScreenDirtyRegionMailboxWork(drain: drain)
                switch continuation.yield(work) {
                case .enqueued:
                    work.waitForAcknowledgement()
                case .dropped:
                    // One-at-a-time acknowledgement makes this unreachable, but a
                    // defensive stop still prevents silently dropping metadata.
                    mailbox.close()
                case .terminated:
                    mailbox.close()
                    return
                @unknown default:
                    mailbox.close()
                    return
                }
            }
        }
    }
}

private final class ScreenDirtyRegionHeartbeat: @unchecked Sendable {
    private let timer: DispatchSourceTimer
    private let lock = NSLock()
    private var stopped = false

    init(
        mailbox: BoundedSceneTokenMailbox<ScreenDirtyRegionSourceToken>,
        interval: DispatchTimeInterval
    ) {
        timer = DispatchSource.makeTimerSource(
            flags: [],
            queue: DispatchQueue(
                label: "pointer-magic.screen-dirty.heartbeat",
                qos: .utility
            )
        )
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { mailbox.offer(.heartbeat) }
        timer.resume()
    }

    func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        lock.unlock()
        timer.setEventHandler {}
        timer.cancel()
    }
}

struct SystemScreenDirtyRegionCaptureProvider: ScreenDirtyRegionCaptureProviding {
    private let processID: Int32

    init(processID: Int32 = ProcessInfo.processInfo.processIdentifier) {
        self.processID = processID
    }

    func hasScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    func startCapture(
        coordinateSnapshot: MacDesktopCoordinateSnapshot,
        mailbox: BoundedSceneTokenMailbox<ScreenDirtyRegionSourceToken>,
        maximumRectsPerFrame: Int
    ) async throws -> any ScreenDirtyRegionCaptureSession {
        // `current` is called only after preflight succeeds. This source never invokes
        // a permission-requesting API and therefore never creates a permission prompt.
        let content = try await SCShareableContent.current
        let displays = Dictionary(
            uniqueKeysWithValues: content.displays.map { ($0.displayID, $0) }
        )
        let outputQueue = DispatchQueue(
            label: "pointer-magic.screen-dirty.frame-metadata",
            qos: .utility
        )
        var records: [SystemScreenDirtyRegionCaptureSession.Record] = []

        do {
            for mapping in coordinateSnapshot.displayMappings {
                let displayID = mapping.display.displayID
                guard let display = displays[displayID] else {
                    throw ScreenDirtyRegionNormalizationError.unknownDisplay(displayID)
                }
                let width = max(1, Int(ceil(mapping.display.globalBounds.width)))
                let height = max(1, Int(ceil(mapping.display.globalBounds.height)))
                let configuration = SCStreamConfiguration()
                configuration.width = width
                configuration.height = height
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 2)
                configuration.queueDepth = 1
                configuration.showsCursor = false
                configuration.capturesAudio = false
                configuration.scalesToFit = true
                configuration.preservesAspectRatio = true
                configuration.captureResolution = .nominal
                configuration.streamName = "Pointer Magic dirty-region metadata"

                let excludedApplications = content.applications.filter {
                    ScreenDirtyRegionFilterPolicy.excludes(
                        applicationProcessID: $0.processID,
                        sourceProcessID: processID
                    )
                }
                // The excluding-applications display filter keeps the desktop and
                // Dock while preventing Halo's own overlay from feeding a dirty loop.
                let filter = SCContentFilter(
                    display: display,
                    excludingApplications: excludedApplications,
                    exceptingWindows: []
                )
                let bridge = ScreenDirtyRegionStreamBridge(
                    displayID: displayID,
                    topologyRevision: coordinateSnapshot.topologyRevision,
                    outputWidth: width,
                    outputHeight: height,
                    maximumRectsPerFrame: maximumRectsPerFrame,
                    mailbox: mailbox
                )
                let stream = SCStream(
                    filter: filter,
                    configuration: configuration,
                    delegate: bridge
                )
                try stream.addStreamOutput(
                    bridge,
                    type: .screen,
                    sampleHandlerQueue: outputQueue
                )
                let record = SystemScreenDirtyRegionCaptureSession.Record(
                    stream: stream,
                    bridge: bridge
                )
                records.append(record)
                try await stream.startCapture()
            }
        } catch {
            let partial = SystemScreenDirtyRegionCaptureSession(records: records)
            await partial.stop()
            throw error
        }
        return SystemScreenDirtyRegionCaptureSession(records: records)
    }
}

enum ScreenDirtyRegionFilterPolicy {
    static func excludes(
        applicationProcessID: Int32,
        sourceProcessID: Int32
    ) -> Bool {
        applicationProcessID == sourceProcessID
    }
}

private final class SystemScreenDirtyRegionCaptureSession:
    ScreenDirtyRegionCaptureSession,
    @unchecked Sendable
{
    struct Record: @unchecked Sendable {
        let stream: SCStream
        let bridge: ScreenDirtyRegionStreamBridge
    }

    private let lock = NSLock()
    private var records: [Record]

    init(records: [Record]) {
        self.records = records
    }

    func stop() async {
        let current = takeRecords()
        for record in current {
            record.bridge.deactivate()
        }
        for record in current {
            try? await record.stream.stopCapture()
        }
    }

    private func takeRecords() -> [Record] {
        lock.lock()
        let current = records
        records.removeAll(keepingCapacity: false)
        lock.unlock()
        return current
    }
}

/// ScreenCaptureKit delegate/output callbacks only copy bounded attachment metadata
/// into the mailbox. They never call the scene sink, create a Task, log, or touch the
/// frame's image buffer.
private final class ScreenDirtyRegionStreamBridge: NSObject, SCStreamOutput,
    SCStreamDelegate, @unchecked Sendable
{
    private let displayID: UInt32
    private let topologyRevision: UInt64
    private let outputWidth: Int
    private let outputHeight: Int
    private let maximumRectsPerFrame: Int
    private let mailbox: BoundedSceneTokenMailbox<ScreenDirtyRegionSourceToken>
    private let lock = NSLock()
    private var active = true

    init(
        displayID: UInt32,
        topologyRevision: UInt64,
        outputWidth: Int,
        outputHeight: Int,
        maximumRectsPerFrame: Int,
        mailbox: BoundedSceneTokenMailbox<ScreenDirtyRegionSourceToken>
    ) {
        self.displayID = displayID
        self.topologyRevision = topologyRevision
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.maximumRectsPerFrame = ScreenDirtyRegionCallbackBudget
            .clampedMaximumRectsPerFrame(maximumRectsPerFrame)
        self.mailbox = mailbox
    }

    func stream(
        _: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen, isActive else { return }
        guard let attachmentArray = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
            let attachment = attachmentArray.first,
            let statusValue = attachment[.status] as? Int,
            SCFrameStatus(rawValue: statusValue) == .complete,
            let values = attachment[.dirtyRects] as? [CGRect],
            !values.isEmpty
        else {
            return
        }

        let acceptedCount = min(values.count, maximumRectsPerFrame)
        var rects: [ScreenDirtyPixelRect] = []
        rects.reserveCapacity(acceptedCount)
        for rect in values.prefix(acceptedCount) {
            if let value = ScreenDirtyPixelRect(
                x: Double(rect.origin.x),
                y: Double(rect.origin.y),
                width: Double(rect.width),
                height: Double(rect.height)
            ) {
                rects.append(value)
            }
        }
        mailbox.offer(.frame(ScreenDirtyRegionFrame(
            displayID: displayID,
            topologyRevision: topologyRevision,
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            dirtyRects: rects,
            didTruncateInput: values.count > maximumRectsPerFrame ||
                rects.count != acceptedCount
        )))
    }

    func stream(_: SCStream, didStopWithError _: any Error) {
        guard isActive else { return }
        mailbox.offer(.streamStopped(displayID: displayID))
    }

    func deactivate() {
        lock.lock()
        active = false
        lock.unlock()
    }

    private var isActive: Bool {
        lock.lock()
        let result = active
        lock.unlock()
        return result
    }
}

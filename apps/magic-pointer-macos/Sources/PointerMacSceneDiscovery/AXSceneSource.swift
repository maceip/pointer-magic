@preconcurrency import AppKit
@preconcurrency import ApplicationServices
import Dispatch
import Foundation
import PointerSceneContracts

public enum AXSceneSourceError: Error, Equatable, Sendable {
    case alreadyStarted
    case stopped
    case sourceHandleMismatch
    case coordinateRegistryDeviceMismatch
    case sinkRejected(IngestRejectionCode?)
}

private enum AXSourcePauseReason: Hashable, Sendable {
    case systemSleeping
    case inactiveSession
}

struct AXSceneProcessResult: Sendable {
    var gapReason: CoverageGapReason?
    var restartCoverage = false
    var invalidations: [SceneInvalidation] = []
    var observations: [SceneObservation] = []
    var checkpoint: SceneCheckpoint?
    var heartbeatRequested = false
}

/// A full mailbox drain can yield both an invalidation and an observation per
/// token. Keep the existing invalidation-then-observation order while splitting
/// emission at the contracts package's event-batch ceiling.
enum AXScenePayloadBatching {
    static let maximumEventsPerBatch = SceneContractLimits.eventsPerBatch

    static func batches(for result: AXSceneProcessResult) -> [[SceneEventPayload]] {
        var payloads = result.invalidations.map(SceneEventPayload.invalidation)
        payloads.append(contentsOf: result.observations.map(SceneEventPayload.observation))
        guard !payloads.isEmpty else { return [] }

        var batches: [[SceneEventPayload]] = []
        batches.reserveCapacity(
            (payloads.count + maximumEventsPerBatch - 1) / maximumEventsPerBatch
        )
        var start = 0
        while start < payloads.count {
            let end = min(start + maximumEventsPerBatch, payloads.count)
            batches.append(Array(payloads[start ..< end]))
            start = end
        }
        return batches
    }
}

/// A single incremental AX scan can consume its full 750 ms deadline. Decide
/// before scanning whether a drain is still small enough for targeted work;
/// larger bursts collapse to one bounded projection resynchronization.
enum AXNotificationDrainScanPolicy {
    static let maximumIncrementalElementScans = 4

    static func requiresFullResynchronization<S: Sequence>(
        for tokens: S
    ) -> Bool where S.Element == AXSceneWorkToken {
        var incrementalElementScans = 0
        for token in tokens {
            guard case let .notification(_, kind, _) = token else { continue }
            if kind.requiresHierarchyRescan { return true }
            if kind == .elementDestroyed { continue }
            incrementalElementScans += 1
            if incrementalElementScans > maximumIncrementalElementScans {
                return true
            }
        }
        return false
    }
}

private final class AXTrackedApplicationStore: @unchecked Sendable {
    private let lock = NSLock()
    private var processIDs: Set<Int32> = []

    func replace(with processIDs: Set<Int32>) {
        lock.lock()
        self.processIDs = Set(processIDs.filter { $0 > 0 }.sorted().prefix(8))
        lock.unlock()
    }

    func snapshot() -> Set<Int32> {
        lock.lock()
        let result = processIDs
        lock.unlock()
        return result
    }
}

/// Worker-owned state. Every AX read and identity-table access happens serially
/// on the owned utility scan thread, never on the observer run loop, source
/// actor, event tap, main actor, or live semantic resolver queue.
private final class AXSceneScanRuntime: @unchecked Sendable {
    private let sourceEpoch: SceneSourceEpoch
    private let device: DevicePrincipalID
    private let clock: any SceneSourceMonotonicClock
    private let censusProvider: any MacDesktopCensusProviding
    private let coordinateRegistry: MacDesktopCoordinateRegistry
    private let trackedApplications: AXTrackedApplicationStore
    private let observerThread: AXObserverThread
    private let scanner: AXShallowScanner
    private let registry = AXSceneIdentityRegistry()
    private var currentCoordinateSnapshot: MacDesktopCoordinateSnapshot?
    private var observationsByObject: [SourceObjectID: SceneObservation] = [:]
    private var currentProcessIDs: Set<Int32> = []
    private var pauseReasons: Set<AXSourcePauseReason> = []
    private var lastPermissionTrusted: Bool?

    init(
        device: DevicePrincipalID,
        sourceEpoch: SceneSourceEpoch,
        clock: any SceneSourceMonotonicClock,
        censusProvider: any MacDesktopCensusProviding,
        coordinateRegistry: MacDesktopCoordinateRegistry,
        trackedApplications: AXTrackedApplicationStore,
        observerThread: AXObserverThread,
        maximumDepth: Int,
        maximumObjects: Int
    ) {
        self.device = device
        self.sourceEpoch = sourceEpoch
        self.clock = clock
        self.censusProvider = censusProvider
        self.coordinateRegistry = coordinateRegistry
        self.trackedApplications = trackedApplications
        self.observerThread = observerThread
        self.scanner = AXShallowScanner(
            device: device,
            sourceEpoch: sourceEpoch,
            maximumDepth: maximumDepth,
            maximumObjects: maximumObjects
        )
    }

    func initialScan() -> AXSceneProcessResult {
        let trusted = AXIsProcessTrusted()
        lastPermissionTrusted = trusted
        guard trusted else {
            observerThread.replaceTrackedElements([])
            return permissionGap()
        }
        var result = fullResynchronization(restartCoverage: false)
        reconcileIdentityEvictions(into: &result)
        return result
    }

    func process(_ drain: SceneTokenMailboxDrain<AXSceneWorkToken>) -> AXSceneProcessResult {
        var result = AXSceneProcessResult()
        reconcileIdentityEvictions(into: &result)
        var requiresFullScan = drain.overflowed ||
            AXNotificationDrainScanPolicy.requiresFullResynchronization(
                for: drain.tokens
            )
        var notificationTokens: [(Int32, AXSceneNotificationKind, AXRetainedElement)] = []

        if drain.overflowed {
            result.gapReason = .sourceBackpressure
            result.restartCoverage = true
            result.invalidations.append(sourceInvalidation(
                reason: .coverageGap,
                observedAt: clock.nowNanoseconds()
            ))
        }

        for token in drain.tokens {
            switch token {
            case .systemWillSleep:
                pauseReasons.insert(.systemSleeping)
                result.gapReason = .deviceSleeping
            case .sessionDidResignActive:
                pauseReasons.insert(.inactiveSession)
                result.gapReason = .screenLocked
            case .systemDidWake:
                pauseReasons.remove(.systemSleeping)
                requiresFullScan = true
                result.restartCoverage = true
            case .sessionDidBecomeActive:
                pauseReasons.remove(.inactiveSession)
                requiresFullScan = true
                result.restartCoverage = true
            case .reconcileApplications, .explicitRefresh, .periodicRescan:
                requiresFullScan = true
            case .permissionStateChanged:
                requiresFullScan = true
            case .observerCoverageReduced:
                // Unsupported notifications retain honest best-effort coverage;
                // they never upgrade this source to complete-event coverage.
                result.heartbeatRequested = true
            case .heartbeat:
                result.heartbeatRequested = true
            case let .notification(processID, kind, element):
                notificationTokens.append((processID, kind, element))
                if kind.requiresHierarchyRescan { requiresFullScan = true }
            }
        }

        guard pauseReasons.isEmpty else {
            observerThread.replaceTrackedElements([])
            return result
        }

        let trusted = AXIsProcessTrusted()
        if trusted != lastPermissionTrusted {
            lastPermissionTrusted = trusted
            if trusted {
                requiresFullScan = true
                result.restartCoverage = true
            } else {
                observerThread.replaceTrackedElements([])
                observationsByObject.removeAll(keepingCapacity: false)
                currentProcessIDs.removeAll()
                let gap = permissionGap()
                result.gapReason = gap.gapReason
                result.invalidations.append(contentsOf: gap.invalidations)
                return result
            }
        }
        guard trusted else { return result }

        let observedAt = clock.nowNanoseconds()
        result.invalidations.append(contentsOf: notificationTokens.compactMap {
            invalidation(
                processID: $0.0,
                kind: $0.1,
                element: $0.2.rawValue,
                observedAt: observedAt
            )
        })

        if requiresFullScan {
            var resync = fullResynchronization(restartCoverage: result.restartCoverage)
            if resync.gapReason == nil { resync.gapReason = result.gapReason }
            if resync.checkpoint == nil { resync.restartCoverage = false }
            resync.invalidations = result.invalidations + resync.invalidations
            resync.heartbeatRequested = result.heartbeatRequested
            reconcileIdentityEvictions(into: &resync)
            return resync
        }

        // Reuse the registry's current immutable view so workspace and AX geometry
        // carry the exact same revision. A census is a scan-thread fallback only.
        let coordinateSnapshot = currentOrCaptureCoordinateSnapshot()
        currentCoordinateSnapshot = coordinateSnapshot
        for (processID, kind, retained) in notificationTokens {
            if kind == .elementDestroyed {
                if let removed = registry.remove(retained.rawValue, processID: processID) {
                    observationsByObject[removed] = nil
                }
                continue
            }
            let existingID = registry.existingObjectID(
                for: retained.rawValue,
                processID: processID
            )
            let parentID = existingID.flatMap {
                observationsByObject[$0]?.parent?.objectID
            }
            let parentSensitivity = parentID.flatMap { objectID in
                observationsByObject[objectID]?.claims.first(where: {
                    $0.field == AXSceneField.content
                })?.sensitivity
            }
            let scan = scanner.scanElement(
                retained.rawValue,
                processID: processID,
                parentObjectID: parentID,
                inheritedSensitivity: parentSensitivity,
                coordinateSnapshot: coordinateSnapshot,
                registry: registry,
                observedAt: observedAt
            )
            reconcileIdentityEvictions(into: &result)
            guard scan.permissionTrusted else {
                lastPermissionTrusted = false
                observerThread.replaceTrackedElements([])
                let gap = permissionGap()
                result.gapReason = gap.gapReason
                result.invalidations.append(contentsOf: gap.invalidations)
                result.observations.removeAll()
                return result
            }
            for observation in scan.observations {
                observationsByObject[observation.subject.objectID] = observation
                result.observations.append(observation)
            }
        }
        return result
    }

    private func reconcileIdentityEvictions(into result: inout AXSceneProcessResult) {
        let evicted = Set(registry.drainEvictedObjectIDs())
        guard !evicted.isEmpty else { return }
        discardCachedObservations(evicted)
        // A later token in the same drain may evict an identity referenced by an
        // earlier token. Do not publish events for identities no longer retained
        // by the source-local registry at drain completion.
        result.observations.removeAll {
            evicted.contains($0.subject.objectID)
        }
        result.invalidations.removeAll { invalidation in
            guard case let .object(object) = invalidation.scope else { return false }
            return evicted.contains(object.objectID)
        }
        if let checkpoint = result.checkpoint {
            result.checkpoint = try? SceneCheckpoint(
                observations: checkpoint.observations.filter {
                    !evicted.contains($0.subject.objectID)
                }
            )
        }
    }

    private func discardCachedObservations<S: Sequence>(_ objectIDs: S)
    where S.Element == SourceObjectID {
        for objectID in objectIDs {
            observationsByObject[objectID] = nil
        }
    }

    private func fullResynchronization(restartCoverage: Bool) -> AXSceneProcessResult {
        // A single census drives both process prioritization and a possible
        // coordinate seed. Workspace remains the normal registry writer; AX
        // writes only through seedIfEmpty when startup ordering leaves it empty.
        let census = try? censusProvider.capture()
        let processIDs: [Int32]
        if let census {
            processIDs = AXTargetProcessSelection.prioritized(
                census: census,
                explicitlyTrackedProcessIDs: trackedApplications.snapshot(),
                ownProcessID: Int32(ProcessInfo.processInfo.processIdentifier),
                maximumCount: 8
            )
        } else {
            // A failed census cannot safely identify newly visible or terminated
            // applications. Retain only still-running members of the last known
            // bounded target set until periodic reconciliation succeeds.
            processIDs = currentProcessIDs.filter { processID in
                guard let application = NSRunningApplication(
                    processIdentifier: pid_t(processID)
                ) else {
                    return false
                }
                return !application.isTerminated
            }.sorted()
        }
        for removedPID in currentProcessIDs.subtracting(processIDs) {
            discardCachedObservations(registry.removeAll(processID: removedPID))
        }
        currentProcessIDs = Set(processIDs)

        let observedAt = clock.nowNanoseconds()
        let coordinateSnapshot = currentOrSeedCoordinateSnapshot(from: census)
        currentCoordinateSnapshot = coordinateSnapshot
        let scan = scanner.scanApplications(
            processIDs: processIDs,
            coordinateSnapshot: coordinateSnapshot,
            registry: registry,
            observedAt: observedAt
        )
        lastPermissionTrusted = scan.permissionTrusted
        guard scan.permissionTrusted else {
            observerThread.replaceTrackedElements([])
            observationsByObject.removeAll(keepingCapacity: false)
            var result = permissionGap()
            result.restartCoverage = false
            return result
        }

        let checkpoint = try? SceneCheckpoint(observations: scan.observations)
        if checkpoint != nil {
            let retainedObjectIDs = Set(scan.observations.map(\.subject.objectID))
            discardCachedObservations(registry.removeIdentitiesOmitted(
                byCheckpointRetaining: retainedObjectIDs
            ))
        }
        observerThread.replaceTrackedElements(scan.observerElements)
        observationsByObject.removeAll(keepingCapacity: true)
        for observation in scan.observations {
            observationsByObject[observation.subject.objectID] = observation
        }
        return AXSceneProcessResult(
            gapReason: nil,
            restartCoverage: restartCoverage,
            invalidations: [],
            observations: [],
            checkpoint: checkpoint,
            heartbeatRequested: false
        )
    }

    private func currentOrSeedCoordinateSnapshot(
        from census: MacDesktopCensus?
    ) -> MacDesktopCoordinateSnapshot? {
        if let snapshot = coordinateRegistry.snapshot() { return snapshot }
        guard let census else { return nil }
        return try? coordinateRegistry.seedIfEmpty(with: census.displays)
    }

    private func currentOrCaptureCoordinateSnapshot() -> MacDesktopCoordinateSnapshot? {
        if let snapshot = coordinateRegistry.snapshot() { return snapshot }
        return currentOrSeedCoordinateSnapshot(from: try? censusProvider.capture())
    }

    private func invalidation(
        processID: Int32,
        kind: AXSceneNotificationKind,
        element: AXUIElement,
        observedAt: UInt64
    ) -> SceneInvalidation? {
        guard let objectID = registry.existingObjectID(
            for: element,
            processID: processID
        ) else {
            return kind.requiresHierarchyRescan
                ? sourceInvalidation(reason: kind.invalidationReason, observedAt: observedAt)
                : nil
        }
        return try? SceneInvalidation(
            scope: .object(SourceObjectKey(sourceEpoch: sourceEpoch, objectID: objectID)),
            fields: kind.invalidatedFields.isEmpty
                ? Array(MacSceneSourceSchema.accessibilityFields)
                : kind.invalidatedFields,
            reason: kind.invalidationReason,
            observedAtSourceMonotonicNs: observedAt
        )
    }

    private func permissionGap() -> AXSceneProcessResult {
        let observedAt = clock.nowNanoseconds()
        return AXSceneProcessResult(
            gapReason: .permissionLost,
            restartCoverage: false,
            invalidations: [sourceInvalidation(
                reason: .permissionChanged,
                observedAt: observedAt
            )],
            observations: [],
            checkpoint: nil,
            heartbeatRequested: false
        )
    }

    private func sourceInvalidation(
        reason: SceneInvalidationReason,
        observedAt: UInt64
    ) -> SceneInvalidation {
        try! SceneInvalidation(
            scope: .sourceProjection(sourceEpoch),
            fields: Array(MacSceneSourceSchema.accessibilityFields),
            reason: reason,
            observedAtSourceMonotonicNs: observedAt
        )
    }
}

/// Pins all proactive AX reads to one dedicated utility thread. Results are
/// acknowledged one at a time, so downstream ingestion cannot create an
/// unbounded queue; if it stalls, the input mailbox overflows explicitly and the
/// next scan becomes a coverage-gap checkpoint resynchronization.
final class AXSceneScanWorker: @unchecked Sendable {
    struct Output: Sendable {
        let ordinal: UInt64
        let result: AXSceneProcessResult
    }

    let outputs: AsyncStream<Output>

    private let mailbox: BoundedSceneTokenMailbox<AXSceneWorkToken>
    private let initialScan: @Sendable () -> AXSceneProcessResult
    private let process: @Sendable (
        SceneTokenMailboxDrain<AXSceneWorkToken>
    ) -> AXSceneProcessResult
    private let continuation: AsyncStream<Output>.Continuation
    private let condition = NSCondition()
    private var thread: Thread?
    private var nextOrdinal: UInt64 = 0
    private var acknowledgedOrdinal: UInt64 = 0
    private var initialOutput: Output?
    private var initialWasPublished = false
    private var initialWaiters: [CheckedContinuation<Output?, Never>] = []
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopping = false
    private var finished = false

    fileprivate init(
        mailbox: BoundedSceneTokenMailbox<AXSceneWorkToken>,
        runtime: AXSceneScanRuntime
    ) {
        self.mailbox = mailbox
        self.initialScan = { runtime.initialScan() }
        self.process = { runtime.process($0) }
        let pair = AsyncStream<Output>.makeStream(
            bufferingPolicy: .bufferingOldest(1)
        )
        self.outputs = pair.stream
        self.continuation = pair.continuation
    }

    init(
        mailbox: BoundedSceneTokenMailbox<AXSceneWorkToken>,
        initialScan: @escaping @Sendable () -> AXSceneProcessResult,
        process: @escaping @Sendable (
            SceneTokenMailboxDrain<AXSceneWorkToken>
        ) -> AXSceneProcessResult
    ) {
        self.mailbox = mailbox
        self.initialScan = initialScan
        self.process = process
        let pair = AsyncStream<Output>.makeStream(
            bufferingPolicy: .bufferingOldest(1)
        )
        self.outputs = pair.stream
        self.continuation = pair.continuation
    }

    func start() {
        condition.lock()
        guard thread == nil, !stopping, !finished else {
            condition.unlock()
            return
        }
        let thread = Thread { [weak self] in self?.threadMain() }
        thread.name = "MagicPointer.AXDiscoveryScan"
        thread.qualityOfService = .utility
        self.thread = thread
        thread.start()
        condition.unlock()
    }

    func acknowledge(_ ordinal: UInt64) {
        condition.lock()
        acknowledgedOrdinal = max(acknowledgedOrdinal, ordinal)
        if let initialOutput, acknowledgedOrdinal >= initialOutput.ordinal {
            self.initialOutput = nil
        }
        condition.broadcast()
        condition.unlock()
    }

    /// Waits asynchronously for the one bounded initial-scan result. Cancelling
    /// the waiter requests worker shutdown; the owned thread finishes any public
    /// AX call already in flight and then resumes the waiter without a result.
    func waitForInitialResult() async -> Output? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { waiter in
                condition.lock()
                if let initialOutput {
                    condition.unlock()
                    waiter.resume(returning: initialOutput)
                } else if initialWasPublished || finished {
                    condition.unlock()
                    waiter.resume(returning: nil)
                } else {
                    initialWaiters.append(waiter)
                    condition.unlock()
                }
            }
        } onCancel: {
            requestStop()
        }
    }

    func requestStop() {
        condition.lock()
        guard !stopping else {
            condition.unlock()
            return
        }
        stopping = true
        let finishWithoutThread = thread == nil
        condition.broadcast()
        condition.unlock()
        mailbox.close()
        if finishWithoutThread { finish() }
    }

    func waitUntilStopped() async {
        await withCheckedContinuation { waiter in
            condition.lock()
            if finished {
                condition.unlock()
                waiter.resume()
            } else {
                stopWaiters.append(waiter)
                condition.unlock()
            }
        }
    }

    private func threadMain() {
        let initial = autoreleasepool { initialScan() }
        guard publishInitial(initial) else {
            finish()
            return
        }

        while true {
            condition.lock()
            let shouldStop = stopping
            condition.unlock()
            if shouldStop { break }

            let drain: SceneTokenMailboxDrain<AXSceneWorkToken>
            switch mailbox.waitAndDrain() {
            case .closed:
                finish()
                return
            case let .drained(value):
                drain = value
            }

            let result = autoreleasepool { process(drain) }
            condition.lock()
            guard !stopping else {
                condition.unlock()
                break
            }
            nextOrdinal = nextOrdinal == UInt64.max ? 1 : nextOrdinal + 1
            let ordinal = nextOrdinal
            condition.unlock()

            guard case .enqueued = continuation.yield(Output(
                ordinal: ordinal,
                result: result
            )) else {
                break
            }

            condition.lock()
            while acknowledgedOrdinal < ordinal, !stopping {
                condition.wait()
            }
            condition.unlock()
        }
        finish()
    }

    private func publishInitial(_ result: AXSceneProcessResult) -> Bool {
        condition.lock()
        guard !stopping, !finished else {
            condition.unlock()
            return false
        }
        nextOrdinal = nextOrdinal == UInt64.max ? 1 : nextOrdinal + 1
        let output = Output(ordinal: nextOrdinal, result: result)
        initialOutput = output
        initialWasPublished = true
        let waiters = initialWaiters
        initialWaiters.removeAll(keepingCapacity: false)
        condition.unlock()

        for waiter in waiters { waiter.resume(returning: output) }

        condition.lock()
        while acknowledgedOrdinal < output.ordinal, !stopping {
            condition.wait()
        }
        let shouldContinue = !stopping
        condition.unlock()
        return shouldContinue
    }

    private func finish() {
        condition.lock()
        guard !finished else {
            condition.unlock()
            return
        }
        finished = true
        thread = nil
        initialOutput = nil
        let initialWaiters = self.initialWaiters
        self.initialWaiters.removeAll(keepingCapacity: false)
        let stopWaiters = self.stopWaiters
        self.stopWaiters.removeAll(keepingCapacity: false)
        condition.broadcast()
        condition.unlock()

        continuation.finish()
        for waiter in initialWaiters { waiter.resume(returning: nil) }
        for waiter in stopWaiters { waiter.resume() }
    }
}

/// Headless, pointer-independent accessibility discovery source. It owns a source
/// epoch, sequence, coverage stream, observer thread, scan lane, and identity
/// registry independent from window metadata and live pointer semantics.
public actor AXSceneSource: SceneDiscoverySource {
    private enum Lifecycle: Sendable {
        case idle
        case starting
        case running
        case stopping
        case stopped
    }

    public nonisolated let manifest: SceneSourceManifest

    private let clock: any SceneSourceMonotonicClock
    private let mailbox: BoundedSceneTokenMailbox<AXSceneWorkToken>
    private let heartbeatInterval: DispatchTimeInterval
    private let periodicRescanCadence: AXPeriodicRescanCadence
    private let maximumCoverageSilenceNs: UInt64
    private let trackedApplications = AXTrackedApplicationStore()
    private let observerThread: AXObserverThread
    private let runtime: AXSceneScanRuntime
    private let scanWorker: AXSceneScanWorker

    private var lifecycle: Lifecycle = .idle
    private var emitter: SceneSourceEmitter?
    private var callbackRegistration: AXLifecycleCallbackRegistration?
    private var worker: Task<Void, Never>?

    public init(
        device: DevicePrincipalID,
        sessionID: SceneSessionID,
        coordinateRegistry: MacDesktopCoordinateRegistry,
        sourceID: SceneSourceID = SceneSourceID(
            rawValue: UUID(uuidString: "4D505343-4143-4345-5353-4942494C0001")!
        ),
        censusProvider: any MacDesktopCensusProviding = SystemMacDesktopCensusProvider(),
        clock: any SceneSourceMonotonicClock = SystemSceneSourceMonotonicClock(),
        mailboxCapacity: Int = 256,
        heartbeatInterval: DispatchTimeInterval = .seconds(5),
        periodicRescanCadence: AXPeriodicRescanCadence = AXPeriodicRescanCadence(),
        maximumCoverageSilenceNs: UInt64 = 15_000_000_000,
        maximumScanDepth: Int = 2,
        maximumScanObjects: Int = 128
    ) throws {
        guard coordinateRegistry.device == device else {
            throw AXSceneSourceError.coordinateRegistryDeviceMismatch
        }
        let sourceEpoch = SceneSourceEpoch(
            source: SceneSourceIdentity(device: device, source: sourceID)
        )
        self.manifest = try SceneSourceManifest(
            sourceEpoch: sourceEpoch,
            sessionID: sessionID,
            displayName: "macOS accessibility scene discovery",
            kind: .accessibility,
            capabilities: [
                .structuredHierarchy,
                .geometry,
                .sensitivityClassification,
                .coverageReporting,
                .onDemandRefresh,
                .checkpoints,
            ]
        )
        self.clock = clock
        let mailbox = BoundedSceneTokenMailbox<AXSceneWorkToken>(capacity: mailboxCapacity)
        self.mailbox = mailbox
        self.heartbeatInterval = heartbeatInterval
        self.periodicRescanCadence = periodicRescanCadence
        self.maximumCoverageSilenceNs = maximumCoverageSilenceNs
        let observerThread = AXObserverThread(mailbox: mailbox)
        self.observerThread = observerThread
        let runtime = AXSceneScanRuntime(
            device: device,
            sourceEpoch: sourceEpoch,
            clock: clock,
            censusProvider: censusProvider,
            coordinateRegistry: coordinateRegistry,
            trackedApplications: trackedApplications,
            observerThread: observerThread,
            maximumDepth: maximumScanDepth,
            maximumObjects: maximumScanObjects
        )
        self.runtime = runtime
        self.scanWorker = AXSceneScanWorker(mailbox: mailbox, runtime: runtime)
    }

    public func start(
        handle: SceneSourceHandle,
        sink: any SceneEventSink
    ) async throws {
        switch lifecycle {
        case .idle:
            break
        case .starting, .running, .stopping:
            throw AXSceneSourceError.alreadyStarted
        case .stopped:
            throw AXSceneSourceError.stopped
        }
        guard handle.sourceEpoch == manifest.sourceEpoch,
              handle.sessionID == manifest.sessionID
        else {
            throw AXSceneSourceError.sourceHandleMismatch
        }

        let emitter = try SceneSourceEmitter(
            sourceEpoch: manifest.sourceEpoch,
            handle: handle,
            sink: sink,
            clock: clock
        )
        self.emitter = emitter

        do {
            lifecycle = .starting
            callbackRegistration = AXLifecycleCallbackRegistration.start(
                mailbox: mailbox,
                heartbeatInterval: heartbeatInterval,
                periodicRescanCadence: periodicRescanCadence
            )
            guard await observerThread.start(),
                  lifecycle == .starting,
                  !Task.isCancelled
            else {
                throw AXSceneSourceError.stopped
            }
            lifecycle = .running

            let scanWorker = self.scanWorker
            scanWorker.start()
            guard let initial = await scanWorker.waitForInitialResult(),
                  lifecycle == .running,
                  !Task.isCancelled
            else {
                throw AXSceneSourceError.stopped
            }
            try await consume(initial.result, emitter: emitter, initial: true)
            guard lifecycle == .running, !Task.isCancelled else {
                throw AXSceneSourceError.stopped
            }
            scanWorker.acknowledge(initial.ordinal)

            worker = Task { [weak self, scanWorker] in
                for await output in scanWorker.outputs {
                    guard !Task.isCancelled else { return }
                    await self?.consumeFromWorker(output.result)
                    scanWorker.acknowledge(output.ordinal)
                }
            }
        } catch {
            callbackRegistration?.stop()
            callbackRegistration = nil
            scanWorker.requestStop()
            worker?.cancel()
            if let worker { await worker.value }
            self.worker = nil
            await scanWorker.waitUntilStopped()
            await observerThread.stop()
            if await emitter.hasOpenCoverageStream() {
                _ = try? await emitter.endCoverage(.producerPaused)
            }
            self.emitter = nil
            lifecycle = .stopped
            throw error
        }
    }

    /// Adds bounded background targets in addition to the current frontmost app.
    /// The source intentionally does not observe every running process by default.
    public func setTrackedApplications(_ processIDs: Set<Int32>) {
        guard lifecycle == .idle || lifecycle == .running else { return }
        trackedApplications.replace(with: processIDs)
        if lifecycle == .running { mailbox.offer(.reconcileApplications) }
    }

    public func refresh(_ request: RefreshRequest) async -> RefreshDisposition {
        guard lifecycle == .running, request.sessionID == manifest.sessionID else {
            return .rejected
        }
        switch request.scope {
        case let .sourceProjection(source) where source != manifest.sourceEpoch:
            return .unsupported
        case let .object(object) where object.sourceEpoch != manifest.sourceEpoch:
            return .unsupported
        case let .surface(surface) where surface.device != manifest.sourceEpoch.source.device:
            return .unsupported
        case let .region(region)
            where region.coordinateSpace.surface.device != manifest.sourceEpoch.source.device:
            return .unsupported
        default:
            break
        }
        return mailbox.offer(.explicitRefresh) == .closed ? .rejected : .accepted
    }

    public func stop() async {
        switch lifecycle {
        case .starting, .running:
            break
        case .idle, .stopping, .stopped:
            return
        }
        lifecycle = .stopping
        callbackRegistration?.stop()
        callbackRegistration = nil
        scanWorker.requestStop()
        worker?.cancel()
        if let worker { await worker.value }
        self.worker = nil
        await scanWorker.waitUntilStopped()
        await observerThread.stop()

        if let emitter, await emitter.hasOpenCoverageStream() {
            _ = try? await emitter.endCoverage(.producerPaused)
        }
        emitter = nil
        lifecycle = .stopped
    }

    private func consumeFromWorker(_ result: AXSceneProcessResult) async {
        guard lifecycle == .running, let emitter else { return }
        do {
            try await consume(result, emitter: emitter, initial: false)
        } catch {
            if await emitter.hasActiveCoverage() {
                _ = try? await emitter.gapCoverage(.unknown)
            }
        }
    }

    private func consume(
        _ result: AXSceneProcessResult,
        emitter: SceneSourceEmitter,
        initial: Bool
    ) async throws {
        if let gapReason = result.gapReason, await emitter.hasActiveCoverage() {
            try ensureAccepted(try await emitter.gapCoverage(gapReason))
        }

        if result.restartCoverage, await emitter.hasOpenCoverageStream() {
            try ensureAccepted(try await emitter.endCoverage(.producerPaused))
        }

        for batch in AXScenePayloadBatching.batches(for: result) {
            try ensureAccepted(try await emitter.emit(batch))
        }
        if let checkpoint = result.checkpoint {
            try ensureAccepted(try await emitter.emit(.checkpoint(checkpoint)))
        }

        let hasOpenCoverage = await emitter.hasOpenCoverageStream()
        if result.checkpoint != nil, !hasOpenCoverage {
            try ensureAccepted(try await emitter.beginBestEffortCoverage(
                scope: .sourceProjection(manifest.sourceEpoch),
                maximumSilenceNs: maximumCoverageSilenceNs
            ))
        } else if result.restartCoverage, result.checkpoint != nil {
            try ensureAccepted(try await emitter.beginBestEffortCoverage(
                scope: .sourceProjection(manifest.sourceEpoch),
                maximumSilenceNs: maximumCoverageSilenceNs
            ))
        }

        if result.heartbeatRequested, await emitter.hasActiveCoverage() {
            try ensureAccepted(try await emitter.heartbeatCoverage())
        }

        _ = initial // Documents that an initial permission gap is a valid start state.
    }

    private func ensureAccepted(_ receipt: IngestReceipt) throws {
        guard receipt.status != .rejected else {
            throw AXSceneSourceError.sinkRejected(receipt.rejection)
        }
    }
}

/// Workspace callbacks are used only to choose which application deserves an AX
/// observer and to break coverage across sleep/lock. Bodies offer fixed tokens;
/// they do not inspect notification payloads or make AX calls.
private final class AXLifecycleCallbackRegistration: @unchecked Sendable {
    private let notificationCenter: NotificationCenter
    private let observers: [NSObjectProtocol]
    private let timers: AXLifecycleTimerRegistration
    private let stopLock = NSLock()
    private var stopped = false

    static func start(
        mailbox: BoundedSceneTokenMailbox<AXSceneWorkToken>,
        heartbeatInterval: DispatchTimeInterval,
        periodicRescanCadence: AXPeriodicRescanCadence
    ) -> AXLifecycleCallbackRegistration {
        let center = NSWorkspace.shared.notificationCenter
        let names: [(Notification.Name, AXSceneWorkToken)] = [
            (NSWorkspace.didActivateApplicationNotification, .reconcileApplications),
            (NSWorkspace.didLaunchApplicationNotification, .reconcileApplications),
            (NSWorkspace.didTerminateApplicationNotification, .reconcileApplications),
            (NSWorkspace.willSleepNotification, .systemWillSleep),
            (NSWorkspace.didWakeNotification, .systemDidWake),
            (NSWorkspace.sessionDidResignActiveNotification, .sessionDidResignActive),
            (NSWorkspace.sessionDidBecomeActiveNotification, .sessionDidBecomeActive),
        ]
        let observers = names.map { name, token in
            center.addObserver(forName: name, object: nil, queue: nil) { _ in
                mailbox.offer(token)
            }
        }
        let timers = AXLifecycleTimerRegistration.start(
            mailbox: mailbox,
            heartbeatInterval: heartbeatInterval,
            periodicRescanCadence: periodicRescanCadence
        )
        return AXLifecycleCallbackRegistration(
            notificationCenter: center,
            observers: observers,
            timers: timers
        )
    }

    private init(
        notificationCenter: NotificationCenter,
        observers: [NSObjectProtocol],
        timers: AXLifecycleTimerRegistration
    ) {
        self.notificationCenter = notificationCenter
        self.observers = observers
        self.timers = timers
    }

    func stop() {
        stopLock.lock()
        guard !stopped else {
            stopLock.unlock()
            return
        }
        stopped = true
        stopLock.unlock()
        timers.stop()
        for observer in observers { notificationCenter.removeObserver(observer) }
    }
}

/// Owns the heartbeat and reconciliation timers separately so the slow AX scan
/// cadence can be tested without installing workspace observers. Timer handlers
/// only offer coalescing mailbox tokens; all census and AX work remains on the
/// owned utility scan thread.
final class AXLifecycleTimerRegistration: @unchecked Sendable {
    private let heartbeatTimer: DispatchSourceTimer
    private let periodicRescanTimer: DispatchSourceTimer
    private let stopLock = NSLock()
    private var stopped = false

    static func start(
        mailbox: BoundedSceneTokenMailbox<AXSceneWorkToken>,
        heartbeatInterval: DispatchTimeInterval,
        periodicRescanCadence: AXPeriodicRescanCadence
    ) -> AXLifecycleTimerRegistration {
        let interval = DispatchTimeInterval.seconds(periodicRescanCadence.intervalSeconds)
        let leeway = DispatchTimeInterval.seconds(
            min(10, max(1, periodicRescanCadence.intervalSeconds / 10))
        )
        return start(
            mailbox: mailbox,
            heartbeatInterval: heartbeatInterval,
            periodicRescanInterval: interval,
            periodicRescanLeeway: leeway
        )
    }

    static func start(
        mailbox: BoundedSceneTokenMailbox<AXSceneWorkToken>,
        heartbeatInterval: DispatchTimeInterval,
        periodicRescanInterval: DispatchTimeInterval,
        periodicRescanLeeway: DispatchTimeInterval
    ) -> AXLifecycleTimerRegistration {
        let heartbeatTimer = DispatchSource.makeTimerSource(
            flags: [],
            queue: DispatchQueue(label: "magic-pointer.ax-discovery.heartbeat", qos: .utility)
        )
        heartbeatTimer.schedule(
            deadline: .now() + heartbeatInterval,
            repeating: heartbeatInterval
        )
        heartbeatTimer.setEventHandler { mailbox.offer(.heartbeat) }
        heartbeatTimer.resume()

        let periodicRescanTimer = DispatchSource.makeTimerSource(
            flags: [],
            queue: DispatchQueue(
                label: "magic-pointer.ax-discovery.periodic-rescan",
                qos: .utility
            )
        )
        periodicRescanTimer.schedule(
            deadline: .now() + periodicRescanInterval,
            repeating: periodicRescanInterval,
            leeway: periodicRescanLeeway
        )
        periodicRescanTimer.setEventHandler { mailbox.offer(.periodicRescan) }
        periodicRescanTimer.resume()
        return AXLifecycleTimerRegistration(
            heartbeatTimer: heartbeatTimer,
            periodicRescanTimer: periodicRescanTimer
        )
    }

    private init(
        heartbeatTimer: DispatchSourceTimer,
        periodicRescanTimer: DispatchSourceTimer
    ) {
        self.heartbeatTimer = heartbeatTimer
        self.periodicRescanTimer = periodicRescanTimer
    }

    func stop() {
        stopLock.lock()
        guard !stopped else {
            stopLock.unlock()
            return
        }
        stopped = true
        stopLock.unlock()
        heartbeatTimer.setEventHandler {}
        heartbeatTimer.cancel()
        periodicRescanTimer.setEventHandler {}
        periodicRescanTimer.cancel()
    }
}

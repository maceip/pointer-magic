@preconcurrency import ApplicationServices
import Dispatch
import Foundation
@testable import PointerMacSceneDiscovery
@testable import PointerSceneContracts
import Testing

@Suite("AX discovery primitives")
struct AXDiscoveryPrimitivesTests {
    @Test("a full incremental notification drain collapses to one bounded resynchronization")
    func fullIncrementalDrainCollapsesBeforeScanning() throws {
        let mailbox = BoundedSceneTokenMailbox<AXSceneWorkToken>(capacity: 256)
        for index in 1 ... 256 {
            let processID = Int32(index)
            #expect(mailbox.offer(.notification(
                processID: processID,
                kind: .valueChanged,
                element: AXRetainedElement(AXUIElementCreateApplication(pid_t(processID)))
            )) == .inserted)
        }

        let drain = try #require(mailbox.drain())
        #expect(drain.tokens.count == 256)
        #expect(!drain.overflowed)
        #expect(AXNotificationDrainScanPolicy.maximumIncrementalElementScans == 4)
        #expect(!AXNotificationDrainScanPolicy.requiresFullResynchronization(
            for: drain.tokens.prefix(4)
        ))
        #expect(AXNotificationDrainScanPolicy.requiresFullResynchronization(
            for: drain.tokens.prefix(5)
        ))
        #expect(AXNotificationDrainScanPolicy.requiresFullResynchronization(
            for: drain.tokens
        ))
    }

    @Test("maps only the supported public notification set")
    func notificationMapping() {
        let cases: [(String, AXSceneNotificationKind)] = [
            (kAXFocusedUIElementChangedNotification as String, .focusedElementChanged),
            (kAXWindowCreatedNotification as String, .windowCreated),
            (kAXWindowMovedNotification as String, .windowMoved),
            (kAXWindowResizedNotification as String, .windowResized),
            (kAXValueChangedNotification as String, .valueChanged),
            (kAXUIElementDestroyedNotification as String, .elementDestroyed),
            (kAXSelectedTextChangedNotification as String, .selectedTextChanged),
            (kAXTitleChangedNotification as String, .titleChanged),
            (kAXLayoutChangedNotification as String, .layoutChanged),
        ]
        for (notification, expected) in cases {
            #expect(AXSceneNotificationMapper.kind(for: notification) == expected)
        }
        #expect(AXSceneNotificationMapper.kind(for: "AXPrivateOrFutureEvent") == nil)
        #expect(AXSceneNotificationKind.windowMoved.invalidationReason == .moved)
        #expect(AXSceneNotificationKind.layoutChanged.requiresHierarchyRescan)
        #expect(!AXSceneNotificationKind.valueChanged.requiresHierarchyRescan)
        #expect(AXSceneNotificationKind.valueChanged.invalidatedFields == [
            AXSceneField.content,
        ])
    }

    @Test("unsupported registrations remain reduced best effort")
    func registrationDisposition() {
        #expect(
            AXNotificationRegistrationDisposition.classify(.notificationUnsupported) ==
                .unsupportedBestEffort
        )
        #expect(
            AXNotificationRegistrationDisposition.classify(.notImplemented) ==
                .unsupportedBestEffort
        )
        #expect(
            AXNotificationRegistrationDisposition.classify(.apiDisabled) == .permissionLost
        )
    }

    @Test("hard scan budget rejects depth and object overflow")
    func hardScanBudget() {
        var budget = AXShallowScanBudget(maximumDepth: 2, maximumObjects: 3)
        let first = budget.consume(depth: 0)
        let second = budget.consume(depth: 2)
        let tooDeep = budget.consume(depth: 3)
        let third = budget.consume(depth: 1)
        let tooMany = budget.consume(depth: 0)
        #expect(first)
        #expect(second)
        #expect(!tooDeep)
        #expect(third)
        #expect(!tooMany)
        #expect(budget.consumedObjects == 3)
        #expect(budget.remainingObjects == 0)
    }

    @Test("visible children lead and traversal is bounded and deduplicated")
    func visibleChildrenLead() {
        let ordered = AXVisibleChildOrder.prioritized(
            visible: [3, 1, 3],
            all: [1, 2, 3, 4],
            limit: 4
        )
        #expect(ordered == [3, 1, 2, 4])
        #expect(AXVisibleChildOrder.prioritized(
            visible: [1],
            all: [2],
            limit: 0
        ).isEmpty)
    }

    @Test("target selection is live, visible, front-to-back, and deterministic")
    func targetProcessSelection() {
        let census = AXSelectionFixture.census(
            applications: [
                AXSelectionFixture.application(40),
                AXSelectionFixture.application(10, isActive: true),
                AXSelectionFixture.application(20),
                AXSelectionFixture.application(30),
                AXSelectionFixture.application(50),
                AXSelectionFixture.application(99),
            ],
            windows: [
                AXSelectionFixture.window(4, owner: 30, index: 3),
                AXSelectionFixture.window(2, owner: 20, index: 0),
                AXSelectionFixture.window(3, owner: 20, index: 1),
                AXSelectionFixture.window(5, owner: 40, index: 2, isOnScreen: false),
                AXSelectionFixture.window(6, owner: 50, index: 4, alpha: 0),
            ]
        )

        let selected = AXTargetProcessSelection.prioritized(
            census: census,
            explicitlyTrackedProcessIDs: [40, 60, 99],
            ownProcessID: 99
        )

        #expect(selected == [10, 20, 30, 40])
        #expect(!selected.contains(50))
        #expect(!selected.contains(60))
        #expect(!selected.contains(99))
    }

    @Test("target selection has a hard eight-process cap")
    func targetProcessSelectionCap() {
        let applications = (1 ... 12).map {
            AXSelectionFixture.application(Int32($0), isActive: $0 == 12)
        }
        let windows = (1 ... 11).reversed().map {
            AXSelectionFixture.window(
                UInt32($0),
                owner: Int32($0),
                index: $0 - 1
            )
        }
        let census = AXSelectionFixture.census(
            applications: applications,
            windows: windows
        )

        let selected = AXTargetProcessSelection.prioritized(
            census: census,
            explicitlyTrackedProcessIDs: [11],
            ownProcessID: 100,
            maximumCount: 100
        )

        #expect(selected == [12, 1, 2, 3, 4, 5, 6, 7])
        #expect(Set(selected).count == selected.count)
    }

    @Test("periodic reconciliation cadence cannot become a tight poll")
    func periodicCadenceBounds() {
        #expect(AXPeriodicRescanCadence().intervalSeconds == 60)
        #expect(AXPeriodicRescanCadence(intervalSeconds: 0).intervalSeconds == 15)
        #expect(AXPeriodicRescanCadence(intervalSeconds: 30).intervalSeconds == 30)
        #expect(AXPeriodicRescanCadence(intervalSeconds: 10_000).intervalSeconds == 900)
    }

    @Test("descendants cannot weaken secure or unknown ancestry")
    func sensitivityPropagation() {
        #expect(AXSceneSensitivityPropagation.combine(
            parent: .secure,
            local: .ordinary
        ) == .secure)
        #expect(AXSceneSensitivityPropagation.combine(
            parent: .unknown,
            local: .ordinary
        ) == .unknown)
        #expect(AXSceneSensitivityPropagation.combine(
            parent: .unknown,
            local: .secure
        ) == .secure)
        #expect(AXSceneSensitivityPropagation.combine(
            parent: .ordinary,
            local: .secure
        ) == .secure)
        #expect(AXSceneSensitivityPropagation.combine(
            parent: nil,
            local: .ordinary
        ) == .ordinary)
    }

    @Test("proactive scans read structural attributes only")
    func structuralAttributePrivacyPolicy() {
        let allowed = Set(AXStructuralAttributePolicy.attributeNames)
        #expect(allowed == Set([
            kAXRoleAttribute as String,
            kAXSubroleAttribute as String,
            kAXPositionAttribute as String,
            kAXSizeAttribute as String,
        ]))
        let forbidden = [
            kAXTitleAttribute as String,
            kAXDescriptionAttribute as String,
            kAXIdentifierAttribute as String,
            kAXValueAttribute as String,
        ]
        #expect(forbidden.allSatisfy { !allowed.contains($0) })
        #expect(AXStructuralAttributePolicy.contentSensitivity(subrole: nil) == .unknown)
        #expect(AXStructuralAttributePolicy.contentSensitivity(
            subrole: kAXSecureTextFieldSubrole as String
        ) == .secure)
    }

    @Test("structural observations never persist AX string metadata")
    func structuralObservationPrivacy() throws {
        let device = DevicePrincipalID()
        let epoch = SceneSourceEpoch(source: SceneSourceIdentity(
            device: device,
            source: SceneSourceID()
        ))
        let scanner = AXShallowScanner(device: device, sourceEpoch: epoch)
        let node = AXScannedNode(
            processID: 42,
            objectID: SourceObjectID(),
            parentObjectID: nil,
            element: AXUIElementCreateSystemWide(),
            profile: .element,
            role: kAXButtonRole as String,
            subrole: nil,
            bounds: nil,
            sensitivity: .unknown
        )

        let observation = try scanner.observation(
            for: node,
            coordinateSnapshot: nil,
            observedAt: 1
        )
        let label = try SceneFieldKey("accessibility.label")
        let identifier = try SceneFieldKey("accessibility.identifier")
        let content = try #require(observation.claims.first {
            $0.field == AXSceneField.content
        })

        #expect(!observation.claims.contains { $0.field == label || $0.field == identifier })
        #expect(content.value == nil)
        #expect(content.sensitivity == .unknown)
        #expect(observation.claims.first { $0.field == AXSceneField.role }?.value ==
            .text(kAXButtonRole as String))
    }

    @Test("accessibility source never declares complete event coverage")
    func manifestIsIndependentBestEffortSource() throws {
        let device = DevicePrincipalID()
        let source = try AXSceneSource(
            device: device,
            sessionID: SceneSessionID(),
            coordinateRegistry: MacDesktopCoordinateRegistry(device: device)
        )
        #expect(source.manifest.kind == .accessibility)
        #expect(source.manifest.capabilities.contains(.coverageReporting))
        #expect(source.manifest.capabilities.contains(.checkpoints))
        #expect(!source.manifest.capabilities.contains(.text))
        #expect(!source.manifest.capabilities.contains(.completeEventCoverage))
    }
}

@Suite("AX scene source lifecycle", .serialized)
struct AXSceneSourceLifecycleTests {
    @Test("starts and stops cleanly with or without Accessibility permission")
    func lifecycle() async throws {
        let device = DevicePrincipalID()
        let session = SceneSessionID()
        let censusProvider = AXCountingCensusProvider()
        let source = try AXSceneSource(
            device: device,
            sessionID: session,
            coordinateRegistry: MacDesktopCoordinateRegistry(device: device),
            censusProvider: censusProvider,
            clock: AXFixedClock(),
            heartbeatInterval: .seconds(3_600),
            periodicRescanCadence: AXPeriodicRescanCadence(intervalSeconds: 3_600)
        )
        let handle = SceneSourceHandle(
            sourceEpoch: source.manifest.sourceEpoch,
            sessionID: session,
            grantID: SceneSourceGrantID()
        )
        let sink = AXRecordingSink()

        try await source.start(handle: handle, sink: sink)
        await source.stop()
        await source.stop()

        let events = await sink.events()
        #expect(!events.isEmpty)
        if events.contains(where: {
            if case .checkpoint = $0.payload { return true }
            return false
        }) {
            #expect(censusProvider.captureCount == 1)
            let coverage = events.compactMap { event -> CoverageReport? in
                if case let .coverage(report) = event.payload { return report }
                return nil
            }
            #expect(coverage.count == 2)
            #expect(coverage.allSatisfy { $0.guarantee == .bestEffort })
        } else if case let .invalidation(invalidation)? = events.first?.payload {
            #expect(invalidation.reason == .permissionChanged)
        } else {
            Issue.record("source produced neither a checkpoint nor a permission invalidation")
        }
    }

    @Test("stop racing startup cannot strand observer or scan threads")
    func stopDuringStartup() async throws {
        let device = DevicePrincipalID()
        let session = SceneSessionID()
        let source = try AXSceneSource(
            device: device,
            sessionID: session,
            coordinateRegistry: MacDesktopCoordinateRegistry(device: device),
            censusProvider: AXCountingCensusProvider(),
            clock: AXFixedClock(),
            heartbeatInterval: .seconds(3_600),
            periodicRescanCadence: AXPeriodicRescanCadence(intervalSeconds: 3_600)
        )
        let handle = SceneSourceHandle(
            sourceEpoch: source.manifest.sourceEpoch,
            sessionID: session,
            grantID: SceneSourceGrantID()
        )
        let sink = AXRecordingSink()
        let start = Task { () -> Bool in
            do {
                try await source.start(handle: handle, sink: sink)
                return true
            } catch {
                return false
            }
        }

        await Task.yield()
        await source.stop()
        _ = await start.value
        await source.stop()
    }

    @Test("periodic reconciliation timer is distinct from heartbeat and stops cleanly")
    func periodicReconciliationLifecycle() async throws {
        let mailbox = BoundedSceneTokenMailbox<AXSceneWorkToken>(capacity: 4)
        let registration = AXLifecycleTimerRegistration.start(
            mailbox: mailbox,
            heartbeatInterval: .seconds(3_600),
            periodicRescanInterval: .milliseconds(10),
            periodicRescanLeeway: .milliseconds(1)
        )

        var received: [AXSceneWorkToken] = []
        for _ in 0 ..< 50 where received.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
            received.append(contentsOf: mailbox.drain()?.tokens ?? [])
        }
        #expect(received.contains(.periodicRescan))
        #expect(!received.contains(.heartbeat))

        registration.stop()
        registration.stop()
    }
}

@Suite("AX result emission", .serialized)
struct AXSceneResultEmissionTests {
    @Test("a full notification drain emits ordered contract-sized batches")
    func fullDrainIsChunked() async throws {
        let device = DevicePrincipalID()
        let epoch = SceneSourceEpoch(source: SceneSourceIdentity(
            device: device,
            source: SceneSourceID()
        ))
        let invalidation = try SceneInvalidation(
            scope: .sourceProjection(epoch),
            reason: .valueChanged,
            observedAtSourceMonotonicNs: 1
        )
        let claim = try SceneFieldClaim(
            field: SceneFieldKey("accessibility.role"),
            value: .text("AXButton"),
            knowledge: .observed,
            confidence: 1,
            sensitivity: .ordinary,
            evidence: [try SceneEvidence(kind: .accessibility)]
        )
        let observation = try SceneObservation(
            subject: SourceObjectKey(sourceEpoch: epoch, objectID: SourceObjectID()),
            observedAtSourceMonotonicNs: 1,
            claims: [claim]
        )
        let eventLimit = SceneContractLimits.eventsPerBatch
        let result = AXSceneProcessResult(
            invalidations: Array(repeating: invalidation, count: eventLimit),
            observations: Array(repeating: observation, count: eventLimit)
        )
        let batches = AXScenePayloadBatching.batches(for: result)

        #expect(AXScenePayloadBatching.maximumEventsPerBatch ==
            SceneContractLimits.eventsPerBatch)
        #expect(batches.map(\.count) == [eventLimit, eventLimit])
        let flattened = batches.flatMap { $0 }
        #expect(flattened.prefix(eventLimit).allSatisfy { $0.kind == .invalidation })
        #expect(flattened.suffix(eventLimit).allSatisfy { $0.kind == .observation })

        let session = SceneSessionID()
        let handle = SceneSourceHandle(
            sourceEpoch: epoch,
            sessionID: session,
            grantID: SceneSourceGrantID()
        )
        let sink = AXBatchRecordingSink()
        let emitter = try SceneSourceEmitter(
            sourceEpoch: epoch,
            handle: handle,
            sink: sink,
            clock: AXFixedClock()
        )
        for batch in batches {
            _ = try await emitter.emit(batch)
        }

        #expect(await sink.batchSizes() == [eventLimit, eventLimit])
        #expect(await sink.revisions() == Array(1 ... (eventLimit * 2)).map(UInt64.init))
        #expect(await sink.payloads() == flattened)
    }
}

@Suite("AX identity eviction")
struct AXSceneIdentityRegistryTests {
    @Test("a checkpoint omission retires an identity before the element reappears")
    func checkpointOmissionPreventsIdentityReuse() {
        let registry = AXSceneIdentityRegistry(capacity: 128)
        let omittedElement = AXUIElementCreateApplication(900)
        let retainedElement = AXUIElementCreateApplication(901)
        let omittedID = registry.objectID(for: omittedElement, processID: 900)
        let retainedID = registry.objectID(for: retainedElement, processID: 901)

        let removed = registry.removeIdentitiesOmitted(
            byCheckpointRetaining: [retainedID]
        )

        #expect(removed == [omittedID])
        #expect(registry.existingObjectID(
            for: omittedElement,
            processID: 900
        ) == nil)
        #expect(registry.objectID(
            for: retainedElement,
            processID: 901
        ) == retainedID)
        let reappearedID = registry.objectID(for: omittedElement, processID: 900)
        #expect(reappearedID != omittedID)
    }

    @Test("observation cache churn drains every identity eviction")
    func evictionDrainKeepsCacheCoupled() throws {
        let registry = AXSceneIdentityRegistry(capacity: 128)
        var observationCache: [SourceObjectID: Int] = [:]
        var evicted: [SourceObjectID] = []
        var firstRecord: (
            element: AXUIElement,
            processID: Int32,
            objectID: SourceObjectID
        )?
        var lastRecord: (
            element: AXUIElement,
            processID: Int32,
            objectID: SourceObjectID
        )?

        for offset in 0 ..< 256 {
            let processID = Int32(1_000 + offset)
            let element = AXUIElementCreateApplication(pid_t(processID))
            let objectID = registry.objectID(for: element, processID: processID)
            observationCache[objectID] = offset
            let newlyEvicted = registry.drainEvictedObjectIDs()
            for evictedID in newlyEvicted { observationCache[evictedID] = nil }
            evicted.append(contentsOf: newlyEvicted)
            if offset == 0 { firstRecord = (element, processID, objectID) }
            if offset == 255 { lastRecord = (element, processID, objectID) }
        }

        let first = try #require(firstRecord)
        let last = try #require(lastRecord)
        #expect(registry.entryCount == 128)
        #expect(observationCache.count == registry.entryCount)
        #expect(evicted.count == 128)
        #expect(evicted.contains(first.objectID))
        #expect(registry.existingObjectID(
            for: first.element,
            processID: first.processID
        ) == nil)
        #expect(registry.existingObjectID(
            for: last.element,
            processID: last.processID
        ) == last.objectID)
        #expect(registry.drainEvictedObjectIDs().isEmpty)
    }
}

@Suite("AX observer owned thread", .serialized)
struct AXObserverThreadTests {
    @Test("an empty observer set blocks until its control source is signalled")
    func idleRunLoopDoesNotSpin() async throws {
        let observer = AXObserverThread(
            mailbox: BoundedSceneTokenMailbox<AXSceneWorkToken>(capacity: 4)
        )

        #expect(await observer.start())
        let beforeIdle = observer.diagnosticRunLoopIterationCount()
        try await Task.sleep(for: .milliseconds(50))
        let afterIdle = observer.diagnosticRunLoopIterationCount()
        #expect(afterIdle >= beforeIdle)
        #expect(afterIdle - beforeIdle <= 1)

        observer.replaceTrackedElements([])
        var afterSignal = afterIdle
        for _ in 0 ..< 50 where afterSignal == afterIdle {
            try await Task.sleep(for: .milliseconds(2))
            afterSignal = observer.diagnosticRunLoopIterationCount()
        }
        #expect(afterSignal > afterIdle)

        try await Task.sleep(for: .milliseconds(50))
        let afterSecondIdle = observer.diagnosticRunLoopIterationCount()
        #expect(afterSecondIdle >= afterSignal)
        #expect(afterSecondIdle - afterSignal <= 1)
        await observer.stop()
    }

    @Test("readiness and shutdown use async continuation handoffs")
    func asyncLifecycle() async {
        let observer = AXObserverThread(
            mailbox: BoundedSceneTokenMailbox<AXSceneWorkToken>(capacity: 4)
        )

        #expect(await observer.start())
        await observer.stop()
        await observer.stop()
        #expect(!(await observer.start()))
    }

    @Test("cancelling readiness cannot strand shutdown")
    func cancelledReadinessStillStops() async {
        let observer = AXObserverThread(
            mailbox: BoundedSceneTokenMailbox<AXSceneWorkToken>(capacity: 4)
        )
        let start = Task { await observer.start() }
        start.cancel()
        _ = await start.value
        await observer.stop()
    }
}

@Suite("AX owned scan worker", .serialized)
struct AXSceneScanWorkerTests {
    @Test("initial scan runs on the owned utility thread before mailbox work")
    func initialScanPrecedesMailboxDrains() async throws {
        let mailbox = BoundedSceneTokenMailbox<AXSceneWorkToken>(capacity: 4)
        let probe = AXScanWorkerProbe()
        let worker = AXSceneScanWorker(
            mailbox: mailbox,
            initialScan: { probe.initialScan() },
            process: { probe.process($0) }
        )
        var outputs = worker.outputs.makeAsyncIterator()

        #expect(mailbox.offer(.heartbeat) == .inserted)
        worker.start()
        let initialValue = await worker.waitForInitialResult()
        let initial = try #require(initialValue)

        #expect(probe.initialThreadName == "MagicPointer.AXDiscoveryScan")
        #expect(probe.initialThreadQuality == .utility)
        try await Task.sleep(for: .milliseconds(20))
        #expect(probe.processedTokens.isEmpty)

        worker.acknowledge(initial.ordinal)
        let updateValue = await outputs.next()
        let update = try #require(updateValue)
        #expect(probe.processedTokens == [[.heartbeat]])

        worker.acknowledge(update.ordinal)
        worker.requestStop()
        await worker.waitUntilStopped()
        #expect(await outputs.next() == nil)
    }

    @Test("cancelling the initial wait shuts down asynchronously after in-flight work")
    func initialWaitCancellationIsSafe() async throws {
        let mailbox = BoundedSceneTokenMailbox<AXSceneWorkToken>(capacity: 1)
        let probe = AXBlockingInitialScanProbe()
        let worker = AXSceneScanWorker(
            mailbox: mailbox,
            initialScan: { probe.initialScan() },
            process: { _ in AXSceneProcessResult() }
        )
        worker.start()
        let waiter = Task { await worker.waitForInitialResult() }

        for _ in 0 ..< 100 where !probe.hasStarted {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(probe.hasStarted)
        waiter.cancel()
        probe.release()

        #expect(await waiter.value == nil)
        await worker.waitUntilStopped()
    }
}

private enum AXSelectionFixture {
    static func application(
        _ processID: Int32,
        isActive: Bool = false
    ) -> MacApplicationSnapshot {
        MacApplicationSnapshot(
            processID: processID,
            bundleIdentifier: "fixture.\(processID)",
            localizedName: "Fixture \(processID)",
            isActive: isActive,
            isHidden: false
        )
    }

    static func window(
        _ windowID: UInt32,
        owner: Int32,
        index: Int,
        isOnScreen: Bool = true,
        alpha: Double = 1
    ) -> MacWindowSnapshot {
        MacWindowSnapshot(
            windowID: windowID,
            ownerProcessID: owner,
            ownerName: nil,
            globalBounds: MacGlobalRect(x: 0, y: 0, width: 100, height: 100)!,
            layer: 0,
            alpha: alpha,
            isOnScreen: isOnScreen,
            sharingState: nil,
            frontToBackIndex: index
        )
    }

    static func census(
        applications: [MacApplicationSnapshot],
        windows: [MacWindowSnapshot]
    ) -> MacDesktopCensus {
        MacDesktopCensus(displays: [], applications: applications, windows: windows)
    }
}

private final class AXCountingCensusProvider: MacDesktopCensusProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _captureCount = 0

    var captureCount: Int {
        lock.withLock { _captureCount }
    }

    func capture() throws -> MacDesktopCensus {
        lock.withLock { _captureCount += 1 }
        return MacDesktopCensus(
            displays: [MacDisplaySnapshot(
                displayID: 1,
                displayUUID: UUID(uuidString: "20000000-0000-0000-0000-000000000001"),
                globalBounds: MacGlobalRect(x: 0, y: 0, width: 1_000, height: 700)!,
                pixelWidth: 2_000,
                pixelHeight: 1_400,
                rotationQuarterTurns: 0,
                scaleFactor: 2,
                isMain: true
            )],
            applications: [],
            windows: []
        )
    }
}

private final class AXScanWorkerProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _initialThreadName: String?
    private var _initialThreadQuality: QualityOfService?
    private var _processedTokens: [[AXSceneWorkToken]] = []

    var initialThreadName: String? {
        lock.withLock { _initialThreadName }
    }

    var initialThreadQuality: QualityOfService? {
        lock.withLock { _initialThreadQuality }
    }

    var processedTokens: [[AXSceneWorkToken]] {
        lock.withLock { _processedTokens }
    }

    func initialScan() -> AXSceneProcessResult {
        lock.withLock {
            _initialThreadName = Thread.current.name
            _initialThreadQuality = Thread.current.qualityOfService
        }
        return AXSceneProcessResult()
    }

    func process(
        _ drain: SceneTokenMailboxDrain<AXSceneWorkToken>
    ) -> AXSceneProcessResult {
        lock.withLock { _processedTokens.append(drain.tokens) }
        return AXSceneProcessResult()
    }
}

private final class AXBlockingInitialScanProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var started = false

    var hasStarted: Bool {
        lock.withLock { started }
    }

    func initialScan() -> AXSceneProcessResult {
        lock.withLock { started = true }
        releaseSemaphore.wait()
        return AXSceneProcessResult()
    }

    func release() {
        releaseSemaphore.signal()
    }
}

private struct AXFixedClock: SceneSourceMonotonicClock {
    func nowNanoseconds() -> UInt64 { 200 }
}

private actor AXRecordingSink: SceneEventSink {
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

private actor AXBatchRecordingSink: SceneEventSink {
    private var receivedBatches: [[SceneEventEnvelope]] = []

    func ingest(
        _ batch: SceneEventBatch,
        through _: SceneSourceHandle
    ) async -> IngestReceipt {
        receivedBatches.append(batch.events)
        return try! IngestReceipt(
            batchID: batch.batchID,
            status: .accepted,
            acceptedThrough: batch.events.last?.revision
        )
    }

    func batchSizes() -> [Int] { receivedBatches.map(\.count) }
    func revisions() -> [UInt64] { receivedBatches.flatMap { $0.map(\.revision.sequence) } }
    func payloads() -> [SceneEventPayload] { receivedBatches.flatMap { $0.map(\.payload) } }
}

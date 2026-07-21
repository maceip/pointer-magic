import Foundation
@testable import PointerMacSceneDiscovery
import PointerSceneContracts
import PointerSceneMemory
import Testing

@Suite("mac scene discovery controller", .serialized)
struct MacSceneDiscoveryControllerTests {
    @Test("restart closes registrations and creates fresh source epochs")
    func restartCreatesFreshEpochs() async throws {
        let recorder = ControllerSourceRecorder()
        let registryProbe = CoordinateRegistryProbe()
        let controller = MacSceneDiscoveryController(
            device: DevicePrincipalID(),
            sessionID: SceneSessionID(),
            factories: factories(recorder: recorder, registryProbe: registryProbe)
        )

        let first = await controller.start()
        #expect(first.phase == .running)
        #expect(first.source(.workspace)?.phase == .running)
        #expect(first.source(.accessibility)?.phase == .running)
        #expect(first.source(.screenDirtyRegions)?.phase == .running)
        let firstWorkspaceEpoch = try #require(first.source(.workspace)?.sourceEpoch)
        let firstAXEpoch = try #require(first.source(.accessibility)?.sourceEpoch)
        let firstDirtyEpoch = try #require(first.source(.screenDirtyRegions)?.sourceEpoch)
        #expect(registryProbe.uniqueRegistryCount() == 1)

        let stopped = await controller.stop()
        #expect(stopped.phase == .stopped)
        #expect(stopped.sources.allSatisfy { $0.phase == .inactive })
        #expect(await controller.memory.statistics().registeredSources == 0)

        let second = await controller.start()
        let secondWorkspaceEpoch = try #require(second.source(.workspace)?.sourceEpoch)
        let secondAXEpoch = try #require(second.source(.accessibility)?.sourceEpoch)
        let secondDirtyEpoch = try #require(second.source(.screenDirtyRegions)?.sourceEpoch)
        #expect(second.generation == first.generation + 1)
        #expect(secondWorkspaceEpoch.source == firstWorkspaceEpoch.source)
        #expect(secondWorkspaceEpoch.epochID != firstWorkspaceEpoch.epochID)
        #expect(secondAXEpoch.source == firstAXEpoch.source)
        #expect(secondAXEpoch.epochID != firstAXEpoch.epochID)
        #expect(secondDirtyEpoch.source == firstDirtyEpoch.source)
        #expect(secondDirtyEpoch.epochID != firstDirtyEpoch.epochID)
        #expect(registryProbe.uniqueRegistryCount() == 1)
        #expect(await recorder.startCount(.workspace) == 2)
        #expect(await recorder.startCount(.accessibility) == 2)
        #expect(await recorder.startCount(.screenDirtyRegions) == 2)

        _ = await controller.stop()
        #expect(await recorder.stopCount(.workspace) == 2)
        #expect(await recorder.stopCount(.accessibility) == 2)
        #expect(await recorder.stopCount(.screenDirtyRegions) == 2)
        #expect(await controller.memory.statistics().registeredSources == 0)
    }

    @Test("one source failure does not stop the other source")
    func sourceFailureIsIsolated() async {
        let recorder = ControllerSourceRecorder()
        let controller = MacSceneDiscoveryController(
            factories: factories(recorder: recorder, failingRole: .accessibility)
        )

        let status = await controller.start()
        #expect(status.phase == .running)
        #expect(status.source(.workspace)?.phase == .running)
        #expect(status.source(.accessibility)?.phase == .failed)
        #expect(status.source(.accessibility)?.failureDescription != nil)
        #expect(status.source(.screenDirtyRegions)?.phase == .running)
        #expect(await controller.memory.statistics().registeredSources == 2)

        _ = await controller.stop()
        #expect(await recorder.stopCount(.workspace) == 1)
        #expect(await controller.memory.statistics().registeredSources == 0)
    }

    @Test("a factory cannot substitute a source from the other role")
    func wrongRoleFactoryFailsClosed() async {
        let recorder = ControllerSourceRecorder()
        let controller = MacSceneDiscoveryController(
            factories: MacSceneDiscoverySourceFactories(
                makeWorkspace: { context in
                    try ControllerMockSource(
                        role: .accessibility,
                        context: context,
                        recorder: recorder,
                        failsOnStart: false
                    )
                },
                makeAccessibility: { context in
                    try ControllerMockSource(
                        role: .accessibility,
                        context: context,
                        recorder: recorder,
                        failsOnStart: false
                    )
                },
                makeScreenDirtyRegions: { context in
                    try ControllerMockSource(
                        role: .screenDirtyRegions,
                        context: context,
                        recorder: recorder,
                        failsOnStart: false
                    )
                }
            )
        )

        let status = await controller.start()
        #expect(status.source(.workspace)?.phase == .failed)
        #expect(status.source(.workspace)?.failureDescription?.contains(
            "unexpectedSourceKind"
        ) == true)
        #expect(status.source(.accessibility)?.phase == .running)
        #expect(status.source(.screenDirtyRegions)?.phase == .running)
        #expect(await recorder.startCount(.workspace) == 0)
        #expect(await recorder.startCount(.accessibility) == 1)
        #expect(await controller.memory.statistics().registeredSources == 2)

        _ = await controller.stop()
        #expect(await controller.memory.statistics().registeredSources == 0)
    }

    @Test("live roles receive field- and evidence-bounded grants")
    func grantsAreLeastPrivilege() throws {
        // Policy construction only depends on the manifest; no AppKit source starts.
        let device = DevicePrincipalID()
        let session = SceneSessionID()
        let workspaceManifest = try manifest(
            role: .workspace,
            device: device,
            session: session
        )
        let axManifest = try manifest(
            role: .accessibility,
            device: device,
            session: session
        )
        let dirtyManifest = try manifest(
            role: .screenDirtyRegions,
            device: device,
            session: session
        )
        let workspace = MacSceneDiscoveryController.authorization(
            for: .workspace,
            manifest: workspaceManifest
        )
        let accessibility = MacSceneDiscoveryController.authorization(
            for: .accessibility,
            manifest: axManifest
        )
        let dirty = MacSceneDiscoveryController.authorization(
            for: .screenDirtyRegions,
            manifest: dirtyManifest
        )

        #expect(workspace.evidenceKinds == [.windowMetadata])
        #expect(accessibility.evidenceKinds == [.accessibility])
        #expect(dirty.evidenceKinds == [.screenPixels])
        #expect(workspace.surfaces == .ownDevice)
        #expect(accessibility.surfaces == .ownDevice)
        #expect(dirty.surfaces == .ownDevice)
        #expect(workspace.eventKinds == Set(SceneEventKind.allCases))
        #expect(accessibility.eventKinds == Set(SceneEventKind.allCases))
        #expect(dirty.eventKinds == Set(SceneEventKind.allCases))
        #expect(workspace.fields == .listed(MacSceneSourceSchema.workspaceFields))
        #expect(accessibility.fields == .listed(MacSceneSourceSchema.accessibilityFields))
        #expect(dirty.fields == .listed(MacSceneSourceSchema.screenDirtyRegionFields))
        #expect(!MacSceneSourceSchema.screenDirtyRegionFields.contains(
            MacSceneSourceSchema.geometryBoundsField
        ))
        #expect(!workspace.capabilities.contains(.text))
        #expect(!accessibility.capabilities.contains(.windowTopology))
        #expect(dirty.capabilities == [
            .dirtyRegions,
            .coverageReporting,
            .onDemandRefresh,
            .checkpoints,
        ])
        #expect(!dirty.capabilities.contains(.text))
        #expect(!dirty.capabilities.contains(.imageUnderstanding))
    }

    @Test("start requested during stop is not lost")
    func startDuringStopEndsRunning() async {
        let recorder = ControllerSourceRecorder()
        let stopGate = ControllerAsyncGate()
        let controller = MacSceneDiscoveryController(
            factories: gatedFactories(
                recorder: recorder,
                stopGate: stopGate
            )
        )
        _ = await controller.start()

        async let stopping = controller.stop()
        await stopGate.waitUntilEntered()
        async let starting = controller.start()
        await stopGate.release()
        _ = await starting
        _ = await stopping

        let status = await controller.status()
        #expect(status.phase == .running)
        #expect(status.sources.allSatisfy { $0.phase == .running })
        _ = await controller.stop()
    }

    @Test("stop requested during start is not lost")
    func stopDuringStartEndsStopped() async {
        let recorder = ControllerSourceRecorder()
        let startGate = ControllerAsyncGate()
        let controller = MacSceneDiscoveryController(
            factories: gatedFactories(
                recorder: recorder,
                startGate: startGate
            )
        )

        async let starting = controller.start()
        await startGate.waitUntilEntered()
        async let stopping = controller.stop()
        await startGate.release()
        _ = await starting
        _ = await stopping

        let status = await controller.status()
        #expect(status.phase == .stopped)
        #expect(status.sources.allSatisfy { $0.phase == .inactive })
        #expect(await controller.memory.statistics().registeredSources == 0)
    }

    @Test("Quartz-global cache probe is synchronous and cache-only")
    func synchronousCacheProbe() throws {
        let device = DevicePrincipalID()
        let controller = MacSceneDiscoveryController(
            device: device,
            factories: factories(recorder: ControllerSourceRecorder())
        )
        let snapshot = try controller.coordinateRegistry.update(with: [
            MacDisplaySnapshot(
                displayID: 101,
                displayUUID: UUID(uuidString: "00000000-0000-0000-0000-000000000101"),
                globalBounds: try #require(MacGlobalRect(
                    x: -100,
                    y: -100,
                    width: 200,
                    height: 200
                )),
                pixelWidth: 400,
                pixelHeight: 400,
                rotationQuarterTurns: 0,
                scaleFactor: 2,
                isMain: true
            ),
        ])

        let globalPoint = try #require(MacGlobalPoint(x: 0, y: 0))
        let probe = try #require(controller.probeCache(atQuartzGlobal: globalPoint))
        let expectedPoint = try ScenePoint(x: 100, y: 100)
        #expect(probe.coordinateSpace == snapshot.virtualDesktop.descriptor.coordinateSpace)
        #expect(probe.point == expectedPoint)
        #expect(probe.candidates.isEmpty)
        #expect(!probe.authorizesSideEffects)
    }

    private func factories(
        recorder: ControllerSourceRecorder,
        registryProbe: CoordinateRegistryProbe = CoordinateRegistryProbe(),
        failingRole: MacSceneDiscoverySourceRole? = nil
    ) -> MacSceneDiscoverySourceFactories {
        MacSceneDiscoverySourceFactories(
            makeWorkspace: { context in
                registryProbe.record(context.coordinateRegistry)
                return try ControllerMockSource(
                    role: .workspace,
                    context: context,
                    recorder: recorder,
                    failsOnStart: failingRole == .workspace
                )
            },
            makeAccessibility: { context in
                registryProbe.record(context.coordinateRegistry)
                return try ControllerMockSource(
                    role: .accessibility,
                    context: context,
                    recorder: recorder,
                    failsOnStart: failingRole == .accessibility
                )
            },
            makeScreenDirtyRegions: { context in
                registryProbe.record(context.coordinateRegistry)
                return try ControllerMockSource(
                    role: .screenDirtyRegions,
                    context: context,
                    recorder: recorder,
                    failsOnStart: failingRole == .screenDirtyRegions
                )
            }
        )
    }

    private func gatedFactories(
        recorder: ControllerSourceRecorder,
        startGate: ControllerAsyncGate? = nil,
        stopGate: ControllerAsyncGate? = nil
    ) -> MacSceneDiscoverySourceFactories {
        MacSceneDiscoverySourceFactories(
            makeWorkspace: { context in
                try ControllerMockSource(
                    role: .workspace,
                    context: context,
                    recorder: recorder,
                    failsOnStart: false,
                    startGate: startGate,
                    stopGate: stopGate
                )
            },
            makeAccessibility: { context in
                try ControllerMockSource(
                    role: .accessibility,
                    context: context,
                    recorder: recorder,
                    failsOnStart: false
                )
            },
            makeScreenDirtyRegions: { context in
                try ControllerMockSource(
                    role: .screenDirtyRegions,
                    context: context,
                    recorder: recorder,
                    failsOnStart: false
                )
            }
        )
    }

    private func manifest(
        role: MacSceneDiscoverySourceRole,
        device: DevicePrincipalID,
        session: SceneSessionID
    ) throws -> SceneSourceManifest {
        try ControllerMockSource.makeManifest(
            role: role,
            device: device,
            sessionID: session
        )
    }
}

private enum ControllerMockSourceError: Error {
    case configuredFailure
}

private actor ControllerMockSource: SceneDiscoverySource {
    nonisolated let manifest: SceneSourceManifest

    private let role: MacSceneDiscoverySourceRole
    private let recorder: ControllerSourceRecorder
    private let failsOnStart: Bool
    private let startGate: ControllerAsyncGate?
    private let stopGate: ControllerAsyncGate?

    init(
        role: MacSceneDiscoverySourceRole,
        context: MacSceneDiscoveryContext,
        recorder: ControllerSourceRecorder,
        failsOnStart: Bool,
        startGate: ControllerAsyncGate? = nil,
        stopGate: ControllerAsyncGate? = nil
    ) throws {
        self.role = role
        self.recorder = recorder
        self.failsOnStart = failsOnStart
        self.startGate = startGate
        self.stopGate = stopGate
        self.manifest = try Self.makeManifest(
            role: role,
            device: context.device,
            sessionID: context.sessionID
        )
    }

    static func makeManifest(
        role: MacSceneDiscoverySourceRole,
        device: DevicePrincipalID,
        sessionID: SceneSessionID
    ) throws -> SceneSourceManifest {
        let sourceID: SceneSourceID
        let kind: SceneSourceKind
        let capabilities: [SceneSourceCapability]
        switch role {
        case .workspace:
            sourceID = SceneSourceID(rawValue: UUID(
                uuidString: "A1000000-0000-0000-0000-000000000001"
            )!)
            kind = .windowMetadata
            capabilities = [
                .applicationLifecycle,
                .windowTopology,
                .geometry,
                .coverageReporting,
                .onDemandRefresh,
                .checkpoints,
            ]
        case .accessibility:
            sourceID = SceneSourceID(rawValue: UUID(
                uuidString: "A1000000-0000-0000-0000-000000000002"
            )!)
            kind = .accessibility
            capabilities = [
                .structuredHierarchy,
                .geometry,
                .text,
                .sensitivityClassification,
                .coverageReporting,
                .onDemandRefresh,
                .checkpoints,
            ]
        case .screenDirtyRegions:
            sourceID = SceneSourceID(rawValue: UUID(
                uuidString: "A1000000-0000-0000-0000-000000000003"
            )!)
            kind = .screenPixels
            capabilities = [
                .dirtyRegions,
                .coverageReporting,
                .onDemandRefresh,
                .checkpoints,
            ]
        }
        return try SceneSourceManifest(
            sourceEpoch: SceneSourceEpoch(
                source: SceneSourceIdentity(device: device, source: sourceID)
            ),
            sessionID: sessionID,
            displayName: "controller test source",
            kind: kind,
            capabilities: capabilities
        )
    }

    func start(handle: SceneSourceHandle, sink _: any SceneEventSink) async throws {
        guard handle.sourceEpoch == manifest.sourceEpoch else {
            throw ControllerMockSourceError.configuredFailure
        }
        await recorder.started(role, epoch: manifest.sourceEpoch)
        if let startGate { await startGate.wait() }
        if failsOnStart { throw ControllerMockSourceError.configuredFailure }
    }

    func refresh(_ request: RefreshRequest) async -> RefreshDisposition { .unsupported }

    func stop() async {
        await recorder.stopped(role, epoch: manifest.sourceEpoch)
        if let stopGate { await stopGate.wait() }
    }
}

private actor ControllerAsyncGate {
    private var entered = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    func waitUntilEntered() async {
        while !entered { await Task.yield() }
    }

    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}

private actor ControllerSourceRecorder {
    private var starts: [MacSceneDiscoverySourceRole: [SceneSourceEpoch]] = [:]
    private var stops: [MacSceneDiscoverySourceRole: [SceneSourceEpoch]] = [:]

    func started(_ role: MacSceneDiscoverySourceRole, epoch: SceneSourceEpoch) {
        starts[role, default: []].append(epoch)
    }

    func stopped(_ role: MacSceneDiscoverySourceRole, epoch: SceneSourceEpoch) {
        // Controller cleanup is intentionally idempotent; count unique epochs so a
        // failed start followed by cleanup cannot inflate lifecycle assertions.
        if !(stops[role] ?? []).contains(epoch) {
            stops[role, default: []].append(epoch)
        }
    }

    func startCount(_ role: MacSceneDiscoverySourceRole) -> Int {
        starts[role]?.count ?? 0
    }

    func stopCount(_ role: MacSceneDiscoverySourceRole) -> Int {
        stops[role]?.count ?? 0
    }
}

private final class CoordinateRegistryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var identifiers: Set<ObjectIdentifier> = []

    func record(_ registry: MacDesktopCoordinateRegistry) {
        lock.lock()
        identifiers.insert(ObjectIdentifier(registry))
        lock.unlock()
    }

    func uniqueRegistryCount() -> Int {
        lock.lock()
        let count = identifiers.count
        lock.unlock()
        return count
    }
}

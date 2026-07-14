import Foundation
import PointerSceneContracts
import PointerSceneMemory

public enum MacSceneDiscoverySourceRole: String, CaseIterable, Hashable, Sendable {
    case workspace
    case accessibility
    case screenDirtyRegions
}

public enum MacSceneDiscoverySourcePhase: String, Hashable, Sendable {
    case inactive
    case starting
    case running
    case failed
}

public enum MacSceneDiscoveryControllerPhase: String, Hashable, Sendable {
    case stopped
    case starting
    case running
    case stopping
}

public enum MacSceneDiscoveryControllerError: Error, Equatable, Sendable {
    case unexpectedSourceKind(
        role: MacSceneDiscoverySourceRole,
        actual: SceneSourceKind
    )
    case wrongDevice(role: MacSceneDiscoverySourceRole)
    case wrongSession(role: MacSceneDiscoverySourceRole)
}

public struct MacSceneDiscoverySourceStatus: Hashable, Sendable {
    public let role: MacSceneDiscoverySourceRole
    public let phase: MacSceneDiscoverySourcePhase
    public let sourceEpoch: SceneSourceEpoch?
    public let failureDescription: String?

    fileprivate init(
        role: MacSceneDiscoverySourceRole,
        phase: MacSceneDiscoverySourcePhase,
        sourceEpoch: SceneSourceEpoch? = nil,
        failureDescription: String? = nil
    ) {
        self.role = role
        self.phase = phase
        self.sourceEpoch = sourceEpoch
        self.failureDescription = failureDescription
    }
}

public struct MacSceneDiscoveryStatus: Hashable, Sendable {
    public let phase: MacSceneDiscoveryControllerPhase
    public let generation: UInt64
    public let sources: [MacSceneDiscoverySourceStatus]

    public func source(
        _ role: MacSceneDiscoverySourceRole
    ) -> MacSceneDiscoverySourceStatus? {
        sources.first { $0.role == role }
    }
}

/// Construction context shared by all local discovery factories. The coordinate
/// registry is deliberately one object: workspace, AX, and screen-dirty metadata must
/// describe the same virtual desktop surface and coordinate-space revision.
public struct MacSceneDiscoveryContext: Sendable {
    public let device: DevicePrincipalID
    public let sessionID: SceneSessionID
    public let coordinateRegistry: MacDesktopCoordinateRegistry

    public init(
        device: DevicePrincipalID,
        sessionID: SceneSessionID,
        coordinateRegistry: MacDesktopCoordinateRegistry
    ) {
        self.device = device
        self.sessionID = sessionID
        self.coordinateRegistry = coordinateRegistry
    }
}

public struct MacSceneDiscoverySourceFactories: Sendable {
    public typealias Factory = @Sendable (
        MacSceneDiscoveryContext
    ) throws -> any SceneDiscoverySource

    public let makeWorkspace: Factory
    public let makeAccessibility: Factory
    public let makeScreenDirtyRegions: Factory

    public init(
        makeWorkspace: @escaping Factory,
        makeAccessibility: @escaping Factory,
        makeScreenDirtyRegions: @escaping Factory
    ) {
        self.makeWorkspace = makeWorkspace
        self.makeAccessibility = makeAccessibility
        self.makeScreenDirtyRegions = makeScreenDirtyRegions
    }

    public static var live: Self {
        Self(
            makeWorkspace: { context in
                try WorkspaceSceneSource(
                    device: context.device,
                    sessionID: context.sessionID,
                    coordinateRegistry: context.coordinateRegistry
                )
            },
            makeAccessibility: { context in
                try AXSceneSource(
                    device: context.device,
                    sessionID: context.sessionID,
                    coordinateRegistry: context.coordinateRegistry
                )
            },
            makeScreenDirtyRegions: { context in
                try ScreenDirtyRegionSceneSource(
                    device: context.device,
                    sessionID: context.sessionID,
                    coordinateRegistry: context.coordinateRegistry
                )
            }
        )
    }
}

/// Owns the local observation session independently from pointer capture and
/// presentation. It has no pointer callbacks, windows, sockets, persistence, or
/// MainActor work. A controller lifetime has one device principal and one memory
/// session; every source restart receives a fresh source epoch.
public actor MacSceneDiscoveryController {
    private enum Lifecycle: Equatable, Sendable {
        case stopped
        case starting(UUID)
        case running
        case stopping(UUID)

        var publicPhase: MacSceneDiscoveryControllerPhase {
            switch self {
            case .stopped: .stopped
            case .starting: .starting
            case .running: .running
            case .stopping: .stopping
            }
        }
    }

    private struct ActiveSource: Sendable {
        let source: any SceneDiscoverySource
        let handle: SceneSourceHandle
    }

    public nonisolated let device: DevicePrincipalID
    public nonisolated let sessionID: SceneSessionID
    public nonisolated let memory: SceneMemoryStore
    public nonisolated let memoryMirror: SceneMemorySnapshotMirror
    public nonisolated let coordinateRegistry: MacDesktopCoordinateRegistry

    private let factories: MacSceneDiscoverySourceFactories
    private var lifecycle: Lifecycle = .stopped
    /// Desired terminal state survives actor reentrancy while source start/stop awaits.
    private var wantsToRun = false
    private var generation: UInt64 = 0
    private var activeSources: [MacSceneDiscoverySourceRole: ActiveSource] = [:]
    private var sourceStatuses: [MacSceneDiscoverySourceRole: MacSceneDiscoverySourceStatus]

    public init(
        device: DevicePrincipalID = DevicePrincipalID(),
        sessionID: SceneSessionID = SceneSessionID(),
        memoryLimits: SceneMemoryLimits = .default,
        factories: MacSceneDiscoverySourceFactories = .live
    ) {
        self.device = device
        self.sessionID = sessionID
        let memory = SceneMemoryStore(sessionID: sessionID, limits: memoryLimits)
        self.memory = memory
        self.memoryMirror = SceneMemorySnapshotMirror(store: memory)
        self.coordinateRegistry = MacDesktopCoordinateRegistry(device: device)
        self.factories = factories
        self.sourceStatuses = Dictionary(uniqueKeysWithValues:
            MacSceneDiscoverySourceRole.allCases.map { role in
                (role, MacSceneDiscoverySourceStatus(role: role, phase: .inactive))
            }
        )
    }

    /// Idempotent while running. A caller that wants fresh epochs must first await
    /// `stop()` (or use `restart()`). Source failures remain isolated: AX permission
    /// loss cannot tear down the workspace census, and the inverse is also true.
    @discardableResult
    public func start() async -> MacSceneDiscoveryStatus {
        wantsToRun = true
        guard lifecycle == .stopped else { return makeStatus() }
        return await performStart()
    }

    private func performStart() async -> MacSceneDiscoveryStatus {
        guard lifecycle == .stopped, wantsToRun else { return makeStatus() }

        generation = generation == UInt64.max ? UInt64.max : generation + 1
        let transition = UUID()
        lifecycle = .starting(transition)
        for role in MacSceneDiscoverySourceRole.allCases {
            sourceStatuses[role] = MacSceneDiscoverySourceStatus(
                role: role,
                phase: .inactive
            )
        }

        await start(.workspace, transition: transition)
        await start(.accessibility, transition: transition)
        await start(.screenDirtyRegions, transition: transition)

        if lifecycle == .starting(transition), wantsToRun {
            lifecycle = .running
        } else if lifecycle == .starting(transition) {
            // A stop intent arrived between the last source await and publication.
            return await performStop()
        }
        return makeStatus()
    }

    /// Ends producer coverage before closing receiver registrations. Closed epochs
    /// are never reused, so a later `start()` necessarily constructs new sources.
    @discardableResult
    public func stop() async -> MacSceneDiscoveryStatus {
        wantsToRun = false
        guard lifecycle != .stopped else { return makeStatus() }
        guard case .stopping = lifecycle else {
            return await performStop()
        }
        return makeStatus()
    }

    private func performStop() async -> MacSceneDiscoveryStatus {
        guard lifecycle != .stopped else {
            return wantsToRun ? await performStart() : makeStatus()
        }

        let transition = UUID()
        lifecycle = .stopping(transition)
        let sources = activeSources
        activeSources.removeAll(keepingCapacity: true)

        for role in MacSceneDiscoverySourceRole.allCases {
            guard let active = sources[role] else { continue }
            await active.source.stop()
            _ = await memory.closeSource(active.handle, reason: .producerPaused)
            _ = await memoryMirror.synchronizeSnapshot()
        }

        if lifecycle == .stopping(transition) {
            for role in MacSceneDiscoverySourceRole.allCases {
                sourceStatuses[role] = MacSceneDiscoverySourceStatus(
                    role: role,
                    phase: .inactive
                )
            }
            lifecycle = .stopped
        }
        return wantsToRun ? await performStart() : makeStatus()
    }

    @discardableResult
    public func restart() async -> MacSceneDiscoveryStatus {
        wantsToRun = false
        _ = await stop()
        return await start()
    }

    public func status() -> MacSceneDiscoveryStatus { makeStatus() }

    /// Synchronous, cache-only Quartz-global probe. It performs no AX query, screen
    /// capture, actor hop, I/O, or action authorization.
    public nonisolated func probeCache(
        atQuartzGlobal point: MacGlobalPoint,
        limit: Int = 8
    ) -> SceneMemoryProbe? {
        guard let mapped = coordinateRegistry.snapshot()?.mapQuartzGlobalPoint(point) else {
            return nil
        }
        return memoryMirror.probe(
            at: mapped.point,
            in: mapped.coordinateSpace,
            limit: limit
        )
    }

    private func start(
        _ role: MacSceneDiscoverySourceRole,
        transition: UUID
    ) async {
        guard lifecycle == .starting(transition) else { return }

        var pendingSource: (any SceneDiscoverySource)?
        var pendingHandle: SceneSourceHandle?
        do {
            let source = try makeSource(role)
            pendingSource = source
            try validate(source.manifest, for: role)
            let epoch = source.manifest.sourceEpoch
            sourceStatuses[role] = MacSceneDiscoverySourceStatus(
                role: role,
                phase: .starting,
                sourceEpoch: epoch
            )

            let registration = try await memory.register(
                manifest: source.manifest,
                authorization: Self.authorization(for: role, manifest: source.manifest)
            )
            pendingHandle = registration.handle
            guard lifecycle == .starting(transition) else {
                await source.stop()
                _ = await memory.closeSource(registration.handle, reason: .producerPaused)
                _ = await memoryMirror.synchronizeSnapshot()
                return
            }

            activeSources[role] = ActiveSource(
                source: source,
                handle: registration.handle
            )
            try await source.start(handle: registration.handle, sink: memoryMirror)

            guard lifecycle == .starting(transition) else {
                await source.stop()
                _ = await memory.closeSource(registration.handle, reason: .producerPaused)
                _ = await memoryMirror.synchronizeSnapshot()
                if activeSources[role]?.handle == registration.handle {
                    activeSources[role] = nil
                }
                return
            }
            sourceStatuses[role] = MacSceneDiscoverySourceStatus(
                role: role,
                phase: .running,
                sourceEpoch: epoch
            )
        } catch {
            if let pendingSource { await pendingSource.stop() }
            if let pendingHandle {
                _ = await memory.closeSource(pendingHandle, reason: .producerPaused)
                _ = await memoryMirror.synchronizeSnapshot()
                if activeSources[role]?.handle == pendingHandle {
                    activeSources[role] = nil
                }
            }
            guard lifecycle == .starting(transition) else { return }
            sourceStatuses[role] = MacSceneDiscoverySourceStatus(
                role: role,
                phase: .failed,
                sourceEpoch: pendingSource?.manifest.sourceEpoch,
                failureDescription: String(reflecting: error)
            )
        }
    }

    private func makeSource(
        _ role: MacSceneDiscoverySourceRole
    ) throws -> any SceneDiscoverySource {
        let context = MacSceneDiscoveryContext(
            device: device,
            sessionID: sessionID,
            coordinateRegistry: coordinateRegistry
        )
        switch role {
        case .workspace:
            return try factories.makeWorkspace(context)
        case .accessibility:
            return try factories.makeAccessibility(context)
        case .screenDirtyRegions:
            return try factories.makeScreenDirtyRegions(context)
        }
    }

    private func validate(
        _ manifest: SceneSourceManifest,
        for role: MacSceneDiscoverySourceRole
    ) throws {
        guard manifest.kind == MacSceneSourceSchema.kind(for: role) else {
            throw MacSceneDiscoveryControllerError.unexpectedSourceKind(
                role: role,
                actual: manifest.kind
            )
        }
        guard manifest.sessionID == sessionID else {
            throw MacSceneDiscoveryControllerError.wrongSession(role: role)
        }
        guard manifest.sourceEpoch.source.device == device else {
            throw MacSceneDiscoveryControllerError.wrongDevice(role: role)
        }
    }

    private func makeStatus() -> MacSceneDiscoveryStatus {
        MacSceneDiscoveryStatus(
            phase: lifecycle.publicPhase,
            generation: generation,
            sources: MacSceneDiscoverySourceRole.allCases.compactMap {
                sourceStatuses[$0]
            }
        )
    }
}

extension MacSceneDiscoveryController {
    static func authorization(
        for role: MacSceneDiscoverySourceRole,
        manifest: SceneSourceManifest
    ) -> SceneSourceGrantPolicy {
        return SceneSourceGrantPolicy(
            capabilities: MacSceneSourceSchema.capabilities(for: role)
                .intersection(Set(manifest.capabilities)),
            eventKinds: [.observation, .invalidation, .coverage, .checkpoint],
            evidenceKinds: MacSceneSourceSchema.evidenceKinds(for: role),
            fields: .listed(MacSceneSourceSchema.fields(for: role)),
            surfaces: .ownDevice
        )
    }
}

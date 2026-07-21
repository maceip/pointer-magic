import Foundation
import PointerMacSceneDiscovery
import PointerSceneContracts
import Testing

@Suite("workspace checkpoint builder")
struct MacSceneObservationBuilderTests {
    @Test("spanning windows stay whole on the virtual desktop")
    func spanningWindow() throws {
        let epoch = sourceEpoch()
        let displays = [
            display(id: 1, uuidSuffix: 1, x: -800, width: 800),
            display(id: 2, uuidSuffix: 2, x: 0, width: 1_000),
        ]
        let window = MacWindowSnapshot(
            windowID: 42,
            ownerProcessID: 100,
            ownerName: "Example",
            globalBounds: MacGlobalRect(x: -100, y: 50, width: 250, height: 100)!,
            layer: 0,
            alpha: 1,
            isOnScreen: true,
            sharingState: 1,
            frontToBackIndex: 0
        )
        let census = MacDesktopCensus(
            displays: displays,
            applications: [MacApplicationSnapshot(
                processID: 100,
                bundleIdentifier: "example.app",
                localizedName: "Example",
                isActive: true,
                isHidden: false
            )],
            windows: [window]
        )
        let checkpoint = try MacSceneObservationBuilder(
            device: epoch.source.device,
            sourceEpoch: epoch
        ).makeCheckpoint(
            from: census,
            coordinateSnapshot: try coordinateSnapshot(
                device: epoch.source.device,
                displays: displays,
                desiredRevision: 3
            ),
            observedAtSourceMonotonicNs: 99
        )
        let windowID = try SceneFieldKey("window.id")
        let geometry = try SceneFieldKey("geometry.bounds")
        let observation = try #require(checkpoint.observations.first { observation in
            observation.claims.contains { claim in
                claim.field == windowID && claim.value == .unsignedInteger(42)
            }
        })

        let region = try #require(observation.claims.first(where: { $0.field == geometry }))
        guard case let .region(value)? = region.value else {
            Issue.record("window geometry was not a region")
            return
        }
        #expect(value.rect.origin.x == 700)
        #expect(value.rect.size.width == 250)
        #expect(value.coordinateSpace.revision == 3)
    }

    @Test("oversized projections fail instead of masquerading as complete checkpoints")
    func oversizedCheckpointFails() throws {
        let epoch = sourceEpoch()
        let applications = (1 ... 500).map { value in
            MacApplicationSnapshot(
                processID: Int32(value),
                bundleIdentifier: nil,
                localizedName: nil,
                isActive: false,
                isHidden: false
            )
        }
        let census = MacDesktopCensus(
            displays: [display(id: 1, uuidSuffix: 1, x: 0, width: 1_000)],
            applications: applications,
            windows: []
        )

        #expect(throws: MacSceneObservationBuilderError.self) {
            let registry = MacDesktopCoordinateRegistry(device: epoch.source.device)
            _ = try MacSceneObservationBuilder(
                device: epoch.source.device,
                sourceEpoch: epoch
            ).makeCheckpoint(
                from: census,
                coordinateSnapshot: registry.update(with: census.displays),
                observedAtSourceMonotonicNs: 1
            )
        }
    }

    @Test("display observation identity follows the stable surface instead of display ID")
    func displayIdentityUsesStableSurface() throws {
        let epoch = sourceEpoch()
        let registry = MacDesktopCoordinateRegistry(device: epoch.source.device)
        let builder = MacSceneObservationBuilder(
            device: epoch.source.device,
            sourceEpoch: epoch
        )
        let firstDisplay = display(id: 1, uuidSuffix: 9, x: 0, width: 1_000)
        let renumberedDisplay = display(id: 99, uuidSuffix: 9, x: 0, width: 1_000)
        let firstCensus = MacDesktopCensus(
            displays: [firstDisplay],
            applications: [],
            windows: []
        )
        let renumberedCensus = MacDesktopCensus(
            displays: [renumberedDisplay],
            applications: [],
            windows: []
        )

        let first = try builder.makeCheckpoint(
            from: firstCensus,
            coordinateSnapshot: registry.update(with: firstCensus.displays),
            observedAtSourceMonotonicNs: 1
        )
        let renumbered = try builder.makeCheckpoint(
            from: renumberedCensus,
            coordinateSnapshot: registry.update(with: renumberedCensus.displays),
            observedAtSourceMonotonicNs: 2
        )

        let firstObservation = try displayObservation(in: first)
        let renumberedObservation = try displayObservation(in: renumbered)
        #expect(firstObservation.subject.objectID == renumberedObservation.subject.objectID)
        #expect(try displayID(in: firstObservation) == 1)
        #expect(try displayID(in: renumberedObservation) == 99)
    }

    private func sourceEpoch() -> SceneSourceEpoch {
        SceneSourceEpoch(source: SceneSourceIdentity(
            device: DevicePrincipalID(rawValue: UUID(
                uuidString: "00000000-0000-0000-0000-000000000001"
            )!),
            source: SceneSourceID(rawValue: UUID(
                uuidString: "00000000-0000-0000-0000-000000000002"
            )!)
        ))
    }

    private func coordinateSnapshot(
        device: DevicePrincipalID,
        displays: [MacDisplaySnapshot],
        desiredRevision: UInt64
    ) throws -> MacDesktopCoordinateSnapshot {
        let registry = MacDesktopCoordinateRegistry(device: device)
        var snapshot = try registry.update(with: displays)
        while snapshot.topologyRevision < desiredRevision {
            registry.invalidateCurrentTopology()
            snapshot = try registry.update(with: displays)
        }
        return snapshot
    }

    private func display(
        id: UInt32,
        uuidSuffix: UInt32,
        x: Double,
        width: Double
    ) -> MacDisplaySnapshot {
        MacDisplaySnapshot(
            displayID: id,
            displayUUID: UUID(uuidString: String(
                format: "00000000-0000-0000-0000-%012u",
                uuidSuffix
            )),
            globalBounds: MacGlobalRect(x: x, y: 0, width: width, height: 600)!,
            pixelWidth: Int(width * 2),
            pixelHeight: 1_200,
            rotationQuarterTurns: 0,
            scaleFactor: 2,
            isMain: id == 2
        )
    }

    private func displayObservation(
        in checkpoint: SceneCheckpoint
    ) throws -> SceneObservation {
        let objectKind = try SceneFieldKey("object.kind")
        return try #require(checkpoint.observations.first { observation in
            observation.claims.contains { claim in
                claim.field == objectKind && claim.value == .text("display")
            }
        })
    }

    private func displayID(in observation: SceneObservation) throws -> UInt64 {
        let field = try SceneFieldKey("display.id")
        let claim = try #require(observation.claims.first { $0.field == field })
        guard case let .unsignedInteger(value) = claim.value else {
            Issue.record("display.id was not an unsigned integer")
            return 0
        }
        return value
    }
}

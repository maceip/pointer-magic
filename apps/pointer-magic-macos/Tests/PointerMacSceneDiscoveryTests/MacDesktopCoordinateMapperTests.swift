import Foundation
import PointerMacSceneDiscovery
import PointerSceneContracts
import Testing

@Suite("shared Mac desktop coordinate registry")
struct MacDesktopCoordinateRegistryTests {
    @Test("maps negative-origin Quartz points and spanning rectangles")
    func mapsGlobalGeometry() throws {
        let device = fixedDevice()
        let registry = MacDesktopCoordinateRegistry(device: device)
        let left = display(
            id: 10,
            uuid: "00000000-0000-0000-0000-000000000010",
            x: -800,
            width: 800,
            isMain: false
        )
        let main = display(
            id: 20,
            uuid: "00000000-0000-0000-0000-000000000020",
            x: 0,
            width: 1_000,
            isMain: true
        )

        let snapshot = try registry.update(with: [main, left])
        let globalPoint = try #require(MacGlobalPoint(x: -100, y: 50))
        let point = try #require(snapshot.mapQuartzGlobalPoint(globalPoint))
        #expect(point.point.x == 700)
        #expect(point.point.y == 50)
        #expect(point.coordinateSpace == snapshot.virtualDesktop.descriptor.coordinateSpace)

        let spanning = try #require(
            MacGlobalRect(x: -100, y: 50, width: 250, height: 100)
        )
        let virtual = try #require(snapshot.mapQuartzGlobalRect(spanning))
        #expect(virtual.rect.origin.x == 700)
        #expect(virtual.rect.origin.y == 50)
        #expect(virtual.rect.size.width == 250)
        #expect(snapshot.virtualDesktop.globalBounds.width == 1_800)

        let fragments = snapshot.displayFragments(forQuartzGlobalRect: spanning)
        #expect(fragments.map(\.displayID) == [10, 20])
        #expect(fragments[0].region.rect.origin.x == 700)
        #expect(fragments[0].region.rect.size.width == 100)
        #expect(fragments[1].region.rect.origin.x == 0)
        #expect(fragments[1].region.rect.size.width == 150)

        let offscreenRect = try #require(
            MacGlobalRect(x: -850, y: 10, width: 100, height: 50)
        )
        let partlyOffscreen = try #require(snapshot.mapQuartzGlobalRect(offscreenRect))
        #expect(partlyOffscreen.rect.origin.x == -50)
        let outsidePoint = try #require(MacGlobalPoint(x: -801, y: 10))
        #expect(snapshot.mapQuartzGlobalPoint(outsidePoint) == nil)
    }

    @Test("source epochs share device-owned identity and exact revision")
    func sourceEpochsShareCoordinates() throws {
        let device = fixedDevice()
        let registry = MacDesktopCoordinateRegistry(device: device)
        let census = MacDesktopCensus(
            displays: [display(
                id: 20,
                uuid: "00000000-0000-0000-0000-000000000020",
                x: 0,
                width: 1_000,
                isMain: true
            )],
            applications: [],
            windows: []
        )
        let firstSnapshot = try registry.update(with: census.displays)
        let secondSnapshot = try registry.update(with: census.displays)
        #expect(firstSnapshot.topologyRevision == secondSnapshot.topologyRevision)
        #expect(firstSnapshot.virtualDesktop.surface == secondSnapshot.virtualDesktop.surface)
        #expect(
            firstSnapshot.virtualDesktop.descriptor.coordinateSpace ==
                secondSnapshot.virtualDesktop.descriptor.coordinateSpace
        )
        let independentlyRebuilt = try MacDesktopCoordinateRegistry(device: device)
            .update(with: census.displays)
        #expect(independentlyRebuilt.virtualDesktop.surface == firstSnapshot.virtualDesktop.surface)
        #expect(
            independentlyRebuilt.virtualDesktop.descriptor.coordinateSpace.coordinateSpaceID ==
                firstSnapshot.virtualDesktop.descriptor.coordinateSpace.coordinateSpaceID
        )

        let firstEpoch = SceneSourceEpoch(source: SceneSourceIdentity(
            device: device,
            source: SceneSourceID()
        ))
        let secondEpoch = SceneSourceEpoch(source: SceneSourceIdentity(
            device: device,
            source: SceneSourceID()
        ))
        #expect(firstEpoch != secondEpoch)

        let firstCheckpoint = try MacSceneObservationBuilder(
            device: device,
            sourceEpoch: firstEpoch
        ).makeCheckpoint(
            from: census,
            coordinateSnapshot: firstSnapshot,
            observedAtSourceMonotonicNs: 1
        )
        let secondCheckpoint = try MacSceneObservationBuilder(
            device: device,
            sourceEpoch: secondEpoch
        ).makeCheckpoint(
            from: census,
            coordinateSnapshot: secondSnapshot,
            observedAtSourceMonotonicNs: 1
        )
        let firstSpace = try #require(geometrySpace(in: firstCheckpoint))
        let secondSpace = try #require(geometrySpace(in: secondCheckpoint))
        #expect(firstSpace == secondSpace)
    }

    @Test("topology changes advance revision while old snapshots remain distinct")
    func topologyRevisionSeparatesStaleGeometry() throws {
        let registry = MacDesktopCoordinateRegistry(device: fixedDevice())
        let initial = display(
            id: 20,
            uuid: "00000000-0000-0000-0000-000000000020",
            x: 0,
            width: 1_000,
            isMain: true
        )
        let old = try registry.update(with: [initial])
        let globalPoint = try #require(MacGlobalPoint(x: 100, y: 100))
        let oldPoint = try #require(old.mapQuartzGlobalPoint(globalPoint))

        let changed = display(
            id: 20,
            uuid: "00000000-0000-0000-0000-000000000020",
            x: -200,
            width: 1_200,
            isMain: true
        )
        let current = try registry.update(with: [changed])
        let currentPoint = try #require(current.mapQuartzGlobalPoint(globalPoint))

        #expect(current.topologyRevision == old.topologyRevision + 1)
        #expect(current.virtualDesktop.surface == old.virtualDesktop.surface)
        #expect(currentPoint.coordinateSpace.coordinateSpaceID == oldPoint.coordinateSpace.coordinateSpaceID)
        #expect(currentPoint.coordinateSpace.revision == oldPoint.coordinateSpace.revision + 1)
        #expect(currentPoint.coordinateSpace != oldPoint.coordinateSpace)
        #expect(oldPoint.point.x == 100)
        #expect(currentPoint.point.x == 300)
        #expect(registry.snapshot()?.topologyRevision == current.topologyRevision)
    }

    @Test("a late secondary seed cannot roll back the workspace topology")
    func lateSecondarySeedCannotRollBack() throws {
        let registry = MacDesktopCoordinateRegistry(device: fixedDevice())
        let staleSecondaryCensus = [display(
            id: 20,
            uuid: "00000000-0000-0000-0000-000000000020",
            x: 0,
            width: 1_000,
            isMain: true
        )]
        let workspaceCensus = [display(
            id: 20,
            uuid: "00000000-0000-0000-0000-000000000020",
            x: -200,
            width: 1_200,
            isMain: true
        )]

        // The AX census began first but completes after workspace publishes.
        let workspace = try registry.update(with: workspaceCensus)
        let lateSecondary = try registry.seedIfEmpty(with: staleSecondaryCensus)

        #expect(lateSecondary.topologyRevision == workspace.topologyRevision)
        #expect(lateSecondary.virtualDesktop.globalBounds == workspace.virtualDesktop.globalBounds)
        #expect(registry.snapshot()?.virtualDesktop.globalBounds == workspace.virtualDesktop.globalBounds)
    }

    private func geometrySpace(in checkpoint: SceneCheckpoint) -> SurfaceCoordinateSpace? {
        let field = try! SceneFieldKey("geometry.bounds")
        return checkpoint.observations.lazy.compactMap { observation in
            observation.claims.first(where: { $0.field == field }).flatMap { claim in
                guard case let .region(region)? = claim.value else { return nil }
                return region.coordinateSpace
            }
        }.first
    }

    private func fixedDevice() -> DevicePrincipalID {
        DevicePrincipalID(rawValue: UUID(
            uuidString: "00000000-0000-0000-0000-000000000001"
        )!)
    }

    private func display(
        id: UInt32,
        uuid: String?,
        x: Double,
        width: Double,
        isMain: Bool
    ) -> MacDisplaySnapshot {
        MacDisplaySnapshot(
            displayID: id,
            displayUUID: uuid.flatMap(UUID.init(uuidString:)),
            globalBounds: MacGlobalRect(x: x, y: 0, width: width, height: 700)!,
            pixelWidth: Int(width * 2),
            pixelHeight: 1_400,
            rotationQuarterTurns: 0,
            scaleFactor: 2,
            isMain: isMain
        )
    }
}

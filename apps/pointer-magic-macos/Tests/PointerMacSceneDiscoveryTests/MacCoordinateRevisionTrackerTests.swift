import Foundation
import PointerMacSceneDiscovery
import PointerSceneContracts
import Testing

@Suite("physical display coordinate identity")
struct MacPhysicalDisplayCoordinateIdentityTests {
    @Test("public display UUID is stable and fallback never aliases a reattachment")
    func stableUUIDAndSafeFallback() throws {
        let device = DevicePrincipalID()
        let registry = MacDesktopCoordinateRegistry(device: device)
        let stableUUID = UUID(uuidString: "30000000-0000-0000-0000-000000000008")!
        let stable = display(id: 8, uuid: stableUUID, width: 1_000)

        let first = try registry.update(with: [stable])
        let stableMapping = try #require(first.displayMappings.first)
        #expect(stableMapping.surface.surfaceID.rawValue == stableUUID)

        registry.invalidateCurrentTopology()
        let reattached = try registry.update(with: [stable])
        let reattachedMapping = try #require(reattached.displayMappings.first)
        #expect(reattachedMapping.surface == stableMapping.surface)
        #expect(
            reattachedMapping.descriptor.coordinateSpace.revision ==
                stableMapping.descriptor.coordinateSpace.revision + 1
        )

        let fallback = display(id: 9, uuid: nil, width: 900)
        let fallbackFirst = try registry.update(with: [fallback])
        let fallbackFirstMapping = try #require(fallbackFirst.displayMappings.first)
        registry.invalidateCurrentTopology()
        let fallbackSecond = try registry.update(with: [fallback])
        let fallbackSecondMapping = try #require(fallbackSecond.displayMappings.first)
        #expect(fallbackSecondMapping.surface != fallbackFirstMapping.surface)
        #expect(
            fallbackSecondMapping.descriptor.coordinateSpace.coordinateSpaceID !=
                fallbackFirstMapping.descriptor.coordinateSpace.coordinateSpaceID
        )
    }

    private func display(
        id: UInt32,
        uuid: UUID?,
        width: Double
    ) -> MacDisplaySnapshot {
        MacDisplaySnapshot(
            displayID: id,
            displayUUID: uuid,
            globalBounds: MacGlobalRect(x: 0, y: 0, width: width, height: 600)!,
            pixelWidth: Int(width * 2),
            pixelHeight: 1_200,
            rotationQuarterTurns: 0,
            scaleFactor: 2,
            isMain: true
        )
    }
}

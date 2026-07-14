import Foundation
import PointerSceneContracts
import Testing

@Suite("Scene contract identity and geometry")
struct IdentityAndGeometryTests {
    @Test("Object identity is isolated by source epoch")
    func objectIdentityIsolatedByEpoch() throws {
        let device = DevicePrincipalID()
        let source = SceneSourceIdentity(device: device, source: SceneSourceID())
        let localID = SourceObjectID()
        let first = SourceObjectKey(
            sourceEpoch: SceneSourceEpoch(source: source),
            objectID: localID
        )
        let second = SourceObjectKey(
            sourceEpoch: SceneSourceEpoch(source: source),
            objectID: localID
        )

        #expect(first != second)
    }

    @Test("Equal compound keys deduplicate while different epochs do not")
    func compoundKeyEquality() {
        let device = DevicePrincipalID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )
        let source = SceneSourceIdentity(
            device: device,
            source: SceneSourceID(
                rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
            )
        )
        let epochID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let objectID = SourceObjectID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        )
        let first = SourceObjectKey(
            sourceEpoch: SceneSourceEpoch(source: source, epochID: epochID),
            objectID: objectID
        )
        let duplicate = SourceObjectKey(
            sourceEpoch: SceneSourceEpoch(source: source, epochID: epochID),
            objectID: objectID
        )

        #expect(first == duplicate)
        #expect(Set([first, duplicate]).count == 1)
    }

    @Test("A rectangle is scoped to its surface and coordinate revision")
    func surfaceScopedGeometry() throws {
        let device = DevicePrincipalID()
        let coordinateID = CoordinateSpaceID()
        let firstSpace = try SurfaceCoordinateSpace(
            surface: SceneSurfaceIdentity(device: device, surfaceID: SceneSurfaceID()),
            coordinateSpaceID: coordinateID,
            revision: 1
        )
        let secondSpace = try SurfaceCoordinateSpace(
            surface: SceneSurfaceIdentity(device: device, surfaceID: SceneSurfaceID()),
            coordinateSpaceID: coordinateID,
            revision: 1
        )
        let rect = try SceneRect(x: 0, y: 0, width: 100, height: 100)

        #expect(SurfaceRegion(coordinateSpace: firstSpace, rect: rect) !=
            SurfaceRegion(coordinateSpace: secondSpace, rect: rect))

        let nextRevision = try SurfaceCoordinateSpace(
            surface: firstSpace.surface,
            coordinateSpaceID: firstSpace.coordinateSpaceID,
            revision: 2
        )
        #expect(SurfaceRegion(coordinateSpace: firstSpace, rect: rect) !=
            SurfaceRegion(coordinateSpace: nextRevision, rect: rect))
    }

    @Test("Invalid coordinate values fail deterministically")
    func invalidCoordinates() {
        #expect(throws: SceneContractValidationError.nonFinite(field: "point")) {
            _ = try ScenePoint(x: .infinity, y: 0)
        }
        #expect(throws: SceneContractValidationError.invalidRange(field: "size")) {
            _ = try SceneSize(width: 0, height: 1)
        }
    }
}


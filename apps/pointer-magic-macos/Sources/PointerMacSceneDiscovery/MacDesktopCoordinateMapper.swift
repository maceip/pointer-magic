import Foundation
import PointerSceneContracts

public struct MacMappedSurfaceRegion: Hashable, Sendable {
    public let displayID: UInt32
    public let globalIntersection: MacGlobalRect
    public let region: SurfaceRegion

    public init(
        displayID: UInt32,
        globalIntersection: MacGlobalRect,
        region: SurfaceRegion
    ) {
        self.displayID = displayID
        self.globalIntersection = globalIntersection
        self.region = region
    }
}

public struct MacMappedSurfacePoint: Hashable, Sendable {
    public let coordinateSpace: SurfaceCoordinateSpace
    public let point: ScenePoint

    public init(coordinateSpace: SurfaceCoordinateSpace, point: ScenePoint) {
        self.coordinateSpace = coordinateSpace
        self.point = point
    }
}

struct MacDesktopDisplayCoordinateRegistration: Sendable {
    let surfaceID: SceneSurfaceID
    let revision: UInt64
}

/// Converts global Quartz desktop rectangles into revisioned, surface-local contract
/// coordinates. A spanning window produces one fragment per intersected display.
public struct MacDesktopCoordinateMapper: Sendable {
    public struct VirtualDesktopMapping: Hashable, Sendable {
        public let globalBounds: MacGlobalRect
        public let surface: SceneSurfaceIdentity
        public let descriptor: CoordinateSpaceDescriptor

        public init(
            globalBounds: MacGlobalRect,
            surface: SceneSurfaceIdentity,
            descriptor: CoordinateSpaceDescriptor
        ) {
            self.globalBounds = globalBounds
            self.surface = surface
            self.descriptor = descriptor
        }
    }

    public struct DisplayMapping: Hashable, Sendable {
        public let display: MacDisplaySnapshot
        public let surface: SceneSurfaceIdentity
        public let descriptor: CoordinateSpaceDescriptor

        public init(
            display: MacDisplaySnapshot,
            surface: SceneSurfaceIdentity,
            descriptor: CoordinateSpaceDescriptor
        ) {
            self.display = display
            self.surface = surface
            self.descriptor = descriptor
        }
    }

    public let mappings: [DisplayMapping]
    /// The canonical logical space for window geometry. A spanning window remains one
    /// complete rectangle instead of becoming undiscoverable on a secondary display.
    public let virtualDesktop: VirtualDesktopMapping

    init(
        displays: [MacDisplaySnapshot],
        device: DevicePrincipalID,
        virtualDesktopRevision: UInt64,
        displayRegistrations: [UInt32: MacDesktopDisplayCoordinateRegistration]
    ) throws {
        guard let union = Self.unionBounds(displays.map(\.globalBounds)) else {
            throw MacDesktopCensusError.noUsableDisplays
        }
        let virtualSurface = SceneSurfaceIdentity(
            device: device,
            surfaceID: SceneStableIdentifiers.virtualDesktop(device: device)
        )
        let virtualCoordinateSpace = try SurfaceCoordinateSpace(
            surface: virtualSurface,
            coordinateSpaceID: SceneStableIdentifiers.coordinateSpace(
                surface: virtualSurface,
                device: device
            ),
            revision: virtualDesktopRevision
        )
        self.virtualDesktop = VirtualDesktopMapping(
            globalBounds: union,
            surface: virtualSurface,
            descriptor: try CoordinateSpaceDescriptor(
                coordinateSpace: virtualCoordinateSpace,
                unit: .logicalPoints,
                origin: .topLeft,
                extent: try SceneSize(width: union.width, height: union.height),
                rotationQuarterTurns: 0,
                // A logical desktop can contain displays with different backing scales.
                scaleFactor: 1
            )
        )

        self.mappings = try displays.sorted { $0.displayID < $1.displayID }.map { display in
            guard let registration = displayRegistrations[display.displayID] else {
                throw MacDesktopCoordinateRegistryError.missingDisplayRegistration(
                    displayID: display.displayID
                )
            }
            let surface = SceneSurfaceIdentity(
                device: device,
                surfaceID: registration.surfaceID
            )
            let coordinateSpace = try SurfaceCoordinateSpace(
                surface: surface,
                coordinateSpaceID: SceneStableIdentifiers.coordinateSpace(
                    surface: surface,
                    device: device
                ),
                revision: registration.revision
            )
            let extent = try SceneSize(
                width: display.globalBounds.width,
                height: display.globalBounds.height
            )
            let descriptor = try CoordinateSpaceDescriptor(
                coordinateSpace: coordinateSpace,
                unit: .logicalPoints,
                origin: .topLeft,
                extent: extent,
                rotationQuarterTurns: display.rotationQuarterTurns,
                scaleFactor: display.scaleFactor
            )
            return DisplayMapping(display: display, surface: surface, descriptor: descriptor)
        }
    }

    /// Maps a Quartz-global rectangle into the one logical virtual-desktop surface used
    /// by base window observations and spatial queries. The rectangle is not clipped:
    /// partially off-desktop windows retain their real bounds, while requiring at least
    /// one visible intersection with the current desktop.
    public func virtualDesktopRegion(for globalRect: MacGlobalRect) -> SurfaceRegion? {
        guard globalRect.intersection(virtualDesktop.globalBounds) != nil,
              let rect = try? SceneRect(
                  x: globalRect.x - virtualDesktop.globalBounds.x,
                  y: globalRect.y - virtualDesktop.globalBounds.y,
                  width: globalRect.width,
                  height: globalRect.height
              )
        else {
            return nil
        }
        return SurfaceRegion(
            coordinateSpace: virtualDesktop.descriptor.coordinateSpace,
            rect: rect
        )
    }

    public func virtualDesktopPoint(for globalPoint: MacGlobalPoint) -> MacMappedSurfacePoint? {
        guard globalPoint.x >= virtualDesktop.globalBounds.x,
              globalPoint.x < virtualDesktop.globalBounds.maxX,
              globalPoint.y >= virtualDesktop.globalBounds.y,
              globalPoint.y < virtualDesktop.globalBounds.maxY,
              let point = try? ScenePoint(
                  x: globalPoint.x - virtualDesktop.globalBounds.x,
                  y: globalPoint.y - virtualDesktop.globalBounds.y
              )
        else {
            return nil
        }
        return MacMappedSurfacePoint(
            coordinateSpace: virtualDesktop.descriptor.coordinateSpace,
            point: point
        )
    }

    public func fragments(for globalRect: MacGlobalRect) -> [MacMappedSurfaceRegion] {
        mappings.compactMap { mapping in
            guard let intersection = globalRect.intersection(mapping.display.globalBounds),
                  let rect = try? SceneRect(
                      x: intersection.x - mapping.display.globalBounds.x,
                      y: intersection.y - mapping.display.globalBounds.y,
                      width: intersection.width,
                      height: intersection.height
                  )
            else {
                return nil
            }
            return MacMappedSurfaceRegion(
                displayID: mapping.display.displayID,
                globalIntersection: intersection,
                region: SurfaceRegion(
                    coordinateSpace: mapping.descriptor.coordinateSpace,
                    rect: rect
                )
            )
        }
    }

    public func primaryRegion(for globalRect: MacGlobalRect) -> MacMappedSurfaceRegion? {
        fragments(for: globalRect).max { lhs, rhs in
            if lhs.globalIntersection.area == rhs.globalIntersection.area {
                // `max` should choose the lower display ID when areas tie.
                return lhs.displayID > rhs.displayID
            }
            return lhs.globalIntersection.area < rhs.globalIntersection.area
        }
    }

    private static func unionBounds(_ bounds: [MacGlobalRect]) -> MacGlobalRect? {
        guard let first = bounds.first else { return nil }
        let minX = bounds.dropFirst().reduce(first.x) { min($0, $1.x) }
        let minY = bounds.dropFirst().reduce(first.y) { min($0, $1.y) }
        let maxX = bounds.dropFirst().reduce(first.maxX) { max($0, $1.maxX) }
        let maxY = bounds.dropFirst().reduce(first.maxY) { max($0, $1.maxY) }
        return MacGlobalRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

enum SceneStableIdentifiers {
    static func object(kind: UInt32, value: UInt64) -> SourceObjectID {
        SourceObjectID(rawValue: deterministicUUID(namespace: kind, value: value))
    }

    static func coordinateSpace(
        surface: SceneSurfaceIdentity,
        device: DevicePrincipalID
    ) -> CoordinateSpaceID {
        let namespace = xorUUID(device.rawValue, surface.surfaceID.rawValue)
        return CoordinateSpaceID(
            rawValue: deterministicUUID(
                namespaceUUID: namespace,
                discriminator: 0x434F_4F52,
                value: 0
            )
        )
    }

    static func virtualDesktop(device: DevicePrincipalID) -> SceneSurfaceID {
        SceneSurfaceID(rawValue: deterministicUUID(
            namespaceUUID: device.rawValue,
            discriminator: 0x5644_4553,
            value: 0
        ))
    }

    static func fallbackDisplay(
        registryNamespace: UUID,
        displayID: UInt32,
        generation: UInt64
    ) -> SceneSurfaceID {
        let generationNamespace = deterministicUUID(
            namespaceUUID: registryNamespace,
            discriminator: 0x4642_4143,
            value: generation
        )
        return SceneSurfaceID(rawValue: deterministicUUID(
            namespaceUUID: generationNamespace,
            discriminator: 0x5355_5246,
            value: UInt64(displayID)
        ))
    }

    static func screenDirtySentinel(
        surface: SceneSurfaceIdentity,
        device: DevicePrincipalID
    ) -> SourceObjectID {
        SourceObjectID(rawValue: deterministicUUID(
            namespaceUUID: xorUUID(device.rawValue, surface.surfaceID.rawValue),
            discriminator: 0x4452_5459,
            value: 0
        ))
    }

    static func workspaceDisplay(
        surface: SceneSurfaceIdentity,
        device: DevicePrincipalID
    ) -> SourceObjectID {
        SourceObjectID(rawValue: deterministicUUID(
            namespaceUUID: xorUUID(device.rawValue, surface.surfaceID.rawValue),
            discriminator: 0x4453_504C,
            value: 0
        ))
    }

    private static func deterministicUUID(namespace: UInt32, value: UInt64) -> UUID {
        let n = namespace.bigEndian
        let v = value.bigEndian
        let bytes: [UInt8] = withUnsafeBytes(of: n, Array.init) +
            [0x4D, 0x50, 0x53, 0x43] + withUnsafeBytes(of: v, Array.init)
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func deterministicUUID(
        namespaceUUID: UUID,
        discriminator: UInt32,
        value: UInt64
    ) -> UUID {
        let namespaceBytes = withUnsafeBytes(of: namespaceUUID.uuid, Array.init)
        let d = withUnsafeBytes(of: discriminator.bigEndian, Array.init)
        let v = withUnsafeBytes(of: value.bigEndian, Array.init)
        var bytes = namespaceBytes
        for index in 0 ..< 4 { bytes[index] ^= d[index] }
        for index in 0 ..< 8 { bytes[index + 8] ^= v[index] }
        // Mark this as a locally namespaced deterministic identifier without claiming
        // a cryptographic UUID version.
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func xorUUID(_ lhs: UUID, _ rhs: UUID) -> UUID {
        let left = withUnsafeBytes(of: lhs.uuid, Array.init)
        let right = withUnsafeBytes(of: rhs.uuid, Array.init)
        let bytes = zip(left, right).map(^)
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

import Foundation

public struct DevicePrincipalID: Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString }
}

public struct SceneSessionID: Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString }
}

/// Stable identity assigned to one producer on one device.
public struct SceneSourceID: Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString }
}

public struct SceneSourceIdentity: Codable, Hashable, Sendable {
    public let device: DevicePrincipalID
    public let source: SceneSourceID

    public init(device: DevicePrincipalID, source: SceneSourceID) {
        self.device = device
        self.source = source
    }
}

/// Restart boundary for a source. Reusing a local object ID in another epoch never aliases it.
public struct SceneSourceEpoch: Codable, Hashable, Sendable {
    public let source: SceneSourceIdentity
    public let epochID: UUID

    public init(source: SceneSourceIdentity, epochID: UUID = UUID()) {
        self.source = source
        self.epochID = epochID
    }
}

/// Producer-created identity for one object incarnation within a source epoch.
/// The receiver maps accepted source-local identities to its own canonical IDs.
public struct SourceObjectID: Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString }
}

public struct SourceObjectKey: Codable, Hashable, Sendable {
    public let sourceEpoch: SceneSourceEpoch
    public let objectID: SourceObjectID

    public init(sourceEpoch: SceneSourceEpoch, objectID: SourceObjectID) {
        self.sourceEpoch = sourceEpoch
        self.objectID = objectID
    }
}

public struct SceneSurfaceID: Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString }
}

/// A surface belongs to a device, not to one discovery source on that device.
public struct SceneSurfaceIdentity: Codable, Hashable, Sendable {
    public let device: DevicePrincipalID
    public let surfaceID: SceneSurfaceID

    public init(device: DevicePrincipalID, surfaceID: SceneSurfaceID) {
        self.device = device
        self.surfaceID = surfaceID
    }
}

public struct CoordinateSpaceID: Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString }
}

/// Geometry is meaningful only with its surface, coordinate-space ID, and revision.
public struct SurfaceCoordinateSpace: Codable, Hashable, Sendable {
    public let surface: SceneSurfaceIdentity
    public let coordinateSpaceID: CoordinateSpaceID
    public let revision: UInt64

    public init(
        surface: SceneSurfaceIdentity,
        coordinateSpaceID: CoordinateSpaceID,
        revision: UInt64
    ) throws {
        guard revision > 0 else {
            throw SceneContractValidationError.invalidRange(field: "coordinateSpace.revision")
        }
        self.surface = surface
        self.coordinateSpaceID = coordinateSpaceID
        self.revision = revision
    }

    private enum CodingKeys: CodingKey { case surface, coordinateSpaceID, revision }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            surface: container.decode(SceneSurfaceIdentity.self, forKey: .surface),
            coordinateSpaceID: container.decode(
                CoordinateSpaceID.self,
                forKey: .coordinateSpaceID
            ),
            revision: container.decode(UInt64.self, forKey: .revision)
        )
    }
}

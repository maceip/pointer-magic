import Foundation

public enum SceneSourceKind: String, Codable, Hashable, Sendable {
    case accessibility
    case windowMetadata
    case screenPixels
    case applicationAdapter
    case remoteDevice
    case syntheticTest
}

public enum SceneSourceCapability: String, Codable, Hashable, CaseIterable, Sendable {
    case applicationLifecycle
    case windowTopology
    case structuredHierarchy
    case geometry
    case text
    case imageUnderstanding
    case dirtyRegions
    case sensitivityClassification
    case coverageReporting
    case completeEventCoverage
    case crossSourceDependencies
    case onDemandRefresh
    case checkpoints
}

public struct SceneSourceManifest: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1

    public let schemaVersion: UInt16
    public let sourceEpoch: SceneSourceEpoch
    public let sessionID: SceneSessionID
    public let displayName: String
    public let kind: SceneSourceKind
    public let capabilities: [SceneSourceCapability]
    public let minimumEventSchemaVersion: UInt16
    public let maximumEventSchemaVersion: UInt16

    public init(
        schemaVersion: UInt16 = currentSchemaVersion,
        sourceEpoch: SceneSourceEpoch,
        sessionID: SceneSessionID,
        displayName: String,
        kind: SceneSourceKind,
        capabilities: [SceneSourceCapability],
        minimumEventSchemaVersion: UInt16 = SceneEventEnvelope.currentSchemaVersion,
        maximumEventSchemaVersion: UInt16 = SceneEventEnvelope.currentSchemaVersion
    ) throws {
        self.schemaVersion = schemaVersion
        self.sourceEpoch = sourceEpoch
        self.sessionID = sessionID
        self.displayName = displayName
        self.kind = kind
        self.capabilities = capabilities.sorted { $0.rawValue < $1.rawValue }
        self.minimumEventSchemaVersion = minimumEventSchemaVersion
        self.maximumEventSchemaVersion = maximumEventSchemaVersion
        try validate()
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw SceneContractValidationError.unsupportedSchema(
                found: schemaVersion,
                supported: Self.currentSchemaVersion
            )
        }
        try validateText(
            displayName,
            maximum: SceneContractLimits.shortTextCharacters,
            field: "manifest.displayName"
        )
        try validateCount(
            capabilities.count,
            maximum: SceneContractLimits.capabilitiesPerManifest,
            field: "manifest.capabilities"
        )
        try validateUnique(capabilities, field: "manifest.capabilities")
        guard minimumEventSchemaVersion > 0,
              maximumEventSchemaVersion >= minimumEventSchemaVersion
        else {
            throw SceneContractValidationError.invalidRange(
                field: "manifest.eventSchemaVersions"
            )
        }
    }

    private enum CodingKeys: CodingKey {
        case schemaVersion
        case sourceEpoch
        case sessionID
        case displayName
        case kind
        case capabilities
        case minimumEventSchemaVersion
        case maximumEventSchemaVersion
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(UInt16.self, forKey: .schemaVersion),
            sourceEpoch: container.decode(SceneSourceEpoch.self, forKey: .sourceEpoch),
            sessionID: container.decode(SceneSessionID.self, forKey: .sessionID),
            displayName: container.decode(String.self, forKey: .displayName),
            kind: container.decode(SceneSourceKind.self, forKey: .kind),
            capabilities: container.decode(
                [SceneSourceCapability].self,
                forKey: .capabilities
            ),
            minimumEventSchemaVersion: container.decode(
                UInt16.self,
                forKey: .minimumEventSchemaVersion
            ),
            maximumEventSchemaVersion: container.decode(
                UInt16.self,
                forKey: .maximumEventSchemaVersion
            )
        )
    }
}

public struct SceneSourceGrantID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    package init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString }
}

public enum SceneSurfaceGrant: Hashable, Sendable {
    case ownDevice
    case listed(Set<SceneSurfaceIdentity>)
}

public enum SceneFieldGrant: Hashable, Sendable {
    case all
    case listed(Set<SceneFieldKey>)
}

/// Receiver-issued authority. Deliberately not Codable: it is established by the
/// ingress boundary and cannot arrive inside a producer payload.
public struct SceneSourceGrant: Hashable, Sendable {
    public let id: SceneSourceGrantID
    public let sourceEpoch: SceneSourceEpoch
    public let capabilities: Set<SceneSourceCapability>
    public let eventKinds: Set<SceneEventKind>
    public let evidenceKinds: Set<SceneEvidenceKind>
    public let fields: SceneFieldGrant
    public let surfaces: SceneSurfaceGrant
    /// Stable source identities whose epochs this source may cite as dependencies.
    /// The enclosing source epoch is always permitted and need not be listed.
    public let permittedDependencySources: Set<SceneSourceIdentity>
    public let expiresAtReceiverMonotonicNs: UInt64?

    package init(
        receiverIssuedID: SceneSourceGrantID = SceneSourceGrantID(),
        sourceEpoch: SceneSourceEpoch,
        capabilities: Set<SceneSourceCapability>,
        eventKinds: Set<SceneEventKind>,
        evidenceKinds: Set<SceneEvidenceKind>,
        fields: SceneFieldGrant,
        surfaces: SceneSurfaceGrant,
        permittedDependencySources: Set<SceneSourceIdentity> = [],
        expiresAtReceiverMonotonicNs: UInt64? = nil
    ) {
        self.id = receiverIssuedID
        self.sourceEpoch = sourceEpoch
        self.capabilities = capabilities
        self.eventKinds = eventKinds
        self.evidenceKinds = evidenceKinds
        self.fields = fields
        self.surfaces = surfaces
        self.permittedDependencySources = permittedDependencySources
        self.expiresAtReceiverMonotonicNs = expiresAtReceiverMonotonicNs
    }
}

public struct SceneSourceHandleID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    package init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString }
}

/// Opaque receiver-issued registration handle. It is passed out-of-band to the sink
/// and is deliberately not Codable.
public struct SceneSourceHandle: Hashable, Sendable {
    public let id: SceneSourceHandleID
    public let sourceEpoch: SceneSourceEpoch
    public let sessionID: SceneSessionID
    public let grantID: SceneSourceGrantID

    package init(
        receiverIssuedID: SceneSourceHandleID = SceneSourceHandleID(),
        sourceEpoch: SceneSourceEpoch,
        sessionID: SceneSessionID,
        grantID: SceneSourceGrantID
    ) {
        self.id = receiverIssuedID
        self.sourceEpoch = sourceEpoch
        self.sessionID = sessionID
        self.grantID = grantID
    }
}

/// Validated registration tuple held by the receiver. It is not transport data.
public struct SceneSourceAuthorization: Hashable, Sendable {
    public let manifest: SceneSourceManifest
    public let grant: SceneSourceGrant
    public let handle: SceneSourceHandle

    package init(
        manifest: SceneSourceManifest,
        grant: SceneSourceGrant,
        handle: SceneSourceHandle,
        receiverNowNs: UInt64
    ) throws {
        try manifest.validate()
        guard manifest.sourceEpoch == grant.sourceEpoch,
              manifest.sourceEpoch == handle.sourceEpoch,
              manifest.sessionID == handle.sessionID,
              grant.id == handle.grantID
        else {
            throw SceneContractValidationError.sourceMismatch(field: "sourceAuthorization")
        }
        guard Set(manifest.capabilities).isSuperset(of: grant.capabilities) else {
            throw SceneContractValidationError.unauthorized(
                field: "sourceAuthorization.capabilities"
            )
        }
        try validateCount(
            grant.permittedDependencySources.count,
            maximum: SceneContractLimits.dependencySourcesPerGrant,
            field: "sourceAuthorization.permittedDependencySources"
        )
        if !grant.permittedDependencySources.isEmpty,
           !grant.capabilities.contains(.crossSourceDependencies)
        {
            throw SceneContractValidationError.unauthorized(
                field: "sourceAuthorization.permittedDependencySources"
            )
        }
        if let expiry = grant.expiresAtReceiverMonotonicNs, expiry <= receiverNowNs {
            throw SceneContractValidationError.expired(field: "sourceAuthorization.grant")
        }
        self.manifest = manifest
        self.grant = grant
        self.handle = handle
    }

    package func validate(_ batch: SceneEventBatch, receiverNowNs: UInt64) throws {
        guard batch.sourceEpoch == handle.sourceEpoch else {
            throw SceneContractValidationError.sourceMismatch(field: "batch.sourceEpoch")
        }
        if let expiry = grant.expiresAtReceiverMonotonicNs, expiry <= receiverNowNs {
            throw SceneContractValidationError.expired(field: "sourceAuthorization.grant")
        }

        for event in batch.events {
            guard grant.eventKinds.contains(event.payload.kind) else {
                throw SceneContractValidationError.unauthorized(field: "event.kind")
            }
            guard grant.evidenceKinds.isSuperset(of: event.payload.evidenceKinds) else {
                throw SceneContractValidationError.unauthorized(field: "event.evidence")
            }
            for dependency in event.payload.claimDependencies
                where dependency.revision.sourceEpoch != handle.sourceEpoch
            {
                guard grant.capabilities.contains(.crossSourceDependencies),
                      grant.permittedDependencySources.contains(
                          dependency.revision.sourceEpoch.source
                      )
                else {
                    throw SceneContractValidationError.unauthorized(
                        field: "claim.dependencies.source"
                    )
                }
            }
            if case let .coverage(report) = event.payload,
               report.guarantee == .completeEvents,
               !grant.capabilities.contains(.completeEventCoverage)
            {
                throw SceneContractValidationError.unauthorized(
                    field: "coverage.completeEvents"
                )
            }
            switch (grant.fields, event.payload.claimedFields) {
            case (.all, _):
                break
            case let (.listed(allowed), .some(claimed)) where allowed.isSuperset(of: claimed):
                break
            default:
                throw SceneContractValidationError.unauthorized(field: "event.fields")
            }
            switch grant.surfaces {
            case .ownDevice:
                guard event.payload.referencedSurfaces.allSatisfy({
                    $0.device == handle.sourceEpoch.source.device
                }) else {
                    throw SceneContractValidationError.unauthorized(field: "event.surfaces")
                }
            case let .listed(allowed):
                guard allowed.isSuperset(of: event.payload.referencedSurfaces) else {
                    throw SceneContractValidationError.unauthorized(field: "event.surfaces")
                }
            }
        }
    }
}

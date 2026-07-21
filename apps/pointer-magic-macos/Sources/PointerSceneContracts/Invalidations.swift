import Foundation

public enum SceneInvalidationScope: Codable, Hashable, Sendable {
    case object(SourceObjectKey)
    case region(SurfaceRegion)
    case surface(SceneSurfaceIdentity)
    case sourceProjection(SceneSourceEpoch)

    func validate(for sourceEpoch: SceneSourceEpoch, field: String) throws {
        switch self {
        case let .object(object):
            guard object.sourceEpoch == sourceEpoch else {
                throw SceneContractValidationError.sourceMismatch(field: field)
            }
        case let .region(region):
            guard region.coordinateSpace.surface.device == sourceEpoch.source.device else {
                throw SceneContractValidationError.sourceMismatch(field: field)
            }
            try region.validate(field: field)
        case let .surface(surface):
            guard surface.device == sourceEpoch.source.device else {
                throw SceneContractValidationError.sourceMismatch(field: field)
            }
        case let .sourceProjection(source):
            guard source == sourceEpoch else {
                throw SceneContractValidationError.sourceMismatch(field: field)
            }
        }
    }
}

public enum SceneInvalidationReason: String, Codable, Hashable, Sendable {
    case valueChanged
    case geometryChanged
    case moved
    case resized
    case destroyed
    case created
    case occlusionChanged
    case sceneTransition
    case permissionChanged
    case privacyBoundary
    case contentDirty
    case coverageGap
    case sourceRestarted
    case modelChanged
    case explicitRetraction
    case unknown
}

public struct SceneInvalidation: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1

    public let schemaVersion: UInt16
    public let scope: SceneInvalidationScope
    /// Empty means every field in scope.
    public let fields: [SceneFieldKey]
    public let reason: SceneInvalidationReason
    public let observedAtSourceMonotonicNs: UInt64

    public init(
        schemaVersion: UInt16 = currentSchemaVersion,
        scope: SceneInvalidationScope,
        fields: [SceneFieldKey] = [],
        reason: SceneInvalidationReason,
        observedAtSourceMonotonicNs: UInt64
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw SceneContractValidationError.unsupportedSchema(
                found: schemaVersion,
                supported: Self.currentSchemaVersion
            )
        }
        try validateCount(
            fields.count,
            maximum: SceneContractLimits.fieldsPerInvalidation,
            field: "invalidation.fields"
        )
        try validateUnique(fields, field: "invalidation.fields")
        self.schemaVersion = schemaVersion
        self.scope = scope
        self.fields = fields.sorted()
        self.reason = reason
        self.observedAtSourceMonotonicNs = observedAtSourceMonotonicNs
    }

    func validate(for sourceEpoch: SceneSourceEpoch) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw SceneContractValidationError.unsupportedSchema(
                found: schemaVersion,
                supported: Self.currentSchemaVersion
            )
        }
        try validateCount(
            fields.count,
            maximum: SceneContractLimits.fieldsPerInvalidation,
            field: "invalidation.fields"
        )
        try validateUnique(fields, field: "invalidation.fields")
        try scope.validate(for: sourceEpoch, field: "invalidation.scope")
    }

    private enum CodingKeys: CodingKey {
        case schemaVersion, scope, fields, reason, observedAtSourceMonotonicNs
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(UInt16.self, forKey: .schemaVersion),
            scope: container.decode(SceneInvalidationScope.self, forKey: .scope),
            fields: container.decode([SceneFieldKey].self, forKey: .fields),
            reason: container.decode(SceneInvalidationReason.self, forKey: .reason),
            observedAtSourceMonotonicNs: container.decode(
                UInt64.self,
                forKey: .observedAtSourceMonotonicNs
            )
        )
    }
}

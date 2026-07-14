import Foundation

public struct RefreshRequestID: Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString }
}

public enum SceneRefreshScope: Codable, Hashable, Sendable {
    case object(SourceObjectKey)
    case region(SurfaceRegion)
    case surface(SceneSurfaceIdentity)
    case sourceProjection(SceneSourceEpoch)
}

public enum SceneRefreshPriority: UInt8, Codable, Hashable, Comparable, Sendable {
    case background = 0
    case utility = 1
    case interactive = 2
    case safetyCritical = 3

    public static func < (lhs: SceneRefreshPriority, rhs: SceneRefreshPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum SceneRefreshReason: String, Codable, Hashable, Sendable {
    case proactiveDiscovery
    case audit
    case invalidated
    case coverageLost
    case pointerProximity
    case pointerVerification
    case explicitUserRequest
}

public struct RefreshRequest: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1

    public let schemaVersion: UInt16
    public let requestID: RefreshRequestID
    public let sessionID: SceneSessionID
    public let scope: SceneRefreshScope
    /// Empty asks the source for every field it can safely provide.
    public let fields: [SceneFieldKey]
    public let requiredEvidence: [SceneEvidenceKind]
    public let priority: SceneRefreshPriority
    /// Relative duration so different device monotonic clocks are never compared.
    public let deadlineAfterNs: UInt64
    public let reason: SceneRefreshReason

    public init(
        schemaVersion: UInt16 = currentSchemaVersion,
        requestID: RefreshRequestID = RefreshRequestID(),
        sessionID: SceneSessionID,
        scope: SceneRefreshScope,
        fields: [SceneFieldKey] = [],
        requiredEvidence: [SceneEvidenceKind] = [],
        priority: SceneRefreshPriority,
        deadlineAfterNs: UInt64,
        reason: SceneRefreshReason
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw SceneContractValidationError.unsupportedSchema(
                found: schemaVersion,
                supported: Self.currentSchemaVersion
            )
        }
        guard deadlineAfterNs > 0, deadlineAfterNs <= 300_000_000_000 else {
            throw SceneContractValidationError.invalidRange(field: "refresh.deadlineAfterNs")
        }
        try validateCount(
            fields.count,
            maximum: SceneContractLimits.fieldsPerRefresh,
            field: "refresh.fields"
        )
        try validateCount(
            requiredEvidence.count,
            maximum: SceneContractLimits.evidenceKindsPerRefresh,
            field: "refresh.requiredEvidence"
        )
        try validateUnique(fields, field: "refresh.fields")
        try validateUnique(requiredEvidence, field: "refresh.requiredEvidence")
        if case let .region(region) = scope {
            try region.validate(field: "refresh.scope")
        }
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.sessionID = sessionID
        self.scope = scope
        self.fields = fields.sorted()
        self.requiredEvidence = requiredEvidence.sorted { $0.rawValue < $1.rawValue }
        self.priority = priority
        self.deadlineAfterNs = deadlineAfterNs
        self.reason = reason
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw SceneContractValidationError.unsupportedSchema(
                found: schemaVersion,
                supported: Self.currentSchemaVersion
            )
        }
        guard deadlineAfterNs > 0, deadlineAfterNs <= 300_000_000_000 else {
            throw SceneContractValidationError.invalidRange(field: "refresh.deadlineAfterNs")
        }
        try validateCount(
            fields.count,
            maximum: SceneContractLimits.fieldsPerRefresh,
            field: "refresh.fields"
        )
        try validateCount(
            requiredEvidence.count,
            maximum: SceneContractLimits.evidenceKindsPerRefresh,
            field: "refresh.requiredEvidence"
        )
        try validateUnique(fields, field: "refresh.fields")
        try validateUnique(requiredEvidence, field: "refresh.requiredEvidence")
        if case let .region(region) = scope {
            try region.validate(field: "refresh.scope")
        }
    }

    private enum CodingKeys: CodingKey {
        case schemaVersion
        case requestID
        case sessionID
        case scope
        case fields
        case requiredEvidence
        case priority
        case deadlineAfterNs
        case reason
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(UInt16.self, forKey: .schemaVersion),
            requestID: container.decode(RefreshRequestID.self, forKey: .requestID),
            sessionID: container.decode(SceneSessionID.self, forKey: .sessionID),
            scope: container.decode(SceneRefreshScope.self, forKey: .scope),
            fields: container.decode([SceneFieldKey].self, forKey: .fields),
            requiredEvidence: container.decode(
                [SceneEvidenceKind].self,
                forKey: .requiredEvidence
            ),
            priority: container.decode(SceneRefreshPriority.self, forKey: .priority),
            deadlineAfterNs: container.decode(UInt64.self, forKey: .deadlineAfterNs),
            reason: container.decode(SceneRefreshReason.self, forKey: .reason)
        )
    }
}

public enum RefreshDisposition: Codable, Hashable, Sendable {
    case accepted
    case coalesced(into: RefreshRequestID)
    case superseded
    case unsupported
    case rejected
}

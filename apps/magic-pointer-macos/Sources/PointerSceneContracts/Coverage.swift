import Foundation

public struct CoverageStreamID: Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString }
}

public enum SceneCoverageScope: Codable, Hashable, Sendable {
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

public enum CoverageGapReason: String, Codable, Hashable, Sendable {
    case sourceBackpressure
    case sequenceGap
    case producerPaused
    case permissionLost
    case screenLocked
    case deviceSleeping
    case disconnected
    case sourceRestarted
    case unknown
}

/// `bestEffort` only proves the source is alive. `completeEvents` permits no-change
/// inference, and only for the explicitly listed fields and evidence kinds.
public enum CoverageGuarantee: String, Codable, Hashable, Sendable {
    case bestEffort
    case completeEvents
}

public enum CoverageReportState: Codable, Hashable, Sendable {
    case started(maximumSilenceNs: UInt64)
    case heartbeat
    case gap(CoverageGapReason)
    case ended(CoverageGapReason)
}

/// Producer report. Lease expiry is determined only from receiver arrival time.
/// A heartbeat extends only uninterrupted continuity; after a gap or lease expiry,
/// the receiver requires a new checkpoint rather than trusting a heartbeat alone.
public struct CoverageReport: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1

    public let schemaVersion: UInt16
    public let streamID: CoverageStreamID
    public let scope: SceneCoverageScope
    public let continuitySequence: UInt64
    public let state: CoverageReportState
    public let guarantee: CoverageGuarantee
    /// Empty never means "all"; it conveys no field-level no-change guarantee.
    public let coveredFields: [SceneFieldKey]
    public let coveredEvidenceKinds: [SceneEvidenceKind]
    public let observedAtSourceMonotonicNs: UInt64

    public init(
        schemaVersion: UInt16 = currentSchemaVersion,
        streamID: CoverageStreamID,
        scope: SceneCoverageScope,
        continuitySequence: UInt64,
        state: CoverageReportState,
        guarantee: CoverageGuarantee,
        coveredFields: [SceneFieldKey] = [],
        coveredEvidenceKinds: [SceneEvidenceKind] = [],
        observedAtSourceMonotonicNs: UInt64
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw SceneContractValidationError.unsupportedSchema(
                found: schemaVersion,
                supported: Self.currentSchemaVersion
            )
        }
        guard continuitySequence > 0 else {
            throw SceneContractValidationError.invalidRange(
                field: "coverage.continuitySequence"
            )
        }
        try Self.validate(state: state)
        try Self.validateCoverageSets(
            fields: coveredFields,
            evidenceKinds: coveredEvidenceKinds
        )
        self.schemaVersion = schemaVersion
        self.streamID = streamID
        self.scope = scope
        self.continuitySequence = continuitySequence
        self.state = state
        self.guarantee = guarantee
        self.coveredFields = coveredFields.sorted()
        self.coveredEvidenceKinds = coveredEvidenceKinds.sorted { $0.rawValue < $1.rawValue }
        self.observedAtSourceMonotonicNs = observedAtSourceMonotonicNs
    }

    func validate(for sourceEpoch: SceneSourceEpoch) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw SceneContractValidationError.unsupportedSchema(
                found: schemaVersion,
                supported: Self.currentSchemaVersion
            )
        }
        guard continuitySequence > 0 else {
            throw SceneContractValidationError.invalidRange(
                field: "coverage.continuitySequence"
            )
        }
        try Self.validate(state: state)
        try Self.validateCoverageSets(
            fields: coveredFields,
            evidenceKinds: coveredEvidenceKinds
        )
        try scope.validate(for: sourceEpoch, field: "coverage.scope")
    }

    private static func validate(state: CoverageReportState) throws {
        if case let .started(maximumSilenceNs) = state {
            guard maximumSilenceNs > 0, maximumSilenceNs <= 86_400_000_000_000 else {
                throw SceneContractValidationError.invalidRange(
                    field: "coverage.maximumSilenceNs"
                )
            }
        }
    }

    private static func validateCoverageSets(
        fields: [SceneFieldKey],
        evidenceKinds: [SceneEvidenceKind]
    ) throws {
        try validateCount(
            fields.count,
            maximum: SceneContractLimits.fieldsPerInvalidation,
            field: "coverage.coveredFields"
        )
        try validateCount(
            evidenceKinds.count,
            maximum: SceneContractLimits.evidenceKindsPerRefresh,
            field: "coverage.coveredEvidenceKinds"
        )
        try validateUnique(fields, field: "coverage.coveredFields")
        try validateUnique(evidenceKinds, field: "coverage.coveredEvidenceKinds")
    }

    private enum CodingKeys: CodingKey {
        case schemaVersion
        case streamID
        case scope
        case continuitySequence
        case state
        case guarantee
        case coveredFields
        case coveredEvidenceKinds
        case observedAtSourceMonotonicNs
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(UInt16.self, forKey: .schemaVersion),
            streamID: container.decode(CoverageStreamID.self, forKey: .streamID),
            scope: container.decode(SceneCoverageScope.self, forKey: .scope),
            continuitySequence: container.decode(UInt64.self, forKey: .continuitySequence),
            state: container.decode(CoverageReportState.self, forKey: .state),
            guarantee: container.decode(CoverageGuarantee.self, forKey: .guarantee),
            coveredFields: container.decode([SceneFieldKey].self, forKey: .coveredFields),
            coveredEvidenceKinds: container.decode(
                [SceneEvidenceKind].self,
                forKey: .coveredEvidenceKinds
            ),
            observedAtSourceMonotonicNs: container.decode(
                UInt64.self,
                forKey: .observedAtSourceMonotonicNs
            )
        )
    }
}

public enum CoverageLeaseState: Hashable, Sendable {
    case current
    case broken(CoverageGapReason)
    case ended(CoverageGapReason)
}

/// Receiver-derived state. It is deliberately not Codable and is not accepted from a source.
public struct CoverageLease: Hashable, Sendable {
    public let sourceEpoch: SceneSourceEpoch
    public let streamID: CoverageStreamID
    public let scope: SceneCoverageScope
    public let lastContinuitySequence: UInt64
    public let receivedAtReceiverMonotonicNs: UInt64
    public let expiresAtReceiverMonotonicNs: UInt64
    public let state: CoverageLeaseState
    public let guarantee: CoverageGuarantee
    public let coveredFields: Set<SceneFieldKey>
    public let coveredEvidenceKinds: Set<SceneEvidenceKind>

    public init(
        sourceEpoch: SceneSourceEpoch,
        streamID: CoverageStreamID,
        scope: SceneCoverageScope,
        lastContinuitySequence: UInt64,
        receivedAtReceiverMonotonicNs: UInt64,
        expiresAtReceiverMonotonicNs: UInt64,
        state: CoverageLeaseState,
        guarantee: CoverageGuarantee,
        coveredFields: Set<SceneFieldKey> = [],
        coveredEvidenceKinds: Set<SceneEvidenceKind> = []
    ) throws {
        guard lastContinuitySequence > 0,
              expiresAtReceiverMonotonicNs >= receivedAtReceiverMonotonicNs
        else {
            throw SceneContractValidationError.invalidRange(field: "coverageLease")
        }
        self.sourceEpoch = sourceEpoch
        self.streamID = streamID
        self.scope = scope
        self.lastContinuitySequence = lastContinuitySequence
        self.receivedAtReceiverMonotonicNs = receivedAtReceiverMonotonicNs
        self.expiresAtReceiverMonotonicNs = expiresAtReceiverMonotonicNs
        self.state = state
        self.guarantee = guarantee
        self.coveredFields = coveredFields
        self.coveredEvidenceKinds = coveredEvidenceKinds
    }
}

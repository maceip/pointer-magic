import Foundation

/// `Codable` supports local fixtures and explicit transport adapters. Its synthesized
/// representation is not a promised wire protocol; adapters must own framing, version
/// negotiation, authentication, and canonical encoding.
public enum SceneEventKind: String, Codable, Hashable, CaseIterable, Sendable {
    case observation
    case invalidation
    case coverage
    case checkpoint
}

public enum SceneEventPayload: Codable, Hashable, Sendable {
    case observation(SceneObservation)
    case invalidation(SceneInvalidation)
    case coverage(CoverageReport)
    case checkpoint(SceneCheckpoint)

    public var kind: SceneEventKind {
        switch self {
        case .observation: .observation
        case .invalidation: .invalidation
        case .coverage: .coverage
        case .checkpoint: .checkpoint
        }
    }

    func validate(for sourceEpoch: SceneSourceEpoch) throws {
        switch self {
        case let .observation(value):
            try value.validate(for: sourceEpoch)
        case let .invalidation(value):
            try value.validate(for: sourceEpoch)
        case let .coverage(value):
            try value.validate(for: sourceEpoch)
        case let .checkpoint(value):
            try value.validate(for: sourceEpoch)
        }
    }

    var claimedFields: Set<SceneFieldKey>? {
        switch self {
        case let .observation(value):
            Set(value.claims.map(\.field))
        case let .invalidation(value):
            value.fields.isEmpty ? nil : Set(value.fields)
        case let .coverage(value):
            Set(value.coveredFields)
        case let .checkpoint(value):
            Set(value.observations.flatMap { $0.claims.map(\.field) })
        }
    }

    var evidenceKinds: Set<SceneEvidenceKind> {
        switch self {
        case let .observation(value):
            Set(value.claims.flatMap { $0.evidence.map(\.kind) })
        case .invalidation:
            []
        case let .coverage(value):
            Set(value.coveredEvidenceKinds)
        case let .checkpoint(value):
            Set(value.observations.flatMap { observation in
                observation.claims.flatMap { $0.evidence.map(\.kind) }
            })
        }
    }

    var claimDependencies: [SceneClaimDependency] {
        switch self {
        case let .observation(value):
            value.claims.flatMap(\.dependencies)
        case let .checkpoint(value):
            value.observations.flatMap { observation in
                observation.claims.flatMap(\.dependencies)
            }
        case .invalidation, .coverage:
            []
        }
    }

    var referencedSurfaces: Set<SceneSurfaceIdentity> {
        func surfaces(in claim: SceneFieldClaim) -> [SceneSurfaceIdentity] {
            guard case let .region(region)? = claim.value else { return [] }
            return [region.coordinateSpace.surface]
        }

        switch self {
        case let .observation(value):
            return Set(value.claims.flatMap(surfaces))
        case let .invalidation(value):
            switch value.scope {
            case let .region(region): return [region.coordinateSpace.surface]
            case let .surface(surface): return [surface]
            case .object, .sourceProjection: return []
            }
        case let .coverage(value):
            switch value.scope {
            case let .region(region): return [region.coordinateSpace.surface]
            case let .surface(surface): return [surface]
            case .object, .sourceProjection: return []
            }
        case let .checkpoint(value):
            return Set(value.observations.flatMap { observation in
                observation.claims.flatMap(surfaces)
            })
        }
    }
}

public enum SceneRevisionReplayComparison: Hashable, Sendable {
    case differentRevision
    case identicalReplay
    case equivocation
}

public struct SceneEventEnvelope: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1

    public let schemaVersion: UInt16
    public let revision: SourceRevision
    public let emittedAtSourceMonotonicNs: UInt64
    public let payload: SceneEventPayload

    public init(
        schemaVersion: UInt16 = currentSchemaVersion,
        revision: SourceRevision,
        emittedAtSourceMonotonicNs: UInt64,
        payload: SceneEventPayload
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw SceneContractValidationError.unsupportedSchema(
                found: schemaVersion,
                supported: Self.currentSchemaVersion
            )
        }
        try payload.validate(for: revision.sourceEpoch)
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.emittedAtSourceMonotonicNs = emittedAtSourceMonotonicNs
        self.payload = payload
    }

    public func compareReplay(to other: SceneEventEnvelope) -> SceneRevisionReplayComparison {
        guard revision == other.revision else { return .differentRevision }
        return self == other ? .identicalReplay : .equivocation
    }

    private enum CodingKeys: CodingKey {
        case schemaVersion
        case revision
        case emittedAtSourceMonotonicNs
        case payload
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(UInt16.self, forKey: .schemaVersion),
            revision: container.decode(SourceRevision.self, forKey: .revision),
            emittedAtSourceMonotonicNs: container.decode(
                UInt64.self,
                forKey: .emittedAtSourceMonotonicNs
            ),
            payload: container.decode(SceneEventPayload.self, forKey: .payload)
        )
    }
}

public struct SceneEventBatch: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1

    public let schemaVersion: UInt16
    public let batchID: UUID
    /// Strictly increasing and source-epoch homogeneous after identical replays are folded.
    public let events: [SceneEventEnvelope]

    public init(
        schemaVersion: UInt16 = currentSchemaVersion,
        batchID: UUID = UUID(),
        events inputEvents: [SceneEventEnvelope]
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw SceneContractValidationError.unsupportedSchema(
                found: schemaVersion,
                supported: Self.currentSchemaVersion
            )
        }
        guard !inputEvents.isEmpty else {
            throw SceneContractValidationError.empty(field: "batch.events")
        }
        try validateCount(
            inputEvents.count,
            maximum: SceneContractLimits.eventsPerBatch,
            field: "batch.events"
        )

        let sourceEpoch = inputEvents[0].revision.sourceEpoch
        var canonical: [SceneEventEnvelope] = []
        canonical.reserveCapacity(inputEvents.count)
        var budget = SceneBatchValidationBudget()

        for event in inputEvents {
            guard event.revision.sourceEpoch == sourceEpoch else {
                throw SceneContractValidationError.mixedSourceEpoch
            }
            guard event.schemaVersion == SceneEventEnvelope.currentSchemaVersion else {
                throw SceneContractValidationError.unsupportedSchema(
                    found: event.schemaVersion,
                    supported: SceneEventEnvelope.currentSchemaVersion
                )
            }
            try event.payload.validate(for: sourceEpoch)

            if let previous = canonical.last {
                if event.revision.sequence < previous.revision.sequence {
                    throw SceneContractValidationError.outOfOrder(
                        previous: previous.revision.sequence,
                        next: event.revision.sequence
                    )
                }
                if event.revision.sequence == previous.revision.sequence {
                    switch previous.compareReplay(to: event) {
                    case .identicalReplay:
                        continue
                    case .equivocation:
                        throw SceneContractValidationError.revisionEquivocation(
                            sequence: event.revision.sequence
                        )
                    case .differentRevision:
                        break
                    }
                }
            }
            try budget.consume(event.payload)
            canonical.append(event)
        }

        self.schemaVersion = schemaVersion
        self.batchID = batchID
        self.events = canonical
    }

    public var sourceEpoch: SceneSourceEpoch { events[0].revision.sourceEpoch }

    /// Gaps are accepted as evidence of loss, never as continuous coverage.
    public var sourceSequenceGaps: [SourceSequenceGap] {
        zip(events, events.dropFirst()).compactMap { previous, next in
            let sequence = previous.revision.sequence
            guard sequence < UInt64.max,
                  next.revision.sequence > sequence + 1
            else {
                return nil
            }
            return try? SourceSequenceGap(
                sourceEpoch: sourceEpoch,
                missingFrom: sequence + 1,
                missingThrough: next.revision.sequence - 1
            )
        }
    }

    public var requiresCoverageBreak: Bool { !sourceSequenceGaps.isEmpty }

    private enum CodingKeys: CodingKey {
        case schemaVersion
        case batchID
        case events
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(UInt16.self, forKey: .schemaVersion),
            batchID: container.decode(UUID.self, forKey: .batchID),
            events: container.decode([SceneEventEnvelope].self, forKey: .events)
        )
    }
}

public enum IngestReceiptStatus: String, Codable, Hashable, Sendable {
    case accepted
    case acceptedWithCoverageGap
    case rejected
}

public enum IngestRejectionCode: String, Codable, Hashable, Sendable {
    case invalidBatch
    case unauthorizedSource
    case expiredGrant
    case unauthorizedCapability
    case unauthorizedSurface
    case staleEpoch
    case sequenceEquivocation
    case reducerUnavailable
}

public struct IngestReceipt: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1

    public let schemaVersion: UInt16
    public let batchID: UUID
    public let status: IngestReceiptStatus
    public let acceptedThrough: SourceRevision?
    public let identicalReplays: [SourceRevision]
    public let sequenceGaps: [SourceSequenceGap]
    public let rejection: IngestRejectionCode?

    public init(
        schemaVersion: UInt16 = currentSchemaVersion,
        batchID: UUID,
        status: IngestReceiptStatus,
        acceptedThrough: SourceRevision? = nil,
        identicalReplays: [SourceRevision] = [],
        sequenceGaps: [SourceSequenceGap] = [],
        rejection: IngestRejectionCode? = nil
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw SceneContractValidationError.unsupportedSchema(
                found: schemaVersion,
                supported: Self.currentSchemaVersion
            )
        }
        try validateCount(identicalReplays.count, maximum: 256, field: "receipt.replays")
        try validateCount(sequenceGaps.count, maximum: 256, field: "receipt.gaps")
        if status == .rejected, rejection == nil {
            throw SceneContractValidationError.empty(field: "receipt.rejection")
        }
        if status != .rejected, rejection != nil {
            throw SceneContractValidationError.invalidRange(field: "receipt.rejection")
        }
        if status == .accepted, !sequenceGaps.isEmpty {
            throw SceneContractValidationError.invalidRange(field: "receipt.sequenceGaps")
        }
        if status == .acceptedWithCoverageGap, sequenceGaps.isEmpty {
            throw SceneContractValidationError.empty(field: "receipt.sequenceGaps")
        }
        self.schemaVersion = schemaVersion
        self.batchID = batchID
        self.status = status
        self.acceptedThrough = acceptedThrough
        self.identicalReplays = identicalReplays
        self.sequenceGaps = sequenceGaps
        self.rejection = rejection
    }

    private enum CodingKeys: CodingKey {
        case schemaVersion
        case batchID
        case status
        case acceptedThrough
        case identicalReplays
        case sequenceGaps
        case rejection
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(UInt16.self, forKey: .schemaVersion),
            batchID: container.decode(UUID.self, forKey: .batchID),
            status: container.decode(IngestReceiptStatus.self, forKey: .status),
            acceptedThrough: container.decodeIfPresent(
                SourceRevision.self,
                forKey: .acceptedThrough
            ),
            identicalReplays: container.decode(
                [SourceRevision].self,
                forKey: .identicalReplays
            ),
            sequenceGaps: container.decode(
                [SourceSequenceGap].self,
                forKey: .sequenceGaps
            ),
            rejection: container.decodeIfPresent(
                IngestRejectionCode.self,
                forKey: .rejection
            )
        )
    }
}

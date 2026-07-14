import Foundation

public struct SceneFieldKey: Codable, Hashable, Sendable, Comparable,
    CustomStringConvertible
{
    public let rawValue: String

    public init(_ rawValue: String) throws {
        try validateText(
            rawValue,
            maximum: SceneContractLimits.identifierCharacters,
            field: "fieldKey"
        )
        guard let first = rawValue.utf8.first,
              (first >= 65 && first <= 90) || (first >= 97 && first <= 122),
              rawValue.utf8.allSatisfy({ byte in
                  (byte >= 65 && byte <= 90) ||
                      (byte >= 97 && byte <= 122) ||
                      (byte >= 48 && byte <= 57) ||
                      byte == 45 || byte == 46 || byte == 95
              })
        else {
            throw SceneContractValidationError.invalidFormat(field: "fieldKey")
        }
        self.rawValue = rawValue
    }

    public static func < (lhs: SceneFieldKey, rhs: SceneFieldKey) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum SceneDataSensitivity: String, Codable, Hashable, Sendable {
    case ordinary
    case secure
    case unknown
}

public enum SceneClaimKnowledge: String, Codable, Hashable, Sendable {
    case observed
    case derived
    case inferred
    case unknown
}

public enum SceneEvidenceKind: String, Codable, Hashable, CaseIterable, Sendable {
    case applicationAdapter
    case accessibility
    case browserDocument
    case windowMetadata
    case screenPixels
    case opticalCharacterRecognition
    case vision
    case temporalTracking
    case userCorrection
    case derived
}

/// Closed set of field payloads understood by the base contracts. New payload shapes
/// require a schema revision; arbitrary encoded blobs are intentionally excluded.
public enum SceneFieldValue: Codable, Hashable, Sendable {
    case text(String)
    case boolean(Bool)
    case signedInteger(Int64)
    case unsignedInteger(UInt64)
    case number(Double)
    case textList([String])
    case region(SurfaceRegion)
    case digest(String)

    func validate(field: String) throws {
        switch self {
        case let .text(value):
            try validateText(
                value,
                maximum: SceneContractLimits.textCharacters,
                field: field,
                allowEmpty: true
            )
        case .boolean, .signedInteger, .unsignedInteger:
            break
        case let .number(value):
            guard value.isFinite else {
                throw SceneContractValidationError.nonFinite(field: field)
            }
        case let .textList(values):
            try validateCount(values.count, maximum: 256, field: field)
            for (index, value) in values.enumerated() {
                try validateText(
                    value,
                    maximum: SceneContractLimits.shortTextCharacters,
                    field: "\(field)[\(index)]",
                    allowEmpty: true
                )
            }
        case let .region(region):
            try region.validate(field: field)
        case let .digest(value):
            try validateText(value, maximum: 256, field: field)
        }
    }
}

public struct SceneEvidence: Codable, Hashable, Sendable {
    public let kind: SceneEvidenceKind
    public let sourceRevision: SourceRevision?
    /// Bounded diagnostic or algorithm code, not free-form model output.
    public let detailCode: String?

    public init(
        kind: SceneEvidenceKind,
        sourceRevision: SourceRevision? = nil,
        detailCode: String? = nil
    ) throws {
        if let detailCode {
            try validateDiagnosticCode(detailCode, field: "evidence.detailCode")
        }
        self.kind = kind
        self.sourceRevision = sourceRevision
        self.detailCode = detailCode
    }

    fileprivate var canonicalSortKey: String {
        let revision = sourceRevision.map {
            "\($0.sourceEpoch.source.device.rawValue.uuidString)|" +
                "\($0.sourceEpoch.source.source.rawValue.uuidString)|" +
                "\($0.sourceEpoch.epochID.uuidString)|\($0.sequence)"
        } ?? ""
        return "\(kind.rawValue)|\(revision)|\(detailCode ?? "")"
    }

    private enum CodingKeys: CodingKey { case kind, sourceRevision, detailCode }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            kind: container.decode(SceneEvidenceKind.self, forKey: .kind),
            sourceRevision: container.decodeIfPresent(
                SourceRevision.self,
                forKey: .sourceRevision
            ),
            detailCode: container.decodeIfPresent(String.self, forKey: .detailCode)
        )
    }
}

public struct SceneClaimDependency: Codable, Hashable, Sendable {
    public let revision: SourceRevision
    public let object: SourceObjectKey?
    public let field: SceneFieldKey?

    public init(
        revision: SourceRevision,
        object: SourceObjectKey? = nil,
        field: SceneFieldKey? = nil
    ) {
        self.revision = revision
        self.object = object
        self.field = field
    }

    fileprivate var canonicalSortKey: String {
        let objectID = object?.objectID.rawValue.uuidString ?? ""
        return "\(revision.sourceEpoch.source.device.rawValue.uuidString)|" +
            "\(revision.sourceEpoch.source.source.rawValue.uuidString)|" +
            "\(revision.sourceEpoch.epochID.uuidString)|\(revision.sequence)|" +
            "\(objectID)|\(field?.rawValue ?? "")"
    }

    func validate(for ownerSourceEpoch: SceneSourceEpoch) throws {
        if let object, object.sourceEpoch != revision.sourceEpoch {
            throw SceneContractValidationError.sourceMismatch(
                field: "claim.dependencies"
            )
        }
        if field != nil, object == nil, revision.sourceEpoch != ownerSourceEpoch {
            // A field in another source has no implicit owner object. Cross-source
            // field dependencies must name the referenced object explicitly.
            throw SceneContractValidationError.sourceMismatch(
                field: "claim.dependencies"
            )
        }
    }
}

/// A claim may carry a value only when its sensitivity is `ordinary`.
/// `secure` and sensitivity-`unknown` claims are necessarily value-less.
public struct SceneFieldClaim: Codable, Hashable, Sendable {
    public let field: SceneFieldKey
    public let value: SceneFieldValue?
    public let knowledge: SceneClaimKnowledge
    public let confidence: Double
    public let sensitivity: SceneDataSensitivity
    public let evidence: [SceneEvidence]
    public let dependencies: [SceneClaimDependency]

    var textByteCount: Int {
        let valueBytes: Int = switch value {
        case let .text(value): value.utf8.count
        case let .textList(values): values.reduce(0) { $0 + $1.utf8.count }
        case let .digest(value): value.utf8.count
        default: 0
        }
        return evidence.reduce(valueBytes) { partial, item in
            partial + (item.detailCode?.utf8.count ?? 0)
        }
    }

    public init(
        field: SceneFieldKey,
        value: SceneFieldValue?,
        knowledge: SceneClaimKnowledge,
        confidence: Double,
        sensitivity: SceneDataSensitivity,
        evidence: [SceneEvidence] = [],
        dependencies: [SceneClaimDependency] = []
    ) throws {
        guard confidence.isFinite, (0 ... 1).contains(confidence) else {
            throw SceneContractValidationError.invalidRange(field: "claim.confidence")
        }
        guard sensitivity == .ordinary || value == nil else {
            throw SceneContractValidationError.sensitiveValue(field: "claim.value")
        }
        try validateCount(
            evidence.count,
            maximum: SceneContractLimits.evidencePerClaim,
            field: "claim.evidence"
        )
        try validateCount(
            dependencies.count,
            maximum: SceneContractLimits.dependenciesPerClaim,
            field: "claim.dependencies"
        )
        try validateUnique(evidence, field: "claim.evidence")
        try validateUnique(dependencies, field: "claim.dependencies")
        try value?.validate(field: "claim.value")
        self.field = field
        self.value = value
        self.knowledge = knowledge
        self.confidence = confidence
        self.sensitivity = sensitivity
        self.evidence = evidence.sorted { $0.canonicalSortKey < $1.canonicalSortKey }
        self.dependencies = dependencies.sorted { $0.canonicalSortKey < $1.canonicalSortKey }
    }

    func validate(for sourceEpoch: SceneSourceEpoch) throws {
        guard confidence.isFinite, (0 ... 1).contains(confidence) else {
            throw SceneContractValidationError.invalidRange(field: "claim.confidence")
        }
        guard sensitivity == .ordinary || value == nil else {
            throw SceneContractValidationError.sensitiveValue(field: "claim.value")
        }
        try validateCount(
            evidence.count,
            maximum: SceneContractLimits.evidencePerClaim,
            field: "claim.evidence"
        )
        try validateUnique(evidence, field: "claim.evidence")
        try validateUnique(dependencies, field: "claim.dependencies")
        try validateCount(
            dependencies.count,
            maximum: SceneContractLimits.dependenciesPerClaim,
            field: "claim.dependencies"
        )
        try value?.validate(field: "claim.value")
        for item in evidence {
            if let revision = item.sourceRevision, revision.sourceEpoch != sourceEpoch {
                throw SceneContractValidationError.sourceMismatch(field: "claim.evidence")
            }
            if let detail = item.detailCode {
                try validateDiagnosticCode(detail, field: "evidence.detailCode")
            }
        }
        for item in dependencies {
            try item.validate(for: sourceEpoch)
        }
    }

    private enum CodingKeys: CodingKey {
        case field, value, knowledge, confidence, sensitivity, evidence, dependencies
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            field: container.decode(SceneFieldKey.self, forKey: .field),
            value: container.decodeIfPresent(SceneFieldValue.self, forKey: .value),
            knowledge: container.decode(SceneClaimKnowledge.self, forKey: .knowledge),
            confidence: container.decode(Double.self, forKey: .confidence),
            sensitivity: container.decode(SceneDataSensitivity.self, forKey: .sensitivity),
            evidence: container.decode([SceneEvidence].self, forKey: .evidence),
            dependencies: container.decode(
                [SceneClaimDependency].self,
                forKey: .dependencies
            )
        )
    }
}

public struct SceneObservation: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1

    public let schemaVersion: UInt16
    public let subject: SourceObjectKey
    public let parent: SourceObjectKey?
    public let observedAtSourceMonotonicNs: UInt64
    public let claims: [SceneFieldClaim]

    public init(
        schemaVersion: UInt16 = currentSchemaVersion,
        subject: SourceObjectKey,
        parent: SourceObjectKey? = nil,
        observedAtSourceMonotonicNs: UInt64,
        claims: [SceneFieldClaim]
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw SceneContractValidationError.unsupportedSchema(
                found: schemaVersion,
                supported: Self.currentSchemaVersion
            )
        }
        guard !claims.isEmpty else {
            throw SceneContractValidationError.empty(field: "observation.claims")
        }
        try validateCount(
            claims.count,
            maximum: SceneContractLimits.claimsPerObservation,
            field: "observation.claims"
        )
        try validateUnique(claims.map(\.field), field: "observation.claims")
        self.schemaVersion = schemaVersion
        self.subject = subject
        self.parent = parent
        self.observedAtSourceMonotonicNs = observedAtSourceMonotonicNs
        self.claims = claims.sorted { $0.field < $1.field }
    }

    func validate(for sourceEpoch: SceneSourceEpoch) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw SceneContractValidationError.unsupportedSchema(
                found: schemaVersion,
                supported: Self.currentSchemaVersion
            )
        }
        guard subject.sourceEpoch == sourceEpoch,
              parent?.sourceEpoch == nil || parent?.sourceEpoch == sourceEpoch
        else {
            throw SceneContractValidationError.sourceMismatch(field: "observation.subject")
        }
        guard !claims.isEmpty else {
            throw SceneContractValidationError.empty(field: "observation.claims")
        }
        try validateCount(
            claims.count,
            maximum: SceneContractLimits.claimsPerObservation,
            field: "observation.claims"
        )
        try validateUnique(claims.map(\.field), field: "observation.claims")
        for claim in claims {
            try claim.validate(for: sourceEpoch)
        }
    }

    private enum CodingKeys: CodingKey {
        case schemaVersion, subject, parent, observedAtSourceMonotonicNs, claims
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(UInt16.self, forKey: .schemaVersion),
            subject: container.decode(SourceObjectKey.self, forKey: .subject),
            parent: container.decodeIfPresent(SourceObjectKey.self, forKey: .parent),
            observedAtSourceMonotonicNs: container.decode(
                UInt64.self,
                forKey: .observedAtSourceMonotonicNs
            ),
            claims: container.decode([SceneFieldClaim].self, forKey: .claims)
        )
    }
}

public struct SceneCheckpoint: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1

    public let schemaVersion: UInt16
    /// Complete source projection at the enclosing event revision. Empty clears it.
    public let observations: [SceneObservation]

    public init(
        schemaVersion: UInt16 = currentSchemaVersion,
        observations: [SceneObservation]
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw SceneContractValidationError.unsupportedSchema(
                found: schemaVersion,
                supported: Self.currentSchemaVersion
            )
        }
        try validateCount(
            observations.count,
            maximum: SceneContractLimits.observationsPerCheckpoint,
            field: "checkpoint.observations"
        )
        try validateUnique(observations.map(\.subject), field: "checkpoint.observations")
        self.schemaVersion = schemaVersion
        self.observations = observations.sorted {
            $0.subject.objectID.rawValue.uuidString < $1.subject.objectID.rawValue.uuidString
        }
    }

    func validate(for sourceEpoch: SceneSourceEpoch) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw SceneContractValidationError.unsupportedSchema(
                found: schemaVersion,
                supported: Self.currentSchemaVersion
            )
        }
        try validateCount(
            observations.count,
            maximum: SceneContractLimits.observationsPerCheckpoint,
            field: "checkpoint.observations"
        )
        try validateUnique(observations.map(\.subject), field: "checkpoint.observations")
        for observation in observations {
            try observation.validate(for: sourceEpoch)
        }
    }

    private enum CodingKeys: CodingKey { case schemaVersion, observations }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(UInt16.self, forKey: .schemaVersion),
            observations: container.decode([SceneObservation].self, forKey: .observations)
        )
    }
}

extension SurfaceRegion {
    func validate(field: String) throws {
        guard coordinateSpace.revision > 0 else {
            throw SceneContractValidationError.invalidRange(
                field: "\(field).coordinateSpace.revision"
            )
        }
        guard rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.size.width.isFinite, rect.size.height.isFinite
        else {
            throw SceneContractValidationError.nonFinite(field: field)
        }
        guard rect.size.width > 0, rect.size.height > 0 else {
            throw SceneContractValidationError.invalidRange(field: "\(field).size")
        }
    }
}

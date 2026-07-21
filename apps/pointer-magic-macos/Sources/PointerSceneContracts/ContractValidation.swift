import Foundation

/// Deterministic validation failures returned before an event batch reaches a reducer.
public enum SceneContractValidationError: Error, Equatable, Hashable, Sendable,
    CustomStringConvertible
{
    case unsupportedSchema(found: UInt16, supported: UInt16)
    case empty(field: String)
    case exceedsLimit(field: String, maximum: Int, actual: Int)
    case invalidFormat(field: String)
    case nonFinite(field: String)
    case invalidRange(field: String)
    case sensitiveValue(field: String)
    case duplicate(field: String, key: String)
    case mixedSourceEpoch
    case outOfOrder(previous: UInt64, next: UInt64)
    case revisionEquivocation(sequence: UInt64)
    case sourceMismatch(field: String)
    case unauthorized(field: String)
    case expired(field: String)

    public var description: String {
        switch self {
        case let .unsupportedSchema(found, supported):
            "Unsupported schema version \(found); this build supports \(supported)"
        case let .empty(field):
            "\(field) must not be empty"
        case let .exceedsLimit(field, maximum, actual):
            "\(field) contains \(actual) items or characters; maximum is \(maximum)"
        case let .invalidFormat(field):
            "\(field) has an invalid format"
        case let .nonFinite(field):
            "\(field) must be finite"
        case let .invalidRange(field):
            "\(field) is outside its permitted range"
        case let .sensitiveValue(field):
            "\(field) must not carry a value when sensitivity is secure or unknown"
        case let .duplicate(field, key):
            "\(field) contains duplicate key \(key)"
        case .mixedSourceEpoch:
            "All events in a batch must belong to one source epoch"
        case let .outOfOrder(previous, next):
            "Source revision \(next) follows \(previous) out of order"
        case let .revisionEquivocation(sequence):
            "Source revision \(sequence) was reused with different content"
        case let .sourceMismatch(field):
            "\(field) does not belong to the envelope source"
        case let .unauthorized(field):
            "\(field) is outside the source grant"
        case let .expired(field):
            "\(field) has expired"
        }
    }
}

package enum SceneContractLimits {
    package static let eventsPerBatch = 256
    static let observationsPerCheckpoint = 512
    static let observationsPerBatch = 4_096
    static let claimsPerObservation = 64
    static let claimsPerBatch = 16_384
    static let evidencePerClaim = 16
    static let evidencePerBatch = 65_536
    static let dependenciesPerClaim = 16
    static let fieldsPerInvalidation = 64
    static let fieldsPerRefresh = 64
    static let evidenceKindsPerRefresh = 16
    static let capabilitiesPerManifest = 32
    static let dependencySourcesPerGrant = 64
    static let textCharacters = 16_384
    static let shortTextCharacters = 512
    static let identifierCharacters = 128
    static let diagnosticCodeBytes = 64
    static let metadataEntries = 32
    static let textBytesPerBatch = 4 * 1_024 * 1_024
}

struct SceneBatchValidationBudget {
    private(set) var observations = 0
    private(set) var claims = 0
    private(set) var evidence = 0
    private(set) var textBytes = 0

    mutating func consume(_ payload: SceneEventPayload) throws {
        switch payload {
        case let .observation(observation):
            try consume(observation)
        case let .checkpoint(checkpoint):
            for observation in checkpoint.observations {
                try consume(observation)
            }
        case .invalidation, .coverage:
            break
        }
    }

    private mutating func consume(_ observation: SceneObservation) throws {
        try increment(
            &observations,
            by: 1,
            maximum: SceneContractLimits.observationsPerBatch,
            field: "batch.observations"
        )
        try increment(
            &claims,
            by: observation.claims.count,
            maximum: SceneContractLimits.claimsPerBatch,
            field: "batch.claims"
        )
        for claim in observation.claims {
            try increment(
                &evidence,
                by: claim.evidence.count,
                maximum: SceneContractLimits.evidencePerBatch,
                field: "batch.evidence"
            )
            let bytes = claim.textByteCount
            try increment(
                &textBytes,
                by: bytes,
                maximum: SceneContractLimits.textBytesPerBatch,
                field: "batch.textBytes"
            )
        }
    }

    private func increment(
        _ value: inout Int,
        by amount: Int,
        maximum: Int,
        field: String
    ) throws {
        let (sum, overflow) = value.addingReportingOverflow(amount)
        guard !overflow, sum <= maximum else {
            throw SceneContractValidationError.exceedsLimit(
                field: field,
                maximum: maximum,
                actual: overflow ? Int.max : sum
            )
        }
        value = sum
    }
}

@inline(__always)
func validateCount(_ count: Int, maximum: Int, field: String) throws {
    guard count <= maximum else {
        throw SceneContractValidationError.exceedsLimit(
            field: field,
            maximum: maximum,
            actual: count
        )
    }
}

@inline(__always)
func validateText(_ value: String, maximum: Int, field: String, allowEmpty: Bool = false) throws {
    if !allowEmpty, value.isEmpty {
        throw SceneContractValidationError.empty(field: field)
    }
    try validateCount(value.utf8.count, maximum: maximum, field: field)
}

/// Evidence annotations are machine-readable codes, never a second free-form content
/// channel. Keeping the alphabet closed prevents a producer from smuggling captured
/// text through diagnostics after the claim value has been privacy-redacted.
@inline(__always)
func validateDiagnosticCode(_ value: String, field: String) throws {
    try validateText(value, maximum: SceneContractLimits.diagnosticCodeBytes, field: field)
    guard value.utf8.allSatisfy({ byte in
        (byte >= 65 && byte <= 90) ||
            (byte >= 97 && byte <= 122) ||
            (byte >= 48 && byte <= 57) ||
            byte == 45 || byte == 46 || byte == 95
    }) else {
        throw SceneContractValidationError.invalidFormat(field: field)
    }
}

@inline(__always)
func validateUnique<T: Hashable>(_ values: [T], field: String) throws {
    var seen = Set<T>()
    for value in values where !seen.insert(value).inserted {
        throw SceneContractValidationError.duplicate(field: field, key: String(describing: value))
    }
}

import Foundation

public struct SourceRevision: Codable, Hashable, Sendable {
    public let sourceEpoch: SceneSourceEpoch
    public let sequence: UInt64

    public init(sourceEpoch: SceneSourceEpoch, sequence: UInt64) throws {
        guard sequence > 0 else {
            throw SceneContractValidationError.invalidRange(field: "sourceRevision.sequence")
        }
        self.sourceEpoch = sourceEpoch
        self.sequence = sequence
    }

    private enum CodingKeys: CodingKey { case sourceEpoch, sequence }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sourceEpoch: container.decode(SceneSourceEpoch.self, forKey: .sourceEpoch),
            sequence: container.decode(UInt64.self, forKey: .sequence)
        )
    }
}

public struct SourceSequenceGap: Codable, Hashable, Sendable {
    public let sourceEpoch: SceneSourceEpoch
    public let missingFrom: UInt64
    public let missingThrough: UInt64

    public init(sourceEpoch: SceneSourceEpoch, missingFrom: UInt64, missingThrough: UInt64) throws {
        guard missingFrom > 0, missingThrough >= missingFrom else {
            throw SceneContractValidationError.invalidRange(field: "sourceSequenceGap")
        }
        self.sourceEpoch = sourceEpoch
        self.missingFrom = missingFrom
        self.missingThrough = missingThrough
    }

    private enum CodingKeys: CodingKey { case sourceEpoch, missingFrom, missingThrough }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sourceEpoch: container.decode(SceneSourceEpoch.self, forKey: .sourceEpoch),
            missingFrom: container.decode(UInt64.self, forKey: .missingFrom),
            missingThrough: container.decode(UInt64.self, forKey: .missingThrough)
        )
    }
}

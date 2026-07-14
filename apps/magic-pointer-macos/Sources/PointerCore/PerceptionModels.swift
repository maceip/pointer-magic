import Foundation

public enum PerceptionEvidenceSource: String, Codable, Hashable, Sendable {
    case applicationAdapter
    case accessibility
    case accessibilityTextRange
    case browserDOM
    case windowMetadata
    case screenPixels
    case opticalCharacterRecognition
    case vision
    case semanticModel
    case temporalTracking
    case userCorrection
    case derived
}

public struct PerceptionEvidence: Codable, Hashable, Sendable {
    public var source: PerceptionEvidenceSource
    public var capturedAtNs: UInt64
    public var sourceIdentifier: String?
    public var detail: String?

    public init(
        source: PerceptionEvidenceSource,
        capturedAtNs: UInt64,
        sourceIdentifier: String? = nil,
        detail: String? = nil
    ) {
        self.source = source
        self.capturedAtNs = capturedAtNs
        self.sourceIdentifier = sourceIdentifier
        self.detail = detail
    }
}

public enum PerceptionKnowledgeState: String, Codable, Hashable, Sendable {
    case observed
    case inferred
    case ambiguous
    case unknown
}

public enum PerceptionFreshnessState: String, Codable, Hashable, Sendable {
    case live
    case current
    case stale
    case expired
    case unknown
}

public struct PerceptionFreshness: Codable, Hashable, Sendable {
    public var state: PerceptionFreshnessState
    public var observedAtNs: UInt64?
    public var validUntilNs: UInt64?

    public init(
        state: PerceptionFreshnessState,
        observedAtNs: UInt64? = nil,
        validUntilNs: UInt64? = nil
    ) {
        self.state = state
        self.observedAtNs = observedAtNs
        self.validUntilNs = validUntilNs
    }
}

/// A value together with the basis and strength of the system's claim about it.
public struct PerceptionField<Value>: Codable, Hashable, Sendable
where Value: Codable & Hashable & Sendable {
    public var value: Value?
    public var knowledge: PerceptionKnowledgeState
    /// A normalized confidence score. Initializers clamp finite values to `0...1`.
    public var confidence: Double
    public var freshness: PerceptionFreshness
    public var evidence: [PerceptionEvidence]

    public init(
        value: Value?,
        knowledge: PerceptionKnowledgeState,
        confidence: Double,
        freshness: PerceptionFreshness,
        evidence: [PerceptionEvidence] = []
    ) {
        self.value = value
        self.knowledge = knowledge
        self.confidence = confidence.isFinite ? min(max(confidence, 0), 1) : 0
        self.freshness = freshness
        self.evidence = evidence
    }
}

public enum PerceptionObjectKind: String, Codable, Hashable, CaseIterable, Sendable {
    case text
    case image
    case icon
    case control
    case chart
    case table
    case video
    case document
    case container
    case canvas
    case unknown
}

public enum PerceptionSurfaceProvenance: String, Codable, Hashable, Sendable {
    case systemChrome
    case applicationChrome
    case documentContent
    case webContent
    case editableContent
    case remotePixels
    case renderedPixels
    case unknown
}

public enum PerceptionAuthorProvenance: String, Codable, Hashable, Sendable {
    case system
    case application
    case localUser
    case remoteAuthor
    case mixed
    case unknown
}

public struct PerceptionContent: Codable, Hashable, Sendable {
    public var label: String?
    /// Text grounded to the pinned point by a structured source such as AX range APIs.
    public var textAtPoint: String?
    /// A structured value for the whole element; it is not claimed to be point-local.
    public var elementValue: String?
    /// Text inferred from rendered pixels, generally by OCR.
    public var text: String?
    public var mediaType: String?
    public var sourceLocator: String?
    public var intrinsicSize: GlobalSize?

    public init(
        label: String? = nil,
        textAtPoint: String? = nil,
        elementValue: String? = nil,
        text: String? = nil,
        mediaType: String? = nil,
        sourceLocator: String? = nil,
        intrinsicSize: GlobalSize? = nil
    ) {
        self.label = label
        self.textAtPoint = textAtPoint
        self.elementValue = elementValue
        self.text = text
        self.mediaType = mediaType
        self.sourceLocator = sourceLocator
        self.intrinsicSize = intrinsicSize
    }
}

public struct PerceptionOwner: Codable, Hashable, Sendable {
    public var processID: Int32?
    public var bundleIdentifier: String?
    public var applicationName: String?
    public var windowTitle: String?

    public init(
        processID: Int32? = nil,
        bundleIdentifier: String? = nil,
        applicationName: String? = nil,
        windowTitle: String? = nil
    ) {
        self.processID = processID
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.windowTitle = windowTitle
    }
}

public struct PerceptionObjectID: Codable, Hashable, Sendable, CustomStringConvertible {
    public var rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString }
}

public struct PerceptionAlternative: Codable, Hashable, Sendable {
    public var objectID: PerceptionObjectID
    public var summary: String?
    public var confidence: Double

    public init(
        objectID: PerceptionObjectID,
        summary: String? = nil,
        confidence: Double
    ) {
        self.objectID = objectID
        self.summary = summary
        self.confidence = confidence.isFinite ? min(max(confidence, 0), 1) : 0
    }
}

public struct PerceivedObject: Codable, Hashable, Sendable {
    public var id: PerceptionObjectID
    public var kind: PerceptionField<PerceptionObjectKind>
    public var bounds: PerceptionField<GlobalRect>
    public var content: PerceptionField<PerceptionContent>?
    public var meaning: PerceptionField<String>?
    public var owner: PerceptionField<PerceptionOwner>?
    public var surface: PerceptionField<PerceptionSurfaceProvenance>
    public var author: PerceptionField<PerceptionAuthorProvenance>
    public var parentID: PerceptionObjectID?
    public var childIDs: [PerceptionObjectID]
    public var alternatives: [PerceptionAlternative]

    public init(
        id: PerceptionObjectID = PerceptionObjectID(),
        kind: PerceptionField<PerceptionObjectKind>,
        bounds: PerceptionField<GlobalRect>,
        content: PerceptionField<PerceptionContent>? = nil,
        meaning: PerceptionField<String>? = nil,
        owner: PerceptionField<PerceptionOwner>? = nil,
        surface: PerceptionField<PerceptionSurfaceProvenance>,
        author: PerceptionField<PerceptionAuthorProvenance>,
        parentID: PerceptionObjectID? = nil,
        childIDs: [PerceptionObjectID] = [],
        alternatives: [PerceptionAlternative] = []
    ) {
        self.id = id
        self.kind = kind
        self.bounds = bounds
        self.content = content
        self.meaning = meaning
        self.owner = owner
        self.surface = surface
        self.author = author
        self.parentID = parentID
        self.childIDs = childIDs
        self.alternatives = alternatives
    }
}

public enum PerceptionSnapshotState: String, Codable, Hashable, Sendable {
    case fresh
    case enriching
    case partial
    case unavailable
    case superseded
    case failed
}

public struct PerceptionSnapshot: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var generation: UInt64
    public var pointer: GlobalPoint
    public var requestedAtNs: UInt64
    public var capturedAtNs: UInt64
    public var state: PerceptionSnapshotState
    public var selectedObjectID: PerceptionObjectID?
    /// Candidates are ordered from the most to the least likely pointer target.
    public var candidates: [PerceivedObject]

    public init(
        schemaVersion: Int = currentSchemaVersion,
        generation: UInt64,
        pointer: GlobalPoint,
        requestedAtNs: UInt64,
        capturedAtNs: UInt64,
        state: PerceptionSnapshotState,
        selectedObjectID: PerceptionObjectID? = nil,
        candidates: [PerceivedObject] = []
    ) {
        self.schemaVersion = schemaVersion
        self.generation = generation
        self.pointer = pointer
        self.requestedAtNs = requestedAtNs
        self.capturedAtNs = capturedAtNs
        self.state = state
        self.selectedObjectID = selectedObjectID
        self.candidates = candidates
    }
}

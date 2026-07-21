import Foundation

public struct SemanticTargetID: Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString }
}

public enum SemanticDetail: String, Codable, Sendable {
    case geometryAndLabel
    case enriched
}

public enum SemanticAction: String, Codable, CaseIterable, Sendable {
    case press
    case focus
    case showMenu
    case increment
    case decrement
    case confirm
    case cancel
    case raise
}

public enum SemanticFieldProvenance: String, Codable, Sendable {
    case accessibilityAttribute
    case cached
    case derived
}

public enum SemanticSensitivity: String, Codable, Sendable {
    case ordinary
    case secure
    case unknown
}

public struct SemanticAncestor: Codable, Hashable, Sendable {
    public var role: String
    public var label: String?

    public init(role: String, label: String?) {
        self.role = role
        self.label = label
    }
}

public struct SemanticTarget: Codable, Hashable, Sendable {
    public var id: SemanticTargetID
    public var generation: UInt64
    public var processID: Int32
    public var bundleIdentifier: String?
    public var role: String
    public var subrole: String?
    public var label: String?
    public var identifier: String?
    public var frame: GlobalRect?
    public var isEnabled: Bool?
    public var actions: [SemanticAction]
    public var ancestors: [SemanticAncestor]
    public var sensitivity: SemanticSensitivity
    public var wasTruncated: Bool
    /// The element's direct Accessibility value when it can be represented as text.
    /// This remains `nil` for secure or sensitivity-unknown targets.
    public var directValue: String?
    /// The smallest useful text run at the requested pointer position, when the
    /// application implements the public Accessibility text-range API.
    public var textAtPoint: String?
    /// Precise screen-space bounds corresponding to `textAtPoint`.
    public var textRangeFrame: GlobalRect?
    public var isEditable: Bool?
    public var roleDescription: String?

    public init(
        id: SemanticTargetID,
        generation: UInt64,
        processID: Int32,
        bundleIdentifier: String?,
        role: String,
        subrole: String?,
        label: String?,
        identifier: String?,
        frame: GlobalRect?,
        isEnabled: Bool?,
        actions: [SemanticAction],
        ancestors: [SemanticAncestor],
        sensitivity: SemanticSensitivity,
        wasTruncated: Bool,
        directValue: String? = nil,
        textAtPoint: String? = nil,
        textRangeFrame: GlobalRect? = nil,
        isEditable: Bool? = nil,
        roleDescription: String? = nil
    ) {
        self.id = id
        self.generation = generation
        self.processID = processID
        self.bundleIdentifier = bundleIdentifier
        self.role = role
        self.subrole = subrole
        self.label = label
        self.identifier = identifier
        self.frame = frame
        self.isEnabled = isEnabled
        self.actions = actions
        self.ancestors = ancestors
        self.sensitivity = sensitivity
        self.wasTruncated = wasTruncated
        self.directValue = directValue
        self.textAtPoint = textAtPoint
        self.textRangeFrame = textRangeFrame
        self.isEditable = isEditable
        self.roleDescription = roleDescription
    }
}

public enum SemanticResolutionState: String, Codable, Sendable {
    case fresh
    case cached
    case partial
    case unavailable
    case timedOut
    case superseded
    case failed
}

public enum SemanticFailureCode: String, Codable, Sendable {
    case accessibilityDenied
    case noElement
    case cannotComplete
    case invalidElement
    case unsupported
    case circuitOpen
    case queueFull
    case staleGeneration
    case unknown
}

public struct SemanticSnapshot: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var generation: UInt64
    public var requestedAtNs: UInt64
    public var capturedAtNs: UInt64
    public var resolutionLatencyNs: UInt64
    public var state: SemanticResolutionState
    public var target: SemanticTarget?
    public var failure: SemanticFailureCode?

    public init(
        schemaVersion: Int = currentSchemaVersion,
        generation: UInt64,
        requestedAtNs: UInt64,
        capturedAtNs: UInt64,
        resolutionLatencyNs: UInt64,
        state: SemanticResolutionState,
        target: SemanticTarget?,
        failure: SemanticFailureCode?
    ) {
        self.schemaVersion = schemaVersion
        self.generation = generation
        self.requestedAtNs = requestedAtNs
        self.capturedAtNs = capturedAtNs
        self.resolutionLatencyNs = resolutionLatencyNs
        self.state = state
        self.target = target
        self.failure = failure
    }
}

public struct SemanticRequest: Codable, Hashable, Sendable {
    public var generation: UInt64
    public var point: GlobalPoint
    public var requestedAtNs: UInt64
    public var deadlineNs: UInt64
    public var detail: SemanticDetail

    public init(
        generation: UInt64,
        point: GlobalPoint,
        requestedAtNs: UInt64,
        deadlineNs: UInt64 = 60_000_000,
        detail: SemanticDetail = .geometryAndLabel
    ) {
        self.generation = generation
        self.point = point
        self.requestedAtNs = requestedAtNs
        self.deadlineNs = deadlineNs
        self.detail = detail
    }
}

public struct SemanticActionRequest: Codable, Hashable, Sendable {
    public var targetID: SemanticTargetID
    public var expectedGeneration: UInt64
    public var action: SemanticAction

    public init(
        targetID: SemanticTargetID,
        expectedGeneration: UInt64,
        action: SemanticAction
    ) {
        self.targetID = targetID
        self.expectedGeneration = expectedGeneration
        self.action = action
    }
}

public enum SemanticActionOutcome: String, Codable, Sendable {
    case succeeded
    case failed
    case outcomeUnknown
    case rejected
}

public struct SemanticActionResult: Codable, Hashable, Sendable {
    public var outcome: SemanticActionOutcome
    public var failure: SemanticFailureCode?

    public init(outcome: SemanticActionOutcome, failure: SemanticFailureCode? = nil) {
        self.outcome = outcome
        self.failure = failure
    }

    public var succeeded: Bool { outcome == .succeeded }
}

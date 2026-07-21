import Foundation
import PointerCore

/// Host-bridged AX evidence. Keeps the assembler free of Accessibility SDK types.
public struct ContextAssemblySemanticInput: Codable, Hashable, Sendable {
    public var state: String
    public var targetID: String?
    public var processID: Int32?
    public var bundleIdentifier: String?
    public var role: String?
    public var subrole: String?
    public var label: String?
    public var directValue: String?
    public var textAtPoint: String?
    public var textRangeFrame: GlobalRect?
    public var frame: GlobalRect?
    public var isEditable: Bool?
    public var sensitivityIsSecure: Bool

    public init(
        state: String,
        targetID: String? = nil,
        processID: Int32? = nil,
        bundleIdentifier: String? = nil,
        role: String? = nil,
        subrole: String? = nil,
        label: String? = nil,
        directValue: String? = nil,
        textAtPoint: String? = nil,
        textRangeFrame: GlobalRect? = nil,
        frame: GlobalRect? = nil,
        isEditable: Bool? = nil,
        sensitivityIsSecure: Bool = false
    ) {
        self.state = state
        self.targetID = targetID
        self.processID = processID
        self.bundleIdentifier = bundleIdentifier
        self.role = role
        self.subrole = subrole
        self.label = label
        self.directValue = directValue
        self.textAtPoint = textAtPoint
        self.textRangeFrame = textRangeFrame
        self.frame = frame
        self.isEditable = isEditable
        self.sensitivityIsSecure = sensitivityIsSecure
    }
}

public struct ContextAssemblyOCRObservation: Codable, Hashable, Sendable {
    public var text: String
    public var confidence: Float
    public var bounds: GlobalRect?

    public init(text: String, confidence: Float, bounds: GlobalRect? = nil) {
        self.text = text
        self.confidence = confidence
        self.bounds = bounds
    }
}

public struct ContextAssemblyPerceptionInput: Codable, Hashable, Sendable {
    public var state: String
    public var observations: [ContextAssemblyOCRObservation]
    public var cropBounds: GlobalRect?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var thumbToken: String?

    public init(
        state: String,
        observations: [ContextAssemblyOCRObservation] = [],
        cropBounds: GlobalRect? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        thumbToken: String? = nil
    ) {
        self.state = state
        self.observations = observations
        self.cropBounds = cropBounds
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.thumbToken = thumbToken
    }
}

public struct ContextAssemblySceneInput: Codable, Hashable, Sendable {
    public var bundleIdentifier: String?
    public var applicationName: String?
    public var windowTitle: String?
    public var processID: Int32?
    public var isStale: Bool

    public init(
        bundleIdentifier: String? = nil,
        applicationName: String? = nil,
        windowTitle: String? = nil,
        processID: Int32? = nil,
        isStale: Bool = false
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.windowTitle = windowTitle
        self.processID = processID
        self.isStale = isStale
    }
}

public struct ContextAssemblyInput: Codable, Hashable, Sendable {
    public var revision: UInt64
    public var generation: UInt64
    public var sequence: UInt64
    public var assembledAtNs: UInt64
    public var point: GlobalPoint
    public var displayID: UInt32?
    public var semantic: ContextAssemblySemanticInput?
    public var perception: ContextAssemblyPerceptionInput?
    public var scene: ContextAssemblySceneInput?

    public init(
        revision: UInt64,
        generation: UInt64,
        sequence: UInt64,
        assembledAtNs: UInt64,
        point: GlobalPoint,
        displayID: UInt32? = nil,
        semantic: ContextAssemblySemanticInput? = nil,
        perception: ContextAssemblyPerceptionInput? = nil,
        scene: ContextAssemblySceneInput? = nil
    ) {
        self.revision = revision
        self.generation = generation
        self.sequence = sequence
        self.assembledAtNs = assembledAtNs
        self.point = point
        self.displayID = displayID
        self.semantic = semantic
        self.perception = perception
        self.scene = scene
    }
}

import Foundation

/// A Quartz-global point. Quartz screen space has its origin at the top-left of the
/// primary display and its Y axis points down.
public struct PerceptionPoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct PerceptionSize: Codable, Hashable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct PerceptionRect: Codable, Hashable, Sendable {
    public var origin: PerceptionPoint
    public var size: PerceptionSize

    public init(x: Double, y: Double, width: Double, height: Double) {
        origin = PerceptionPoint(x: x, y: y)
        size = PerceptionSize(width: width, height: height)
    }

    public var minX: Double { origin.x }
    public var minY: Double { origin.y }
    public var maxX: Double { origin.x + size.width }
    public var maxY: Double { origin.y + size.height }
}

public enum PerceptionTextRecognitionLevel: String, Codable, Sendable {
    case fast
    case accurate
}

public struct VisualPerceptionRequest: Codable, Hashable, Sendable {
    public var generation: UInt64
    public var point: PerceptionPoint
    /// Optional capture center when the semantic object's center is more useful than
    /// centering the crop on the pointer itself. `point` remains the pinned hit point.
    public var cropCenter: PerceptionPoint?
    public var cropSizePoints: PerceptionSize
    public var textRecognitionLevel: PerceptionTextRecognitionLevel
    public var includeImageClassifications: Bool
    public var includeForegroundSummary: Bool
    public var includeCropPNG: Bool
    /// Uses an application-filtered ScreenCaptureKit path so Magic Pointer's own
    /// companion, outline, and panel cannot become perception input.
    public var excludeCurrentApplication: Bool
    public var maximumClassificationCount: Int
    public var minimumClassificationConfidence: Float

    public init(
        generation: UInt64,
        point: PerceptionPoint,
        cropCenter: PerceptionPoint? = nil,
        cropSizePoints: PerceptionSize = PerceptionSize(width: 480, height: 320),
        textRecognitionLevel: PerceptionTextRecognitionLevel = .fast,
        includeImageClassifications: Bool = true,
        includeForegroundSummary: Bool = true,
        includeCropPNG: Bool = true,
        excludeCurrentApplication: Bool = false,
        maximumClassificationCount: Int = 8,
        minimumClassificationConfidence: Float = 0.08
    ) {
        self.generation = generation
        self.point = point
        self.cropCenter = cropCenter
        self.cropSizePoints = cropSizePoints
        self.textRecognitionLevel = textRecognitionLevel
        self.includeImageClassifications = includeImageClassifications
        self.includeForegroundSummary = includeForegroundSummary
        self.includeCropPNG = includeCropPNG
        self.excludeCurrentApplication = excludeCurrentApplication
        self.maximumClassificationCount = maximumClassificationCount
        self.minimumClassificationConfidence = minimumClassificationConfidence
    }
}

public enum VisualPerceptionState: String, Codable, Sendable {
    case fresh
    case partial
    case unavailable
    case failed
    case superseded
}

public enum VisualPerceptionFailure: String, Codable, Sendable {
    case screenRecordingPermissionDenied
    case captureUnavailable
    case pointOutsideDisplays
    case invalidCropSize
    case captureFailed
    case visionFailed
    case sensitivityRestricted
    case captureScopeNotGrounded
    case superseded
    case cancelled
}

public enum PerceptionCapturePath: String, Codable, Sendable {
    /// Configured display-agnostic capture on macOS 26+, with the cursor omitted.
    case screenCaptureKitConfiguredRegion
    /// Display-agnostic bounded capture, public on macOS 15.2 and newer.
    case screenCaptureKitRegion
    /// Display-filtered bounded capture used on macOS 14 and 15.0/15.1.
    case screenCaptureKitDisplayFallback
}

public struct PerceptionCropMetadata: Codable, Hashable, Sendable {
    /// The bounded rectangle requested from ScreenCaptureKit, in Quartz-global points.
    public var globalRect: PerceptionRect
    public var pointer: PerceptionPoint
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var pixelsPerPointX: Double
    public var pixelsPerPointY: Double
    public var capturePath: PerceptionCapturePath

    public init(
        globalRect: PerceptionRect,
        pointer: PerceptionPoint,
        pixelWidth: Int,
        pixelHeight: Int,
        pixelsPerPointX: Double,
        pixelsPerPointY: Double,
        capturePath: PerceptionCapturePath
    ) {
        self.globalRect = globalRect
        self.pointer = pointer
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.pixelsPerPointX = pixelsPerPointX
        self.pixelsPerPointY = pixelsPerPointY
        self.capturePath = capturePath
    }
}

public struct RecognizedTextCandidate: Codable, Hashable, Sendable {
    public var text: String
    public var confidence: Float

    public init(text: String, confidence: Float) {
        self.text = text
        self.confidence = confidence
    }
}

public struct PerceptionTextObservation: Codable, Hashable, Sendable {
    public var text: String
    public var confidence: Float

    /// Vision-normalized bounds with a lower-left origin, relative to the crop.
    public var normalizedBounds: PerceptionRect

    /// Bounds converted to top-left-origin Quartz-global points.
    public var globalBounds: PerceptionRect
    public var alternateCandidates: [RecognizedTextCandidate]

    public init(
        text: String,
        confidence: Float,
        normalizedBounds: PerceptionRect,
        globalBounds: PerceptionRect,
        alternateCandidates: [RecognizedTextCandidate]
    ) {
        self.text = text
        self.confidence = confidence
        self.normalizedBounds = normalizedBounds
        self.globalBounds = globalBounds
        self.alternateCandidates = alternateCandidates
    }
}

public struct PerceptionImageClassification: Codable, Hashable, Sendable {
    /// Vision taxonomy identifier. It is technical metadata, not localized UI copy.
    public var identifier: String
    public var confidence: Float

    public init(identifier: String, confidence: Float) {
        self.identifier = identifier
        self.confidence = confidence
    }
}

public struct PerceptionForegroundSummary: Codable, Hashable, Sendable {
    public var salientInstanceCount: Int
    public var maskPixelWidth: Int
    public var maskPixelHeight: Int

    public init(salientInstanceCount: Int, maskPixelWidth: Int, maskPixelHeight: Int) {
        self.salientInstanceCount = salientInstanceCount
        self.maskPixelWidth = maskPixelWidth
        self.maskPixelHeight = maskPixelHeight
    }
}

public enum PerceptionDiagnosticStage: String, Codable, Sendable {
    case capture
    case textRecognition
    case imageClassification
    case foregroundSegmentation
    case cropEncoding
}

public struct PerceptionDiagnostic: Codable, Hashable, Sendable {
    public var stage: PerceptionDiagnosticStage
    public var message: String

    public init(stage: PerceptionDiagnosticStage, message: String) {
        self.stage = stage
        self.message = message
    }
}

public struct VisualPerceptionResult: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var generation: UInt64
    public var requestedAtNs: UInt64
    public var completedAtNs: UInt64
    public var totalLatencyNs: UInt64
    public var state: VisualPerceptionState
    public var failure: VisualPerceptionFailure?
    public var crop: PerceptionCropMetadata?
    public var cropPNG: Data?
    public var textObservations: [PerceptionTextObservation]
    public var imageClassifications: [PerceptionImageClassification]
    public var foreground: PerceptionForegroundSummary?
    public var diagnostics: [PerceptionDiagnostic]

    public init(
        schemaVersion: Int = currentSchemaVersion,
        generation: UInt64,
        requestedAtNs: UInt64,
        completedAtNs: UInt64,
        state: VisualPerceptionState,
        failure: VisualPerceptionFailure? = nil,
        crop: PerceptionCropMetadata? = nil,
        cropPNG: Data? = nil,
        textObservations: [PerceptionTextObservation] = [],
        imageClassifications: [PerceptionImageClassification] = [],
        foreground: PerceptionForegroundSummary? = nil,
        diagnostics: [PerceptionDiagnostic] = []
    ) {
        self.schemaVersion = schemaVersion
        self.generation = generation
        self.requestedAtNs = requestedAtNs
        self.completedAtNs = completedAtNs
        totalLatencyNs = completedAtNs >= requestedAtNs ? completedAtNs - requestedAtNs : 0
        self.state = state
        self.failure = failure
        self.crop = crop
        self.cropPNG = cropPNG
        self.textObservations = textObservations
        self.imageClassifications = imageClassifications
        self.foreground = foreground
        self.diagnostics = diagnostics
    }
}

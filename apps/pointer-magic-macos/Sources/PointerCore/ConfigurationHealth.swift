import Foundation

public enum SemanticPolicy: Codable, Hashable, Sendable {
    case onDemand
    case settled(delayNs: UInt64, radius: Double, minimumIntervalNs: UInt64)

    public static let quietSettled = SemanticPolicy.settled(
        delayNs: 85_000_000,
        radius: 4,
        minimumIntervalNs: 80_000_000
    )
}

public struct PointerConfiguration: Codable, Hashable, Sendable {
    public var semanticPolicy: SemanticPolicy
    public var allowPositionOnlyFallback: Bool
    public var reduceMotion: Bool
    public var semanticCacheLifetimeNs: UInt64

    public init(
        semanticPolicy: SemanticPolicy = .quietSettled,
        allowPositionOnlyFallback: Bool = true,
        reduceMotion: Bool = false,
        semanticCacheLifetimeNs: UInt64 = 80_000_000
    ) {
        self.semanticPolicy = semanticPolicy
        self.allowPositionOnlyFallback = allowPositionOnlyFallback
        self.reduceMotion = reduceMotion
        self.semanticCacheLifetimeNs = semanticCacheLifetimeNs
    }
}

public enum PointerPermission: String, Codable, CaseIterable, Sendable {
    case inputMonitoring
    case accessibility
}

public enum PermissionState: String, Codable, Sendable {
    case granted
    case denied
    case unknown
}

public struct PermissionReport: Codable, Hashable, Sendable {
    public var inputMonitoring: PermissionState
    public var accessibility: PermissionState

    public init(inputMonitoring: PermissionState, accessibility: PermissionState) {
        self.inputMonitoring = inputMonitoring
        self.accessibility = accessibility
    }
}

public enum PointerCaptureMode: String, Codable, Sendable {
    case eventTap
    case positionOnly
    case stopped
}

public struct EventTapMetrics: Codable, Hashable, Sendable {
    public var callbackCount: UInt64
    public var callbackAverageNs: UInt64
    public var callbackMaximumNs: UInt64
    public var callbackP99UpperBoundNs: UInt64
    public var tapDisabledCount: UInt64
    public var discreteOverflowCount: UInt64

    public init(
        callbackCount: UInt64 = 0,
        callbackAverageNs: UInt64 = 0,
        callbackMaximumNs: UInt64 = 0,
        callbackP99UpperBoundNs: UInt64 = 0,
        tapDisabledCount: UInt64 = 0,
        discreteOverflowCount: UInt64 = 0
    ) {
        self.callbackCount = callbackCount
        self.callbackAverageNs = callbackAverageNs
        self.callbackMaximumNs = callbackMaximumNs
        self.callbackP99UpperBoundNs = callbackP99UpperBoundNs
        self.tapDisabledCount = tapDisabledCount
        self.discreteOverflowCount = discreteOverflowCount
    }
}

public struct LatencySummary: Codable, Hashable, Sendable {
    public var sampleCount: Int
    public var medianNs: UInt64
    public var p95Ns: UInt64
    public var p99Ns: UInt64
    public var maximumNs: UInt64

    public init(
        sampleCount: Int = 0,
        medianNs: UInt64 = 0,
        p95Ns: UInt64 = 0,
        p99Ns: UInt64 = 0,
        maximumNs: UInt64 = 0
    ) {
        self.sampleCount = sampleCount
        self.medianNs = medianNs
        self.p95Ns = p95Ns
        self.p99Ns = p99Ns
        self.maximumNs = maximumNs
    }
}

public struct HealthSnapshot: Codable, Hashable, Sendable {
    public var capturedAtNs: UInt64
    public var captureMode: PointerCaptureMode
    public var permissions: PermissionReport
    public var eventTap: EventTapMetrics
    public var renderSubmitLatency: LatencySummary
    public var latestGeneration: UInt64
    public var latestSemanticState: SemanticResolutionState?

    public init(
        capturedAtNs: UInt64,
        captureMode: PointerCaptureMode,
        permissions: PermissionReport,
        eventTap: EventTapMetrics,
        renderSubmitLatency: LatencySummary,
        latestGeneration: UInt64,
        latestSemanticState: SemanticResolutionState?
    ) {
        self.capturedAtNs = capturedAtNs
        self.captureMode = captureMode
        self.permissions = permissions
        self.eventTap = eventTap
        self.renderSubmitLatency = renderSubmitLatency
        self.latestGeneration = latestGeneration
        self.latestSemanticState = latestSemanticState
    }
}

public struct StartReport: Codable, Hashable, Sendable {
    public var captureMode: PointerCaptureMode
    public var permissions: PermissionReport
    public var started: Bool

    public init(captureMode: PointerCaptureMode, permissions: PermissionReport, started: Bool) {
        self.captureMode = captureMode
        self.permissions = permissions
        self.started = started
    }
}

/// Tunable thresholds for deliberate pointer-shake activation.
///
/// Distances are expressed in global display points. The defaults require several
/// substantial, nearly collinear reversals that return close to their starting point.
public struct ShakeActivationConfiguration: Hashable, Sendable {
    public let maximumDurationNs: UInt64
    public let minimumSegmentDistance: Double
    public let minimumPathLength: Double
    public let maximumNetDisplacement: Double
    public let maximumNetToPathRatio: Double
    public let minimumReversalCount: Int
    public let minimumAxisAlignment: Double
    public let cooldownNs: UInt64

    public init(
        maximumDurationNs: UInt64 = 650_000_000,
        minimumSegmentDistance: Double = 14,
        minimumPathLength: Double = 180,
        maximumNetDisplacement: Double = 48,
        maximumNetToPathRatio: Double = 0.28,
        minimumReversalCount: Int = 4,
        minimumAxisAlignment: Double = 0.72,
        cooldownNs: UInt64 = 1_200_000_000
    ) {
        precondition(maximumDurationNs > 0)
        precondition(minimumSegmentDistance.isFinite && minimumSegmentDistance > 0)
        precondition(minimumPathLength.isFinite && minimumPathLength > 0)
        precondition(maximumNetDisplacement.isFinite && maximumNetDisplacement >= 0)
        precondition(
            maximumNetToPathRatio.isFinite &&
                maximumNetToPathRatio >= 0 &&
                maximumNetToPathRatio <= 1
        )
        precondition(minimumReversalCount > 0)
        precondition(
            minimumAxisAlignment.isFinite &&
                minimumAxisAlignment >= 0 &&
                minimumAxisAlignment <= 1
        )

        self.maximumDurationNs = maximumDurationNs
        self.minimumSegmentDistance = minimumSegmentDistance
        self.minimumPathLength = minimumPathLength
        self.maximumNetDisplacement = maximumNetDisplacement
        self.maximumNetToPathRatio = maximumNetToPathRatio
        self.minimumReversalCount = minimumReversalCount
        self.minimumAxisAlignment = minimumAxisAlignment
        self.cooldownNs = cooldownNs
    }
}

/// Fixed-size, allocation-bounded state for recognizing a deliberate pointer shake.
///
/// `observe(_:)` stores only scalar values. It does not retain frames or append samples to
/// a collection. Only ordinary `.moved` frames are eligible: button, drag, and fallback
/// frames cancel the candidate so a shake can never activate during an unknown or pressed
/// button state.
public struct ShakeActivationDetector: Sendable {
    public let configuration: ShakeActivationConfiguration

    private var candidateOrigin = GlobalPoint(x: 0, y: 0)
    private var lastAcceptedPoint = GlobalPoint(x: 0, y: 0)
    private var candidateStartedAtNs: UInt64 = 0
    private var lastObservedAtNs: UInt64 = 0
    private var cooldownUntilNs: UInt64 = 0
    private var axisX: Double = 0
    private var axisY: Double = 0
    private var pathLength: Double = 0
    private var reversalCount: Int = 0
    private var lastDirection: Int8 = 0
    private var hasCandidate = false
    private var hasAxis = false
    private var hasObservedTimestamp = false

    public init(configuration: ShakeActivationConfiguration = .init()) {
        self.configuration = configuration
    }

    /// Returns `true` exactly once when the current sample completes a valid shake.
    @discardableResult
    public mutating func observe(_ frame: PointerFrame) -> Bool {
        observe(
            point: frame.coordinates.quartzGlobal,
            timestampNs: frame.observedTimestampNs,
            kind: frame.kind,
            buttons: frame.buttons
        )
    }

    /// Primitive entry point for callers that already have fixed pointer fields.
    @discardableResult
    public mutating func observe(
        point: GlobalPoint,
        timestampNs: UInt64,
        kind: PointerEventKind,
        buttons: PointerButtonMask
    ) -> Bool {
        guard point.x.isFinite, point.y.isFinite else {
            resetCandidate()
            return false
        }

        if hasObservedTimestamp, timestampNs < lastObservedAtNs {
            reset()
        }
        lastObservedAtNs = timestampNs
        hasObservedTimestamp = true

        guard kind == .moved, buttons.isEmpty else {
            resetCandidate()
            return false
        }

        guard timestampNs >= cooldownUntilNs else {
            resetCandidate()
            return false
        }

        guard hasCandidate else {
            beginCandidate(at: point, timestampNs: timestampNs)
            return false
        }

        let elapsedNs = timestampNs - candidateStartedAtNs
        guard elapsedNs <= configuration.maximumDurationNs else {
            beginCandidate(at: point, timestampNs: timestampNs)
            return false
        }

        let dx = point.x - lastAcceptedPoint.x
        let dy = point.y - lastAcceptedPoint.y
        let distanceSquared = (dx * dx) + (dy * dy)
        let minimumDistanceSquared =
            configuration.minimumSegmentDistance * configuration.minimumSegmentDistance
        guard distanceSquared >= minimumDistanceSquared else {
            return false
        }

        let distance = distanceSquared.squareRoot()
        if !hasAxis {
            axisX = dx / distance
            axisY = dy / distance
            hasAxis = true
            lastDirection = 1
        } else {
            let projection = (dx * axisX) + (dy * axisY)
            let alignment = Swift.abs(projection) / distance
            guard alignment >= configuration.minimumAxisAlignment else {
                beginCandidate(at: point, timestampNs: timestampNs)
                return false
            }

            let direction: Int8 = projection >= 0 ? 1 : -1
            if direction != lastDirection {
                reversalCount += 1
                lastDirection = direction
            }
        }

        pathLength += distance
        lastAcceptedPoint = point

        guard reversalCount >= configuration.minimumReversalCount,
              pathLength >= configuration.minimumPathLength
        else {
            return false
        }

        let netDX = point.x - candidateOrigin.x
        let netDY = point.y - candidateOrigin.y
        let netDistanceSquared = (netDX * netDX) + (netDY * netDY)
        let maximumNetSquared =
            configuration.maximumNetDisplacement * configuration.maximumNetDisplacement
        guard netDistanceSquared <= maximumNetSquared else {
            return false
        }

        let maximumRatioDistance = pathLength * configuration.maximumNetToPathRatio
        guard netDistanceSquared <= maximumRatioDistance * maximumRatioDistance else {
            return false
        }

        let (cooldownEnd, overflow) = timestampNs.addingReportingOverflow(
            configuration.cooldownNs
        )
        cooldownUntilNs = overflow ? UInt64.max : cooldownEnd
        resetCandidate()
        return true
    }

    /// Restores pristine state, including clearing an active cooldown.
    public mutating func reset() {
        resetCandidate()
        lastObservedAtNs = 0
        cooldownUntilNs = 0
        hasObservedTimestamp = false
    }

    private mutating func beginCandidate(at point: GlobalPoint, timestampNs: UInt64) {
        candidateOrigin = point
        lastAcceptedPoint = point
        candidateStartedAtNs = timestampNs
        axisX = 0
        axisY = 0
        pathLength = 0
        reversalCount = 0
        lastDirection = 0
        hasCandidate = true
        hasAxis = false
    }

    private mutating func resetCandidate() {
        candidateOrigin = GlobalPoint(x: 0, y: 0)
        lastAcceptedPoint = GlobalPoint(x: 0, y: 0)
        candidateStartedAtNs = 0
        axisX = 0
        axisY = 0
        pathLength = 0
        reversalCount = 0
        lastDirection = 0
        hasCandidate = false
        hasAxis = false
    }
}

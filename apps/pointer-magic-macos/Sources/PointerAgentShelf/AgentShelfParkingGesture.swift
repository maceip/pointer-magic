import CoreGraphics
import PointerCore

/// Mouse-only, allocation-bounded recognition for parking the agent shelf.
/// It samples the same global cursor position already used by the follower, so
/// it remains available without a keyboard hook or Input Monitoring permission.
struct AgentShelfParkingGesture {
    private static let configuration = ShakeActivationConfiguration(
        maximumDurationNs: 1_100_000_000,
        minimumSegmentDistance: 8,
        minimumPathLength: 100,
        maximumNetDisplacement: 64,
        maximumNetToPathRatio: 0.40,
        minimumReversalCount: 3,
        minimumAxisAlignment: 0.58,
        cooldownNs: 1_200_000_000
    )
    private static let newGestureGapNs: UInt64 = 250_000_000

    private var detector = ShakeActivationDetector(configuration: configuration)
    private var lastPolledPoint: CGPoint?
    private var lastMovementTimestampNs: UInt64?
    private var lastActivationTimestampNs: UInt64?
    private var lastObservedTimestampNs: UInt64?

    mutating func observe(
        point: CGPoint,
        timestampNs: UInt64,
        buttonsArePressed: Bool
    ) -> Bool {
        if let lastObservedTimestampNs, timestampNs < lastObservedTimestampNs {
            reset()
        }
        lastObservedTimestampNs = timestampNs

        guard let previousPoint = lastPolledPoint else {
            lastPolledPoint = point
            if buttonsArePressed {
                _ = detector.observe(
                    point: GlobalPoint(x: point.x, y: point.y),
                    timestampNs: timestampNs,
                    kind: .dragged,
                    buttons: .primary
                )
            }
            return false
        }
        lastPolledPoint = point

        if isCoolingDown(at: timestampNs) {
            // Trailing samples from the park wiggle (and the post-lock reset window)
            // must not rebuild a candidate or fire release.
            return false
        }

        if buttonsArePressed {
            lastMovementTimestampNs = nil
            return detector.observe(
                point: GlobalPoint(x: point.x, y: point.y),
                timestampNs: timestampNs,
                kind: .dragged,
                buttons: .primary
            )
        }

        // A display link calls this method even while the pointer is perfectly still.
        // Do not let those idle ticks start or age the gesture candidate. The clock must
        // begin with physical motion, independent of where the display-link phase lands.
        guard point != previousPoint else { return false }

        let beginsNewGesture: Bool
        if let lastMovementTimestampNs,
           timestampNs >= lastMovementTimestampNs
        {
            beginsNewGesture = timestampNs - lastMovementTimestampNs >
                Self.newGestureGapNs
        } else {
            beginsNewGesture = true
        }

        if beginsNewGesture {
            // Seed with the last stationary point at the timestamp of the first motion.
            // That preserves the first leg without charging idle time to the gesture.
            detector.reset()
            _ = detector.observe(
                point: GlobalPoint(x: previousPoint.x, y: previousPoint.y),
                timestampNs: timestampNs,
                kind: .moved,
                buttons: []
            )
        }
        lastMovementTimestampNs = timestampNs

        let activated = detector.observe(
            point: GlobalPoint(x: point.x, y: point.y),
            timestampNs: timestampNs,
            kind: .moved,
            buttons: []
        )
        if activated {
            lastActivationTimestampNs = timestampNs
        }
        return activated
    }

    /// Clears in-flight candidate state but keeps the activation cooldown so the
    /// same physical wiggle cannot immediately park-then-release.
    mutating func clearCandidatePreservingCooldown(at timestampNs: UInt64) {
        detector.reset()
        lastPolledPoint = nil
        lastMovementTimestampNs = nil
        lastObservedTimestampNs = timestampNs
        lastActivationTimestampNs = timestampNs
    }

    mutating func reset() {
        detector.reset()
        lastPolledPoint = nil
        lastMovementTimestampNs = nil
        lastActivationTimestampNs = nil
        lastObservedTimestampNs = nil
    }

    private func isCoolingDown(at timestampNs: UInt64) -> Bool {
        guard let lastActivationTimestampNs,
              timestampNs >= lastActivationTimestampNs
        else { return false }
        return timestampNs - lastActivationTimestampNs < Self.configuration.cooldownNs
    }
}

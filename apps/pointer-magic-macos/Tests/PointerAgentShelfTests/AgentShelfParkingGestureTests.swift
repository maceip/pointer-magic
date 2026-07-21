import CoreGraphics
@testable import PointerAgentShelf
import Testing

@Suite("Agent shelf parking gesture")
struct AgentShelfParkingGestureTests {
    @Test("A normal three-reversal wiggle requests parking")
    func naturalWiggleRequestsParking() {
        var gesture = AgentShelfParkingGesture()
        let samples: [(UInt64, CGFloat, CGFloat)] = [
            (0, 0, 0),
            (140, 35, 2),
            (280, -20, -1),
            (420, 35, 1),
            (560, 0, 0),
        ]

        var didPark = false
        for (milliseconds, x, y) in samples {
            didPark = gesture.observe(
                point: CGPoint(x: x, y: y),
                timestampNs: milliseconds * 1_000_000,
                buttonsArePressed: false
            ) || didPark
        }

        #expect(didPark)
    }

    @Test("Post-park cooldown ignores trailing wiggle samples")
    func cooldownBlocksImmediateRelease() {
        var gesture = AgentShelfParkingGesture()
        let parkSamples: [(UInt64, CGFloat, CGFloat)] = [
            (0, 0, 0),
            (140, 35, 2),
            (280, -20, -1),
            (420, 35, 1),
            (560, 0, 0),
        ]
        var didPark = false
        for (milliseconds, x, y) in parkSamples {
            didPark = gesture.observe(
                point: CGPoint(x: x, y: y),
                timestampNs: milliseconds * 1_000_000,
                buttonsArePressed: false
            ) || didPark
        }
        #expect(didPark)

        gesture.clearCandidatePreservingCooldown(at: 560 * 1_000_000)

        let trailing: [(UInt64, CGFloat, CGFloat)] = [
            (600, 35, 2),
            (740, -20, -1),
            (880, 35, 1),
            (1_020, 0, 0),
        ]
        for (milliseconds, x, y) in trailing {
            let activated = gesture.observe(
                point: CGPoint(x: x, y: y),
                timestampNs: milliseconds * 1_000_000,
                buttonsArePressed: false
            )
            #expect(!activated)
        }
    }

    @Test("Idle display-link samples cannot consume the gesture window", arguments: [
        UInt64(0), 100, 200, 300, 400, 500, 600, 700, 800, 900,
    ])
    func idleSamplingDoesNotConsumeGestureWindow(startOffsetMs: UInt64) {
        var gesture = AgentShelfParkingGesture()
        let frameNs: UInt64 = 8_333_333
        let motionStartsNs = 2_000_000_000 + (startOffsetMs * 1_000_000)

        var timestampNs: UInt64 = 0
        while timestampNs < motionStartsNs {
            let activatedWhileIdle = gesture.observe(
                point: .zero,
                timestampNs: timestampNs,
                buttonsArePressed: false
            )
            #expect(!activatedWhileIdle)
            timestampNs += frameNs
        }

        let keyframes: [(UInt64, CGFloat)] = [
            (0, 0), (160, 36), (320, -24), (480, 36), (640, 0),
        ]
        var didPark = false
        for index in 1 ..< keyframes.count {
            let (startMs, startX) = keyframes[index - 1]
            let (endMs, endX) = keyframes[index]
            let segmentStartNs = motionStartsNs + (startMs * 1_000_000)
            let segmentEndNs = motionStartsNs + (endMs * 1_000_000)
            var sampleNs = max(timestampNs, segmentStartNs)
            while sampleNs <= segmentEndNs {
                let progress = CGFloat(sampleNs - segmentStartNs) /
                    CGFloat(segmentEndNs - segmentStartNs)
                let x = startX + ((endX - startX) * progress)
                didPark = gesture.observe(
                    point: CGPoint(x: x, y: 1),
                    timestampNs: sampleNs,
                    buttonsArePressed: false
                ) || didPark
                sampleNs += frameNs
            }
            timestampNs = sampleNs
        }

        #expect(didPark)
    }

    @Test("Ordinary one-way pointer travel does not park")
    func oneWayTravelDoesNotPark() {
        var gesture = AgentShelfParkingGesture()
        for index in 0 ... 8 {
            let didPark = gesture.observe(
                point: CGPoint(x: index * 30, y: index * 4),
                timestampNs: UInt64(index * 80) * 1_000_000,
                buttonsArePressed: false
            )
            #expect(!didPark)
        }
    }

    @Test("Dragging can never request parking")
    func dragDoesNotPark() {
        var gesture = AgentShelfParkingGesture()
        let samples: [(UInt64, CGFloat)] = [
            (0, 0), (140, 35), (280, -20), (420, 35), (560, 0),
        ]

        for (milliseconds, x) in samples {
            let didPark = gesture.observe(
                point: CGPoint(x: x, y: 0),
                timestampNs: milliseconds * 1_000_000,
                buttonsArePressed: true
            )
            #expect(!didPark)
        }
    }
}

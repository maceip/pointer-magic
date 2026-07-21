import PointerCore
import Testing

@Suite("Shake activation detector")
struct ShakeActivationDetectorTests {
    private let millisecond: UInt64 = 1_000_000

    @Test("Deliberate alternating movement activates at the 650 millisecond boundary")
    func deliberateShakeActivates() {
        var detector = ShakeActivationDetector()

        expectNoActivation(frame(x: 0, timeMs: 0), on: &detector)
        expectNoActivation(frame(x: 60, timeMs: 100), on: &detector)
        expectNoActivation(frame(x: -40, timeMs: 200), on: &detector)
        expectNoActivation(frame(x: 60, timeMs: 300), on: &detector)
        expectNoActivation(frame(x: -40, timeMs: 400), on: &detector)
        expectActivation(frame(x: 10, timeMs: 650), on: &detector)
    }

    @Test("The same movement does not activate after the time window")
    func lateShakeDoesNotActivate() {
        var detector = ShakeActivationDetector()

        expectNoActivation(frame(x: 0, timeMs: 0), on: &detector)
        expectNoActivation(frame(x: 60, timeMs: 100), on: &detector)
        expectNoActivation(frame(x: -40, timeMs: 200), on: &detector)
        expectNoActivation(frame(x: 60, timeMs: 300), on: &detector)
        expectNoActivation(frame(x: -40, timeMs: 400), on: &detector)
        expectNoActivation(frame(x: 10, timeMs: 651), on: &detector)
    }

    @Test("Long one-way travel is not a shake")
    func oneWayTravelDoesNotActivate() {
        var detector = ShakeActivationDetector()

        for (index, x) in [0.0, 50, 100, 150, 200, 250].enumerated() {
            expectNoActivation(
                frame(x: x, timeMs: UInt64(index * 80)),
                on: &detector
            )
        }
    }

    @Test("Alternation that ends far from its origin is rejected")
    func highNetDisplacementDoesNotActivate() {
        var detector = ShakeActivationDetector()
        let samples: [(UInt64, Double)] = [
            (0, 0),
            (100, 80),
            (200, -20),
            (300, 80),
            (400, -20),
            (500, 80),
        ]

        for (time, x) in samples {
            expectNoActivation(frame(x: x, timeMs: time), on: &detector)
        }
    }

    @Test("Off-axis looping does not count as deliberate alternation")
    func loopDoesNotActivate() {
        var detector = ShakeActivationDetector()
        let samples: [(UInt64, Double, Double)] = [
            (0, 0, 0),
            (80, 60, 0),
            (160, 60, 60),
            (240, 0, 60),
            (320, 0, 0),
            (400, 60, 0),
            (480, 60, 60),
            (560, 0, 60),
            (640, 0, 0),
        ]

        for (time, x, y) in samples {
            expectNoActivation(frame(x: x, y: y, timeMs: time), on: &detector)
        }
    }

    @Test("A pressed button cancels the candidate")
    func buttonDownCancelsCandidate() {
        var detector = ShakeActivationDetector()

        expectNoActivation(frame(x: 0, timeMs: 0), on: &detector)
        expectNoActivation(frame(x: 60, timeMs: 100), on: &detector)
        expectNoActivation(frame(x: -40, timeMs: 200), on: &detector)
        expectNoActivation(frame(x: 60, timeMs: 300), on: &detector)
        expectNoActivation(frame(x: -40, timeMs: 400), on: &detector)
        expectNoActivation(
            frame(x: 10, timeMs: 500, buttons: .primary),
            on: &detector
        )
        expectNoActivation(frame(x: 60, timeMs: 550), on: &detector)
    }

    @Test("Dragging cancels the candidate even if the button mask is empty")
    func draggingCancelsCandidate() {
        var detector = ShakeActivationDetector()

        expectNoActivation(frame(x: 0, timeMs: 0), on: &detector)
        expectNoActivation(frame(x: 60, timeMs: 100), on: &detector)
        expectNoActivation(frame(x: -40, timeMs: 200), on: &detector)
        expectNoActivation(frame(x: 60, timeMs: 300), on: &detector)
        expectNoActivation(frame(x: -40, timeMs: 400), on: &detector)
        expectNoActivation(
            frame(x: 10, timeMs: 500, kind: .dragged),
            on: &detector
        )
        expectNoActivation(frame(x: 60, timeMs: 550), on: &detector)
    }

    @Test("Cooldown suppresses another shake until its deadline")
    func cooldownSuppressesRepeatedActivation() {
        var detector = ShakeActivationDetector()

        let firstActivation = performShake(on: &detector, startingAtMs: 0)
        #expect(firstActivation)
        let duringCooldown = performShake(on: &detector, startingAtMs: 600)
        #expect(!duringCooldown)
        let afterCooldown = performShake(on: &detector, startingAtMs: 1_700)
        #expect(afterCooldown)
    }

    @Test("Reset clears partial movement and cooldown")
    func resetRestoresPristineState() {
        var detector = ShakeActivationDetector()

        let firstActivation = performShake(on: &detector, startingAtMs: 0)
        #expect(firstActivation)
        detector.reset()
        let activationAfterReset = performShake(on: &detector, startingAtMs: 600)
        #expect(activationAfterReset)

        detector.reset()
        expectNoActivation(frame(x: 0, timeMs: 1_200), on: &detector)
        expectNoActivation(frame(x: 60, timeMs: 1_300), on: &detector)
        expectNoActivation(frame(x: -40, timeMs: 1_400), on: &detector)
        detector.reset()
        expectNoActivation(frame(x: 60, timeMs: 1_500), on: &detector)
        expectNoActivation(frame(x: -40, timeMs: 1_600), on: &detector)
        expectNoActivation(frame(x: 10, timeMs: 1_700), on: &detector)
    }

    private func performShake(
        on detector: inout ShakeActivationDetector,
        startingAtMs start: UInt64
    ) -> Bool {
        let samples: [(UInt64, Double)] = [
            (0, 0),
            (100, 60),
            (200, -40),
            (300, 60),
            (400, -40),
            (500, 10),
        ]
        var activated = false
        for (offset, x) in samples {
            let sampleActivated = detector.observe(
                frame(x: x, timeMs: start + offset)
            )
            activated = sampleActivated || activated
        }
        return activated
    }

    private func expectNoActivation(
        _ frame: PointerFrame,
        on detector: inout ShakeActivationDetector
    ) {
        let activated = detector.observe(frame)
        #expect(!activated)
    }

    private func expectActivation(
        _ frame: PointerFrame,
        on detector: inout ShakeActivationDetector
    ) {
        let activated = detector.observe(frame)
        #expect(activated)
    }

    private func frame(
        x: Double,
        y: Double = 0,
        timeMs: UInt64,
        kind: PointerEventKind = .moved,
        buttons: PointerButtonMask = []
    ) -> PointerFrame {
        let timestampNs = timeMs * millisecond
        let point = GlobalPoint(x: x, y: y)
        return PointerFrame(
            generation: timeMs,
            sequence: timeMs,
            eventTimestampNs: timestampNs,
            observedTimestampNs: timestampNs,
            publishedTimestampNs: timestampNs,
            coordinates: PointerCoordinates(
                quartzGlobal: point,
                appKitGlobal: point
            ),
            kind: kind,
            buttons: buttons,
            modifiers: []
        )
    }
}

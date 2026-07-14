import PointerCore
import Testing

@Suite("Ordered pointer input batch")
struct PointerInputBatchTests {
    private let millisecond: UInt64 = 1_000_000

    @Test("A same-sequence button transition precedes its mailbox frame")
    func sameSequenceButtonPrecedesFrame() {
        let frame = frame(sequence: 20, x: 10, timeMs: 20, kind: .button)
        let button = discrete(sequence: 20, kind: .buttonDown)
        let batch = PointerInputBatch(frame: frame, discreteEvents: [button])
        var observed: [String] = []

        batch.forEachOrdered { input in
            switch input {
            case .frame: observed.append("frame")
            case .discrete: observed.append("button")
            }
        }

        #expect(observed == ["button", "frame"])
    }

    @Test("A coalesced click disarms a partial shake before later motion")
    func coalescedClickDisarmsShake() {
        var detector = seededDetector()
        let batch = PointerInputBatch(
            frame: frame(sequence: 8, x: 10, timeMs: 500),
            discreteEvents: [
                discrete(sequence: 6, kind: .buttonDown),
                discrete(sequence: 7, kind: .buttonUp),
            ]
        )
        var activated = false

        batch.forEachOrdered { input in
            switch input {
            case let .frame(frame):
                activated = detector.observe(frame) || activated
            case .discrete:
                detector.reset()
            }
        }

        #expect(!activated)
    }

    @Test("Right Option after the final shake frame pins; before it disarms")
    func optionOrderingControlsClutch() {
        var validDetector = seededDetector()
        var validState: PointerClutchState = .idle
        let finalFrame = frame(sequence: 6, x: 10, timeMs: 500)
        let optionAfter = discrete(sequence: 7, kind: .rightOptionDown)

        PointerInputBatch(frame: finalFrame, discreteEvents: [optionAfter])
            .forEachOrdered { input in
                apply(input, detector: &validDetector, state: &validState)
            }

        guard case .pinning = validState else {
            Issue.record("Expected final shake frame followed by Right Option to pin")
            return
        }

        var reversedDetector = seededDetector()
        var reversedState: PointerClutchState = .idle
        let optionBefore = discrete(sequence: 5, kind: .rightOptionDown)
        PointerInputBatch(frame: finalFrame, discreteEvents: [optionBefore])
            .forEachOrdered { input in
                apply(input, detector: &reversedDetector, state: &reversedState)
            }

        #expect(reversedState == .idle)
    }

    private func apply(
        _ input: PointerInputEvent,
        detector: inout ShakeActivationDetector,
        state: inout PointerClutchState
    ) {
        switch input {
        case let .frame(frame):
            if detector.observe(frame) {
                let lease = PointerClutchLease(
                    generation: frame.generation,
                    expiresAtNs: frame.observedTimestampNs + 20_000_000_000
                )
                state = PointerClutchReducer.reduce(
                    state: state,
                    event: .beginFollowing(lease: lease, nowNs: frame.observedTimestampNs)
                )
            }
        case let .discrete(event):
            detector.reset()
            if event.kind == .rightOptionDown {
                state = PointerClutchReducer.reduce(
                    state: state,
                    event: .optionDown(nowNs: event.observedTimestampNs)
                )
            }
        }
    }

    private func seededDetector() -> ShakeActivationDetector {
        var detector = ShakeActivationDetector()
        let positions = [0.0, 60, -40, 60, -40]
        for (index, x) in positions.enumerated() {
            let activated = detector.observe(
                frame(
                    sequence: UInt64(index + 1),
                    x: x,
                    timeMs: UInt64(index * 100)
                )
            )
            #expect(!activated)
        }
        return detector
    }

    private func frame(
        sequence: UInt64,
        x: Double,
        timeMs: UInt64,
        kind: PointerEventKind = .moved
    ) -> PointerFrame {
        let timestampNs = timeMs * millisecond
        let point = GlobalPoint(x: x, y: 0)
        return PointerFrame(
            generation: sequence,
            sequence: sequence,
            eventTimestampNs: timestampNs,
            observedTimestampNs: timestampNs,
            publishedTimestampNs: timestampNs,
            coordinates: PointerCoordinates(quartzGlobal: point, appKitGlobal: point),
            kind: kind,
            buttons: [],
            modifiers: []
        )
    }

    private func discrete(
        sequence: UInt64,
        kind: PointerDiscreteKind
    ) -> PointerDiscreteEvent {
        PointerDiscreteEvent(
            sequence: sequence,
            eventTimestampNs: sequence * millisecond,
            observedTimestampNs: sequence * millisecond,
            point: GlobalPoint(x: 0, y: 0),
            kind: kind,
            button: kind == .buttonDown || kind == .buttonUp ? .primary : nil,
            buttons: kind == .buttonDown ? .primary : [],
            modifiers: []
        )
    }
}

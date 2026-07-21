import PointerCore
import PointerTransport
import Testing

@Suite("Pointer transport")
struct TransportTests {
    @Test("Motion is latest-value, not an unbounded queue")
    func latestMotionWins() {
        let mailbox = MotionMailbox()
        for sequence in 1...100_000 {
            mailbox.write(sample(UInt64(sequence)))
        }

        let update = mailbox.read(afterVersion: 0)
        #expect(update?.sample.sequence == 100_000)
        #expect(mailbox.read(afterVersion: update?.version ?? 0) == nil)
    }

    @Test("Discrete transitions remain ordered")
    func discreteOrder() {
        let ring = DiscreteRing()
        for sequence in 1...128 {
            #expect(ring.push(discrete(UInt64(sequence))))
        }
        #expect(!ring.push(discrete(129)))
        let drained = ring.drain()
        #expect(drained.map(\.sequence) == Array(1...128).map(UInt64.init))
    }

    @Test("Right Option clutch transitions survive the ordered lane")
    func rightOptionOrder() throws {
        let ring = DiscreteRing()
        let down = PointerDiscreteEvent(
            sequence: 1,
            eventTimestampNs: 1,
            observedTimestampNs: 1,
            point: GlobalPoint(x: 40, y: 50),
            kind: .rightOptionDown,
            button: nil,
            buttons: [],
            modifiers: []
        )
        var up = down
        up.sequence = 2
        up.kind = .rightOptionUp

        #expect(ring.push(down))
        #expect(ring.push(up))
        let drained = ring.drain()
        #expect(drained.map(\.kind) == [.rightOptionDown, .rightOptionUp])
    }

    @Test("Right Command shelf transitions survive the ordered lane")
    func rightCommandOrder() {
        let ring = DiscreteRing()
        let down = PointerDiscreteEvent(
            sequence: 1,
            eventTimestampNs: 1,
            observedTimestampNs: 1,
            point: GlobalPoint(x: 40, y: 50),
            kind: .rightCommandDown,
            button: nil,
            buttons: [],
            modifiers: []
        )
        var up = down
        up.sequence = 2
        up.kind = .rightCommandUp

        #expect(ring.push(down))
        #expect(ring.push(up))
        #expect(ring.drain().map(\.kind) == [.rightCommandDown, .rightCommandUp])
    }

    private func sample(_ sequence: UInt64) -> TransportMotionSample {
        TransportMotionSample(
            sequence: sequence,
            eventTimestampNs: sequence,
            observedTimestampNs: sequence,
            coordinates: PointerCoordinates(
                quartzGlobal: GlobalPoint(x: Double(sequence), y: 0),
                appKitGlobal: GlobalPoint(x: Double(sequence), y: 0)
            ),
            flags: 0,
            buttons: 0,
            kind: .moved
        )
    }

    private func discrete(_ sequence: UInt64) -> PointerDiscreteEvent {
        PointerDiscreteEvent(
            sequence: sequence,
            eventTimestampNs: sequence,
            observedTimestampNs: sequence,
            point: GlobalPoint(x: 0, y: 0),
            kind: .buttonDown,
            button: .primary,
            buttons: .primary,
            modifiers: []
        )
    }
}

import PointerCore
import Testing

@Suite("Settled-pointer policy")
struct SettledPointerPolicyTests {
    @Test("It does not resolve before the dwell threshold")
    func waitsForDwell() {
        var state = SettledPointerPolicyState()
        let policy = SemanticPolicy.settled(
            delayNs: 80,
            radius: 4,
            minimumIntervalNs: 80
        )

        #expect(state.requestIfReady(
            frame: frame(sequence: 1, time: 100, x: 10),
            policy: policy,
            cachedTargetFrame: nil,
            cachedAtNs: nil,
            cacheLifetimeNs: 80
        ) == nil)
        #expect(state.requestIfReady(
            frame: frame(sequence: 2, time: 179, x: 12),
            policy: policy,
            cachedTargetFrame: nil,
            cachedAtNs: nil,
            cacheLifetimeNs: 80
        ) == nil)

        let request = state.requestIfReady(
            frame: frame(sequence: 3, time: 180, x: 12),
            policy: policy,
            cachedTargetFrame: nil,
            cachedAtNs: nil,
            cacheLifetimeNs: 80
        )
        #expect(request?.generation == 3)
    }

    @Test("Meaningful movement resets dwell")
    func movementResetsDwell() {
        var state = SettledPointerPolicyState()
        let policy = SemanticPolicy.settled(
            delayNs: 80,
            radius: 4,
            minimumIntervalNs: 80
        )
        _ = state.requestIfReady(
            frame: frame(sequence: 1, time: 100, x: 10),
            policy: policy,
            cachedTargetFrame: nil,
            cachedAtNs: nil,
            cacheLifetimeNs: 80
        )
        #expect(state.requestIfReady(
            frame: frame(sequence: 2, time: 180, x: 30),
            policy: policy,
            cachedTargetFrame: nil,
            cachedAtNs: nil,
            cacheLifetimeNs: 80
        ) == nil)
        #expect(state.requestIfReady(
            frame: frame(sequence: 3, time: 259, x: 30),
            policy: policy,
            cachedTargetFrame: nil,
            cachedAtNs: nil,
            cacheLifetimeNs: 80
        ) == nil)
        #expect(state.requestIfReady(
            frame: frame(sequence: 4, time: 260, x: 30),
            policy: policy,
            cachedTargetFrame: nil,
            cachedAtNs: nil,
            cacheLifetimeNs: 80
        ) != nil)
    }

    @Test("A fresh cached frame suppresses redundant AX work")
    func cacheSuppressesResolution() {
        var state = SettledPointerPolicyState()
        let policy = SemanticPolicy.settled(
            delayNs: 0,
            radius: 4,
            minimumIntervalNs: 0
        )
        let cachedFrame = GlobalRect(x: 0, y: 0, width: 100, height: 100)
        #expect(state.requestIfReady(
            frame: frame(sequence: 1, time: 150, x: 10),
            policy: policy,
            cachedTargetFrame: cachedFrame,
            cachedAtNs: 100,
            cacheLifetimeNs: 80
        ) == nil)
    }

    private func frame(sequence: UInt64, time: UInt64, x: Double) -> PointerFrame {
        PointerFrame(
            generation: sequence,
            sequence: sequence,
            eventTimestampNs: time,
            observedTimestampNs: time,
            publishedTimestampNs: time,
            coordinates: PointerCoordinates(
                quartzGlobal: GlobalPoint(x: x, y: 10),
                appKitGlobal: GlobalPoint(x: x, y: 10)
            ),
            kind: .moved,
            buttons: [],
            modifiers: []
        )
    }
}

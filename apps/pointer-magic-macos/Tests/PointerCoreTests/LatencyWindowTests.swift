import PointerCore
import Testing

@Suite("Fixed latency window")
struct LatencyWindowTests {
    @Test("It remains bounded and reports tail latency")
    func boundedWindow() {
        var window = LatencyWindow(capacity: 4)
        for value: UInt64 in [10, 20, 30, 40, 50] {
            window.record(value)
        }
        let summary = window.summary()
        #expect(summary.sampleCount == 4)
        #expect(summary.maximumNs == 50)
        #expect(summary.p95Ns == 50)
    }
}

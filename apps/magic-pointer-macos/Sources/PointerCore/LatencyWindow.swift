import Foundation

public struct LatencyWindow: Sendable {
    private var samples: [UInt64]
    private var nextIndex = 0
    private var storedCount = 0

    public init(capacity: Int = 512) {
        precondition(capacity > 0)
        samples = Array(repeating: 0, count: capacity)
    }

    public mutating func record(_ value: UInt64) {
        samples[nextIndex] = value
        nextIndex = (nextIndex + 1) % samples.count
        storedCount = min(storedCount + 1, samples.count)
    }

    public func summary() -> LatencySummary {
        guard storedCount > 0 else { return LatencySummary() }

        let ordered = samples.prefix(storedCount).sorted()
        func percentile(_ fraction: Double) -> UInt64 {
            let rawIndex = Int((Double(ordered.count - 1) * fraction).rounded(.up))
            return ordered[min(max(rawIndex, 0), ordered.count - 1)]
        }

        return LatencySummary(
            sampleCount: storedCount,
            medianNs: percentile(0.5),
            p95Ns: percentile(0.95),
            p99Ns: percentile(0.99),
            maximumNs: ordered.last ?? 0
        )
    }
}

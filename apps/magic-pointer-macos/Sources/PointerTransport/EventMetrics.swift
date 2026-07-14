import PointerC
import PointerCore

public final class EventMetrics: @unchecked Sendable {
    private let handle: OpaquePointer

    public init() {
        guard let handle = mp_event_metrics_create() else {
            fatalError("Unable to allocate pointer event metrics")
        }
        self.handle = handle
    }

    deinit {
        mp_event_metrics_destroy(handle)
    }

    public func recordCallback(durationNs: UInt64) {
        mp_event_metrics_record_callback(handle, durationNs)
    }

    public func recordTapDisabledByTimeout() {
        mp_event_metrics_record_tap_disabled_timeout(handle)
    }

    public func recordTapDisabledByUserInput() {
        mp_event_metrics_record_tap_disabled_user(handle)
    }

    public func recordDiscreteOverflow() {
        mp_event_metrics_record_discrete_overflow(handle)
    }

    public func snapshot() -> EventTapMetrics {
        var raw = mp_event_metrics_snapshot_t()
        mp_event_metrics_snapshot(handle, &raw)

        let bucketCounts: [UInt64] = withUnsafeBytes(of: &raw.callback_buckets) { bytes in
            Array(bytes.bindMemory(to: UInt64.self))
        }
        let bucketUpperBounds: [UInt64] = [
            50_000,
            100_000,
            250_000,
            500_000,
            1_000_000,
            2_000_000,
            5_000_000,
            UInt64.max,
        ]

        let p99Target = raw.callback_count == 0
            ? 0
            : max(UInt64(1), (raw.callback_count * 99 + 99) / 100)
        var cumulative: UInt64 = 0
        var p99UpperBound: UInt64 = 0
        if p99Target > 0 {
            for (index, count) in bucketCounts.enumerated() {
                cumulative += count
                if cumulative >= p99Target {
                    p99UpperBound = bucketUpperBounds[index]
                    break
                }
            }
        }

        return EventTapMetrics(
            callbackCount: raw.callback_count,
            callbackAverageNs: raw.callback_count == 0
                ? 0
                : raw.callback_total_ns / raw.callback_count,
            callbackMaximumNs: raw.callback_max_ns,
            callbackP99UpperBoundNs: p99UpperBound,
            tapDisabledCount: raw.tap_disabled_timeout_count + raw.tap_disabled_user_count,
            discreteOverflowCount: raw.discrete_overflow_count
        )
    }
}

import PointerC

public enum MonotonicClock {
    public static func nowNs() -> UInt64 {
        mp_monotonic_time_ns()
    }
}

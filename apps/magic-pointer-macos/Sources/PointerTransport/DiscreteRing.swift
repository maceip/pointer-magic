import PointerC
import PointerCore

public final class DiscreteRing: @unchecked Sendable {
    private let handle: OpaquePointer

    public init() {
        guard let handle = mp_discrete_ring_create() else {
            fatalError("Unable to allocate the pointer discrete-event ring")
        }
        self.handle = handle
    }

    deinit {
        mp_discrete_ring_destroy(handle)
    }

    @discardableResult
    public func push(_ event: PointerDiscreteEvent) -> Bool {
        // Preserve capacity for button transitions. For the bedrock, scroll is a cache-
        // invalidation signal rather than a lossless gesture trace, so excess scroll events
        // may be coalesced while down/up ordering remains protected.
        if event.kind == .scroll, count >= 96 {
            return true
        }
        var raw = mp_discrete_event_t()
        raw.sequence = event.sequence
        raw.event_time_ns = event.eventTimestampNs
        raw.observed_time_ns = event.observedTimestampNs
        raw.quartz_x = event.point.x
        raw.quartz_y = event.point.y
        raw.delta_x = event.scrollDelta.x
        raw.delta_y = event.scrollDelta.y
        raw.flags = event.modifiers.rawValue
        raw.buttons = event.buttons.rawValue
        raw.event_kind = event.kind.rawValue
        raw.button = event.button?.rawValue ?? UInt8.max
        raw.click_count = UInt8(clamping: event.clickCount)
        return mp_discrete_ring_push(handle, &raw)
    }

    public func drain(limit: Int = 128) -> [PointerDiscreteEvent] {
        guard limit > 0 else { return [] }
        var events: [PointerDiscreteEvent] = []
        events.reserveCapacity(min(limit, Int(mp_discrete_ring_count(handle))))

        var raw = mp_discrete_event_t()
        while events.count < limit, mp_discrete_ring_pop(handle, &raw) {
            guard let kind = PointerDiscreteKind(rawValue: raw.event_kind) else {
                continue
            }
            let button = raw.button == UInt8.max ? nil : PointerButton(rawValue: raw.button)
            events.append(
                PointerDiscreteEvent(
                    sequence: raw.sequence,
                    eventTimestampNs: raw.event_time_ns,
                    observedTimestampNs: raw.observed_time_ns,
                    point: GlobalPoint(x: raw.quartz_x, y: raw.quartz_y),
                    kind: kind,
                    button: button,
                    buttons: PointerButtonMask(rawValue: raw.buttons),
                    modifiers: PointerModifierFlags(rawValue: raw.flags),
                    clickCount: Int(raw.click_count),
                    scrollDelta: GlobalPoint(x: raw.delta_x, y: raw.delta_y)
                )
            )
        }
        return events
    }

    public var count: Int {
        Int(mp_discrete_ring_count(handle))
    }

    public var overflowEpoch: UInt64 {
        mp_discrete_ring_overflow_epoch(handle)
    }

    /// Call only after the producer has stopped and the consumer is quiescent.
    public func reset() {
        mp_discrete_ring_reset(handle)
    }
}

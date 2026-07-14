import PointerC
import PointerCore

public struct TransportMotionSample: Sendable {
    public var sequence: UInt64
    public var eventTimestampNs: UInt64
    public var observedTimestampNs: UInt64
    public var coordinates: PointerCoordinates
    public var flags: UInt64
    public var buttons: UInt32
    public var kind: PointerEventKind

    public init(
        sequence: UInt64,
        eventTimestampNs: UInt64,
        observedTimestampNs: UInt64,
        coordinates: PointerCoordinates,
        flags: UInt64,
        buttons: UInt32,
        kind: PointerEventKind
    ) {
        self.sequence = sequence
        self.eventTimestampNs = eventTimestampNs
        self.observedTimestampNs = observedTimestampNs
        self.coordinates = coordinates
        self.flags = flags
        self.buttons = buttons
        self.kind = kind
    }
}

public final class MotionMailbox: @unchecked Sendable {
    private let handle: OpaquePointer

    public init() {
        guard let handle = mp_motion_mailbox_create() else {
            fatalError("Unable to allocate the pointer motion mailbox")
        }
        self.handle = handle
    }

    deinit {
        mp_motion_mailbox_destroy(handle)
    }

    public func write(_ sample: TransportMotionSample) {
        var raw = mp_motion_sample_t()
        raw.sequence = sample.sequence
        raw.event_time_ns = sample.eventTimestampNs
        raw.observed_time_ns = sample.observedTimestampNs
        raw.quartz_x = sample.coordinates.quartzGlobal.x
        raw.quartz_y = sample.coordinates.quartzGlobal.y
        raw.appkit_x = sample.coordinates.appKitGlobal.x
        raw.appkit_y = sample.coordinates.appKitGlobal.y
        raw.flags = sample.flags
        raw.buttons = sample.buttons
        raw.event_kind = sample.kind.rawValue
        mp_motion_mailbox_write(handle, &raw)
    }

    /// Call only after the single producer has stopped.
    public func reset() {
        mp_motion_mailbox_reset(handle)
    }

    public func read(afterVersion: UInt64) -> (version: UInt64, sample: TransportMotionSample)? {
        var version: UInt64 = 0
        var raw = mp_motion_sample_t()
        guard mp_motion_mailbox_read(handle, afterVersion, &version, &raw) else {
            return nil
        }

        guard let kind = PointerEventKind(rawValue: raw.event_kind) else {
            return nil
        }

        return (
            version,
            TransportMotionSample(
                sequence: raw.sequence,
                eventTimestampNs: raw.event_time_ns,
                observedTimestampNs: raw.observed_time_ns,
                coordinates: PointerCoordinates(
                    quartzGlobal: GlobalPoint(x: raw.quartz_x, y: raw.quartz_y),
                    appKitGlobal: GlobalPoint(x: raw.appkit_x, y: raw.appkit_y)
                ),
                flags: raw.flags,
                buttons: raw.buttons,
                kind: kind
            )
        )
    }
}

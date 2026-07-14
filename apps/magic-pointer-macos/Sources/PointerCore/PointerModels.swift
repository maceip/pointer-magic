import Foundation

public enum PointerEventKind: UInt8, Codable, Sendable {
    case moved = 1
    case dragged = 2
    case button = 3
    case fallback = 4
}

public enum PointerButton: UInt8, Codable, Sendable {
    case primary = 0
    case secondary = 1
    case middle = 2
    case other = 3
}

public struct PointerButtonMask: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let primary = PointerButtonMask(rawValue: 1 << 0)
    public static let secondary = PointerButtonMask(rawValue: 1 << 1)
    public static let middle = PointerButtonMask(rawValue: 1 << 2)
    public static let other = PointerButtonMask(rawValue: 1 << 3)
}

public struct PointerModifierFlags: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

public struct PointerFrame: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var generation: UInt64
    public var sequence: UInt64
    public var eventTimestampNs: UInt64
    public var observedTimestampNs: UInt64
    public var publishedTimestampNs: UInt64
    public var coordinates: PointerCoordinates
    public var kind: PointerEventKind
    public var buttons: PointerButtonMask
    public var modifiers: PointerModifierFlags

    public init(
        schemaVersion: Int = currentSchemaVersion,
        generation: UInt64,
        sequence: UInt64,
        eventTimestampNs: UInt64,
        observedTimestampNs: UInt64,
        publishedTimestampNs: UInt64,
        coordinates: PointerCoordinates,
        kind: PointerEventKind,
        buttons: PointerButtonMask,
        modifiers: PointerModifierFlags
    ) {
        self.schemaVersion = schemaVersion
        self.generation = generation
        self.sequence = sequence
        self.eventTimestampNs = eventTimestampNs
        self.observedTimestampNs = observedTimestampNs
        self.publishedTimestampNs = publishedTimestampNs
        self.coordinates = coordinates
        self.kind = kind
        self.buttons = buttons
        self.modifiers = modifiers
    }
}

public enum PointerDiscreteKind: UInt8, Codable, Sendable {
    case buttonDown = 1
    case buttonUp = 2
    case scroll = 3
    /// The fixed ring overflowed. Consumers must cancel any in-progress gesture and
    /// rebuild button state from subsequent frames instead of guessing.
    case resynchronize = 4
    /// The physical Right Option key changed while the passive clutch feature was enabled.
    /// No other key identity or text is retained by the pointer foundation.
    case rightOptionDown = 5
    case rightOptionUp = 6
}

public struct PointerDiscreteEvent: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var sequence: UInt64
    public var eventTimestampNs: UInt64
    public var observedTimestampNs: UInt64
    public var point: GlobalPoint
    public var kind: PointerDiscreteKind
    public var button: PointerButton?
    public var buttons: PointerButtonMask
    public var modifiers: PointerModifierFlags
    public var clickCount: Int
    public var scrollDelta: GlobalPoint

    public init(
        schemaVersion: Int = currentSchemaVersion,
        sequence: UInt64,
        eventTimestampNs: UInt64,
        observedTimestampNs: UInt64,
        point: GlobalPoint,
        kind: PointerDiscreteKind,
        button: PointerButton?,
        buttons: PointerButtonMask,
        modifiers: PointerModifierFlags,
        clickCount: Int = 0,
        scrollDelta: GlobalPoint = .init(x: 0, y: 0)
    ) {
        self.schemaVersion = schemaVersion
        self.sequence = sequence
        self.eventTimestampNs = eventTimestampNs
        self.observedTimestampNs = observedTimestampNs
        self.point = point
        self.kind = kind
        self.button = button
        self.buttons = buttons
        self.modifiers = modifiers
        self.clickCount = clickCount
        self.scrollDelta = scrollDelta
    }
}

/// One item from the lossless, serial interaction lane.
///
/// Display-cadence motion and ordered discrete transitions remain available as
/// independent streams for observers. Gesture owners use this lane when relative
/// ordering matters, such as a click interrupting a shake or Right Option following
/// the final shake frame.
public enum PointerInputEvent: Codable, Hashable, Sendable {
    case frame(PointerFrame)
    case discrete(PointerDiscreteEvent)

    public var sequence: UInt64 {
        switch self {
        case let .frame(frame): frame.sequence
        case let .discrete(event): event.sequence
        }
    }
}

/// The transport snapshot consumed during one display-link turn.
///
/// Discrete events are already ordered by the event-tap sequence. Iteration inserts
/// the coalesced motion frame at its exact sequence boundary; an event sharing the
/// frame's sequence is emitted first because button transitions are written before
/// their `.button` mailbox sample.
public enum PointerInputResynchronization: String, Codable, Hashable, Sendable {
    case none
    /// Input before this batch was dropped by a bounded feature-side queue.
    case beforeBatch
    /// The fixed transport ring was drained in quarantine after a loss. Discrete input
    /// is discarded and the carried frame only reconciles state; it is not a gesture.
    case transportRecovery
}

public struct PointerInputBatch: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var frame: PointerFrame?
    public var discreteEvents: [PointerDiscreteEvent]
    public var resynchronization: PointerInputResynchronization

    public init(
        schemaVersion: Int = currentSchemaVersion,
        frame: PointerFrame?,
        discreteEvents: [PointerDiscreteEvent],
        resynchronization: PointerInputResynchronization = .none
    ) {
        self.schemaVersion = schemaVersion
        self.frame = frame
        self.discreteEvents = discreteEvents
        self.resynchronization = resynchronization
    }

    public func forEachOrdered(_ body: (PointerInputEvent) -> Void) {
        // Resynchronization marks a boundary around, not an item within, this known
        // sequence. The bedrock applies `resynchronization` at the declared side.
        guard let frame else {
            for event in discreteEvents {
                body(.discrete(event))
            }
            return
        }

        var emittedFrame = false
        for event in discreteEvents {
            if !emittedFrame, event.sequence > frame.sequence {
                body(.frame(frame))
                emittedFrame = true
            }
            body(.discrete(event))
        }
        if !emittedFrame {
            body(.frame(frame))
        }
    }
}

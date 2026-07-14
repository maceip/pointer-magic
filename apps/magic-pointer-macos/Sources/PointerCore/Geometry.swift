import Foundation

public struct GlobalPoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public func distanceSquared(to other: GlobalPoint) -> Double {
        let dx = x - other.x
        let dy = y - other.y
        return (dx * dx) + (dy * dy)
    }
}

public struct GlobalSize: Codable, Hashable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct GlobalRect: Codable, Hashable, Sendable {
    public var origin: GlobalPoint
    public var size: GlobalSize

    public init(origin: GlobalPoint, size: GlobalSize) {
        self.origin = origin
        self.size = size
    }

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.init(
            origin: GlobalPoint(x: x, y: y),
            size: GlobalSize(width: width, height: height)
        )
    }

    public var minX: Double { origin.x }
    public var minY: Double { origin.y }
    public var maxX: Double { origin.x + size.width }
    public var maxY: Double { origin.y + size.height }

    public func contains(_ point: GlobalPoint, inset: Double = 0) -> Bool {
        point.x >= minX - inset &&
            point.x <= maxX + inset &&
            point.y >= minY - inset &&
            point.y <= maxY + inset
    }
}

public struct PointerCoordinates: Codable, Hashable, Sendable {
    /// Top-left-relative Quartz global coordinates. Use this space for AX hit testing.
    public var quartzGlobal: GlobalPoint

    /// Lower-left-relative AppKit global coordinates. Use this space for windows and screens.
    public var appKitGlobal: GlobalPoint

    public init(quartzGlobal: GlobalPoint, appKitGlobal: GlobalPoint) {
        self.quartzGlobal = quartzGlobal
        self.appKitGlobal = appKitGlobal
    }
}

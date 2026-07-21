import Foundation

public struct ScenePoint: Codable, Hashable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) throws {
        guard x.isFinite, y.isFinite else {
            throw SceneContractValidationError.nonFinite(field: "point")
        }
        self.x = x
        self.y = y
    }

    private enum CodingKeys: CodingKey { case x, y }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            x: container.decode(Double.self, forKey: .x),
            y: container.decode(Double.self, forKey: .y)
        )
    }
}

public struct SceneSize: Codable, Hashable, Sendable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) throws {
        guard width.isFinite, height.isFinite else {
            throw SceneContractValidationError.nonFinite(field: "size")
        }
        guard width > 0, height > 0 else {
            throw SceneContractValidationError.invalidRange(field: "size")
        }
        self.width = width
        self.height = height
    }

    private enum CodingKeys: CodingKey { case width, height }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            width: container.decode(Double.self, forKey: .width),
            height: container.decode(Double.self, forKey: .height)
        )
    }
}

public struct SceneRect: Codable, Hashable, Sendable {
    public let origin: ScenePoint
    public let size: SceneSize

    public init(origin: ScenePoint, size: SceneSize) {
        self.origin = origin
        self.size = size
    }

    public init(x: Double, y: Double, width: Double, height: Double) throws {
        self.origin = try ScenePoint(x: x, y: y)
        self.size = try SceneSize(width: width, height: height)
    }
}

public struct SurfaceRegion: Codable, Hashable, Sendable {
    public let coordinateSpace: SurfaceCoordinateSpace
    public let rect: SceneRect

    public init(coordinateSpace: SurfaceCoordinateSpace, rect: SceneRect) {
        self.coordinateSpace = coordinateSpace
        self.rect = rect
    }
}

public enum SceneCoordinateUnit: String, Codable, Hashable, Sendable {
    case logicalPoints
    case physicalPixels
    case normalized
}

public enum SceneCoordinateOrigin: String, Codable, Hashable, Sendable {
    case topLeft
    case bottomLeft
}

public struct CoordinateSpaceDescriptor: Codable, Hashable, Sendable {
    public let coordinateSpace: SurfaceCoordinateSpace
    public let unit: SceneCoordinateUnit
    public let origin: SceneCoordinateOrigin
    public let extent: SceneSize
    /// Clockwise rotation from the surface's natural orientation, in quarter turns.
    public let rotationQuarterTurns: UInt8
    /// Logical-to-physical scale. It is descriptive; regions remain in `unit` above.
    public let scaleFactor: Double

    public init(
        coordinateSpace: SurfaceCoordinateSpace,
        unit: SceneCoordinateUnit,
        origin: SceneCoordinateOrigin,
        extent: SceneSize,
        rotationQuarterTurns: UInt8 = 0,
        scaleFactor: Double = 1
    ) throws {
        guard rotationQuarterTurns <= 3 else {
            throw SceneContractValidationError.invalidRange(
                field: "coordinateSpace.rotationQuarterTurns"
            )
        }
        guard scaleFactor.isFinite, scaleFactor > 0 else {
            throw SceneContractValidationError.invalidRange(field: "coordinateSpace.scaleFactor")
        }
        self.coordinateSpace = coordinateSpace
        self.unit = unit
        self.origin = origin
        self.extent = extent
        self.rotationQuarterTurns = rotationQuarterTurns
        self.scaleFactor = scaleFactor
    }

    private enum CodingKeys: CodingKey {
        case coordinateSpace, unit, origin, extent, rotationQuarterTurns, scaleFactor
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            coordinateSpace: container.decode(
                SurfaceCoordinateSpace.self,
                forKey: .coordinateSpace
            ),
            unit: container.decode(SceneCoordinateUnit.self, forKey: .unit),
            origin: container.decode(SceneCoordinateOrigin.self, forKey: .origin),
            extent: container.decode(SceneSize.self, forKey: .extent),
            rotationQuarterTurns: container.decode(
                UInt8.self,
                forKey: .rotationQuarterTurns
            ),
            scaleFactor: container.decode(Double.self, forKey: .scaleFactor)
        )
    }
}

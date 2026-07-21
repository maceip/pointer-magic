import Foundation

public struct OverlayColor: Codable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let cyan = OverlayColor(red: 0.22, green: 0.88, blue: 0.96)
    public static let violet = OverlayColor(red: 0.64, green: 0.43, blue: 0.98)
    public static let amber = OverlayColor(red: 1.0, green: 0.68, blue: 0.25)
}

public struct HaloItem: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var symbol: String
    public var label: String
    public var angleRadians: Double
    public var accent: OverlayColor

    public init(
        id: String,
        symbol: String,
        label: String,
        angleRadians: Double,
        accent: OverlayColor
    ) {
        self.id = id
        self.symbol = symbol
        self.label = label
        self.angleRadians = angleRadians
        self.accent = accent
    }
}

public struct OverlayScene: Codable, Hashable, Identifiable, Sendable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var id: UUID
    public var sourceID: String
    public var generation: UInt64
    public var createdAtNs: UInt64
    public var expiresAtNs: UInt64
    public var anchor: GlobalPoint
    public var targetFrame: GlobalRect?
    public var title: String?
    public var items: [HaloItem]

    public init(
        schemaVersion: Int = currentSchemaVersion,
        id: UUID = UUID(),
        sourceID: String,
        generation: UInt64,
        createdAtNs: UInt64,
        expiresAtNs: UInt64,
        anchor: GlobalPoint,
        targetFrame: GlobalRect? = nil,
        title: String? = nil,
        items: [HaloItem]
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.sourceID = sourceID
        self.generation = generation
        self.createdAtNs = createdAtNs
        self.expiresAtNs = expiresAtNs
        self.anchor = anchor
        self.targetFrame = targetFrame
        self.title = title
        self.items = items
    }

    public func validate(currentGeneration: UInt64, nowNs: UInt64) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw OverlayValidationError.unsupportedSchema
        }
        guard generation == currentGeneration else {
            throw OverlayValidationError.staleGeneration
        }
        guard expiresAtNs > nowNs, expiresAtNs > createdAtNs else {
            throw OverlayValidationError.expired
        }
        guard expiresAtNs - createdAtNs <= 30_000_000_000 else {
            throw OverlayValidationError.excessiveLifetime
        }
        guard !sourceID.isEmpty, sourceID.utf8.count <= 80 else {
            throw OverlayValidationError.invalidSource
        }
        guard items.count <= 8 else {
            throw OverlayValidationError.tooManyItems
        }
        guard title?.utf8.count ?? 0 <= 160 else {
            throw OverlayValidationError.textTooLong
        }
        for item in items {
            guard !item.id.isEmpty,
                  item.id.utf8.count <= 80,
                  item.symbol.utf8.count <= 16,
                  !item.label.isEmpty,
                  item.label.utf8.count <= 80
            else {
                throw OverlayValidationError.textTooLong
            }
        }
    }
}

public enum OverlayValidationError: Error, Equatable, Sendable {
    case unsupportedSchema
    case staleGeneration
    case expired
    case excessiveLifetime
    case invalidSource
    case tooManyItems
    case textTooLong
}

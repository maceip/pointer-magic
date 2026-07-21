import CoreGraphics
import Foundation

/// A finite point in the global Quartz desktop coordinate space.
public struct MacGlobalPoint: Hashable, Sendable {
    public let x: Double
    public let y: Double

    public init?(x: Double, y: Double) {
        guard x.isFinite, y.isFinite else { return nil }
        self.x = x
        self.y = y
    }

    public init?(_ point: CGPoint) {
        self.init(x: Double(point.x), y: Double(point.y))
    }
}

/// A finite, positive-area rectangle in the global Quartz desktop coordinate space.
/// Quartz window-list bounds use a top-left origin, matching the coordinate origin
/// exported by this discovery source.
public struct MacGlobalRect: Hashable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init?(x: Double, y: Double, width: Double, height: Double) {
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite,
              width > 0, height > 0
        else {
            return nil
        }
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init?(_ rect: CGRect) {
        self.init(
            x: Double(rect.origin.x),
            y: Double(rect.origin.y),
            width: Double(rect.width),
            height: Double(rect.height)
        )
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var area: Double { width * height }

    public func intersection(_ other: MacGlobalRect) -> MacGlobalRect? {
        let left = max(x, other.x)
        let top = max(y, other.y)
        let right = min(maxX, other.maxX)
        let bottom = min(maxY, other.maxY)
        return MacGlobalRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}

/// Raw display facts read from public CoreGraphics APIs. The parser owns validation,
/// normalization and ordering so tests do not depend on attached hardware.
public struct RawMacDisplayRecord: Hashable, Sendable {
    public let displayID: UInt32
    /// Stable physical-display UUID from the public ColorSync display API, when available.
    public let displayUUID: UUID?
    public let globalBounds: MacGlobalRect?
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let rotationDegrees: Double
    public let isMain: Bool

    public init(
        displayID: UInt32,
        displayUUID: UUID?,
        globalBounds: MacGlobalRect?,
        pixelWidth: Int,
        pixelHeight: Int,
        rotationDegrees: Double,
        isMain: Bool
    ) {
        self.displayID = displayID
        self.displayUUID = displayUUID
        self.globalBounds = globalBounds
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.rotationDegrees = rotationDegrees
        self.isMain = isMain
    }
}

public struct MacDisplaySnapshot: Hashable, Sendable {
    public let displayID: UInt32
    /// Stable physical-display UUID. Nil means the mapper must use its source-epoch
    /// namespace, never the reusable CGDirectDisplayID alone, for surface identity.
    public let displayUUID: UUID?
    public let globalBounds: MacGlobalRect
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let rotationQuarterTurns: UInt8
    public let scaleFactor: Double
    public let isMain: Bool

    public init(
        displayID: UInt32,
        displayUUID: UUID?,
        globalBounds: MacGlobalRect,
        pixelWidth: Int,
        pixelHeight: Int,
        rotationQuarterTurns: UInt8,
        scaleFactor: Double,
        isMain: Bool
    ) {
        self.displayID = displayID
        self.displayUUID = displayUUID
        self.globalBounds = globalBounds
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.rotationQuarterTurns = rotationQuarterTurns
        self.scaleFactor = scaleFactor
        self.isMain = isMain
    }
}

public struct MacApplicationSnapshot: Hashable, Sendable {
    public let processID: Int32
    public let bundleIdentifier: String?
    public let localizedName: String?
    public let isActive: Bool
    public let isHidden: Bool
    /// Public process-incarnation marker reported by NSRunningApplication.
    /// Nil means public workspace metadata cannot distinguish a PID reuse unless
    /// an intervening census observes the process absent.
    public let launchDate: Date?

    public init(
        processID: Int32,
        bundleIdentifier: String?,
        localizedName: String?,
        isActive: Bool,
        isHidden: Bool,
        launchDate: Date? = nil
    ) {
        self.processID = processID
        self.bundleIdentifier = bundleIdentifier
        self.localizedName = localizedName
        self.isActive = isActive
        self.isHidden = isHidden
        self.launchDate = launchDate
    }
}

public struct MacWindowSnapshot: Hashable, Sendable {
    public let windowID: UInt32
    public let ownerProcessID: Int32
    public let ownerName: String?
    public let globalBounds: MacGlobalRect
    public let layer: Int
    public let alpha: Double
    public let isOnScreen: Bool
    public let sharingState: UInt32?
    /// Zero is frontmost. This is the order returned by CGWindowListCopyWindowInfo.
    public let frontToBackIndex: Int

    public init(
        windowID: UInt32,
        ownerProcessID: Int32,
        ownerName: String?,
        globalBounds: MacGlobalRect,
        layer: Int,
        alpha: Double,
        isOnScreen: Bool,
        sharingState: UInt32?,
        frontToBackIndex: Int
    ) {
        self.windowID = windowID
        self.ownerProcessID = ownerProcessID
        self.ownerName = ownerName
        self.globalBounds = globalBounds
        self.layer = layer
        self.alpha = alpha
        self.isOnScreen = isOnScreen
        self.sharingState = sharingState
        self.frontToBackIndex = frontToBackIndex
    }
}

public struct MacDesktopCensus: Hashable, Sendable {
    public let displays: [MacDisplaySnapshot]
    public let applications: [MacApplicationSnapshot]
    public let windows: [MacWindowSnapshot]

    public init(
        displays: [MacDisplaySnapshot],
        applications: [MacApplicationSnapshot],
        windows: [MacWindowSnapshot]
    ) {
        self.displays = displays
        self.applications = applications
        self.windows = windows
    }
}

public enum MacDesktopCensusError: Error, Equatable, Sendable {
    case displayEnumerationFailed(CGError)
    case windowEnumerationFailed
    case noUsableDisplays
}

public protocol MacDesktopCensusProviding: Sendable {
    func capture() throws -> MacDesktopCensus
}

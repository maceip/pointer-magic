import Foundation
import PointerSceneContracts

/// Pixel-space metadata copied from a ScreenCaptureKit frame attachment. It never
/// retains the sample buffer, IOSurface, or any pixel bytes.
public struct ScreenDirtyPixelRect: Hashable, Sendable {
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

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
}

/// One bounded callback token. `didTruncateInput` means metadata was discarded at
/// the callback boundary and therefore must break coverage rather than be treated as
/// a complete set of dirty regions.
public struct ScreenDirtyRegionFrame: Hashable, Sendable {
    public let displayID: UInt32
    public let topologyRevision: UInt64
    public let outputWidth: Int
    public let outputHeight: Int
    public let dirtyRects: [ScreenDirtyPixelRect]
    public let didTruncateInput: Bool

    public init(
        displayID: UInt32,
        topologyRevision: UInt64,
        outputWidth: Int,
        outputHeight: Int,
        dirtyRects: [ScreenDirtyPixelRect],
        didTruncateInput: Bool = false
    ) {
        self.displayID = displayID
        self.topologyRevision = topologyRevision
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.dirtyRects = dirtyRects
        self.didTruncateInput = didTruncateInput
    }
}

public struct ScreenDirtyRegionNormalizationPolicy: Hashable, Sendable {
    /// Hard callback and normalization ceilings. Callers may request a smaller
    /// budget, but cannot increase per-frame work beyond these values.
    public static let hardMaximumInputRects = 64
    public static let hardMaximumOutputRegions = 16

    public let maximumInputRects: Int
    public let maximumOutputRegions: Int
    public let mergeTolerancePixels: Double

    public init(
        maximumInputRects: Int = hardMaximumInputRects,
        maximumOutputRegions: Int = hardMaximumOutputRegions,
        mergeTolerancePixels: Double = 1
    ) {
        precondition(mergeTolerancePixels.isFinite && mergeTolerancePixels >= 0)
        self.maximumInputRects = min(
            Self.hardMaximumInputRects,
            max(1, maximumInputRects)
        )
        self.maximumOutputRegions = min(
            Self.hardMaximumOutputRegions,
            max(1, maximumOutputRegions)
        )
        self.mergeTolerancePixels = mergeTolerancePixels
    }

    public static let `default` = ScreenDirtyRegionNormalizationPolicy()
}

enum ScreenDirtyRegionCallbackBudget {
    static func clampedMaximumRectsPerFrame(_ requested: Int) -> Int {
        min(
            ScreenDirtyRegionNormalizationPolicy.hardMaximumInputRects,
            max(1, requested)
        )
    }
}

public enum ScreenDirtyRegionNormalizationError: Error, Equatable, Sendable {
    case invalidOutputExtent
    case callbackMetadataOverflow
    case coordinateRevisionMismatch(expected: UInt64, actual: UInt64)
    case unknownDisplay(UInt32)
    case outputRegionBudgetExceeded(limit: Int)
}

public struct ScreenDirtyRegionNormalizationResult: Hashable, Sendable {
    public let regions: [SurfaceRegion]
    public let acceptedInputRectCount: Int
    public let didCoalesce: Bool

    public init(
        regions: [SurfaceRegion],
        acceptedInputRectCount: Int,
        didCoalesce: Bool
    ) {
        self.regions = regions
        self.acceptedInputRectCount = acceptedInputRectCount
        self.didCoalesce = didCoalesce
    }
}

/// Deterministic dirty-rectangle normalization. The exact immutable coordinate
/// snapshot is supplied by the shared desktop registry, so a frame can never be
/// silently mapped through a newer display topology.
public enum ScreenDirtyRegionNormalizer {
    public static func normalize(
        _ frame: ScreenDirtyRegionFrame,
        through snapshot: MacDesktopCoordinateSnapshot,
        policy: ScreenDirtyRegionNormalizationPolicy = .default
    ) throws -> ScreenDirtyRegionNormalizationResult {
        guard frame.outputWidth > 0, frame.outputHeight > 0 else {
            throw ScreenDirtyRegionNormalizationError.invalidOutputExtent
        }
        guard !frame.didTruncateInput,
              frame.dirtyRects.count <= policy.maximumInputRects
        else {
            throw ScreenDirtyRegionNormalizationError.callbackMetadataOverflow
        }
        guard frame.topologyRevision == snapshot.topologyRevision else {
            throw ScreenDirtyRegionNormalizationError.coordinateRevisionMismatch(
                expected: snapshot.topologyRevision,
                actual: frame.topologyRevision
            )
        }
        guard let display = snapshot.displayMappings.first(where: {
            $0.display.displayID == frame.displayID
        })?.display else {
            throw ScreenDirtyRegionNormalizationError.unknownDisplay(frame.displayID)
        }

        let outputBounds = ScreenDirtyPixelRect(
            x: 0,
            y: 0,
            width: Double(frame.outputWidth),
            height: Double(frame.outputHeight)
        )!
        var clipped = frame.dirtyRects.compactMap { intersection($0, outputBounds) }
        clipped.sort(by: canonicalOrder)
        let originalCount = clipped.count
        clipped = coalesce(clipped, tolerance: policy.mergeTolerancePixels)

        guard clipped.count <= policy.maximumOutputRegions else {
            throw ScreenDirtyRegionNormalizationError.outputRegionBudgetExceeded(
                limit: policy.maximumOutputRegions
            )
        }

        let scaleX = display.globalBounds.width / Double(frame.outputWidth)
        let scaleY = display.globalBounds.height / Double(frame.outputHeight)
        let regions = clipped.compactMap { rect -> SurfaceRegion? in
            guard let global = MacGlobalRect(
                x: display.globalBounds.x + rect.x * scaleX,
                y: display.globalBounds.y + rect.y * scaleY,
                width: rect.width * scaleX,
                height: rect.height * scaleY
            ) else {
                return nil
            }
            return snapshot.mapQuartzGlobalRect(global)
        }

        return ScreenDirtyRegionNormalizationResult(
            regions: regions,
            acceptedInputRectCount: originalCount,
            didCoalesce: regions.count < originalCount
        )
    }

    private static func coalesce(
        _ input: [ScreenDirtyPixelRect],
        tolerance: Double
    ) -> [ScreenDirtyPixelRect] {
        var pending = input
        mergePass: while true {
            guard pending.count > 1 else { break }
            for index in 0 ..< (pending.count - 1) {
                for comparison in (index + 1) ..< pending.count {
                    if shouldMerge(
                        pending[index],
                        pending[comparison],
                        tolerance: tolerance
                    ) {
                        pending[index] = union(pending[index], pending[comparison])
                        pending.remove(at: comparison)
                        // A new union may bridge rectangles that were previously
                        // separate, so restart until the result reaches a fixed point.
                        continue mergePass
                    }
                }
            }
            break
        }
        pending.sort(by: canonicalOrder)
        return pending
    }

    private static func intersection(
        _ lhs: ScreenDirtyPixelRect,
        _ rhs: ScreenDirtyPixelRect
    ) -> ScreenDirtyPixelRect? {
        let x = max(lhs.x, rhs.x)
        let y = max(lhs.y, rhs.y)
        let maxX = min(lhs.maxX, rhs.maxX)
        let maxY = min(lhs.maxY, rhs.maxY)
        return ScreenDirtyPixelRect(x: x, y: y, width: maxX - x, height: maxY - y)
    }

    private static func shouldMerge(
        _ lhs: ScreenDirtyPixelRect,
        _ rhs: ScreenDirtyPixelRect,
        tolerance: Double
    ) -> Bool {
        lhs.x <= rhs.maxX + tolerance &&
            rhs.x <= lhs.maxX + tolerance &&
            lhs.y <= rhs.maxY + tolerance &&
            rhs.y <= lhs.maxY + tolerance
    }

    private static func union(
        _ lhs: ScreenDirtyPixelRect,
        _ rhs: ScreenDirtyPixelRect
    ) -> ScreenDirtyPixelRect {
        let x = min(lhs.x, rhs.x)
        let y = min(lhs.y, rhs.y)
        let maxX = max(lhs.maxX, rhs.maxX)
        let maxY = max(lhs.maxY, rhs.maxY)
        return ScreenDirtyPixelRect(x: x, y: y, width: maxX - x, height: maxY - y)!
    }

    private static func canonicalOrder(
        _ lhs: ScreenDirtyPixelRect,
        _ rhs: ScreenDirtyPixelRect
    ) -> Bool {
        if lhs.y != rhs.y { return lhs.y < rhs.y }
        if lhs.x != rhs.x { return lhs.x < rhs.x }
        if lhs.height != rhs.height { return lhs.height < rhs.height }
        return lhs.width < rhs.width
    }
}

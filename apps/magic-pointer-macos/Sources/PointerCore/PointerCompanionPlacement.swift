public enum PointerCompanionPlacement: String, Codable, Hashable, Sendable {
    case below
    case above
    case right
    case left
}

public struct PointerCompanionLayoutResult: Codable, Hashable, Sendable {
    public var placement: PointerCompanionPlacement
    public var frame: GlobalRect

    public init(placement: PointerCompanionPlacement, frame: GlobalRect) {
        self.placement = placement
        self.frame = frame
    }
}

/// One coordinate-space-independent placement policy shared by the click-through
/// follower and the interactive panel that replaces it.
public enum PointerCompanionLayout {
    public static func protectedCursorRect(at pointer: GlobalPoint) -> GlobalRect {
        // The macOS arrow hotspot is `pointer`; the visible glyph extends mostly down/right.
        GlobalRect(x: pointer.x - 5, y: pointer.y - 32, width: 36, height: 42)
    }

    public static func place(
        pointer: GlobalPoint,
        inside canvas: GlobalRect,
        size: GlobalSize,
        gap: Double = 5
    ) -> PointerCompanionLayoutResult {
        let protected = protectedCursorRect(at: pointer)
        let halfWidth = size.width / 2
        let halfHeight = size.height / 2

        let rightX = protected.maxX + gap + halfWidth
        let leftX = protected.minX - gap - halfWidth
        let belowY = protected.minY - gap - halfHeight
        let aboveY = protected.maxY + gap + halfHeight
        let lateralY = clamp(
            pointer.y - (protected.size.height + gap + halfHeight),
            minimum: canvas.minY + halfHeight,
            maximum: canvas.maxY - halfHeight
        )
        let verticalX = clamp(
            pointer.x,
            minimum: canvas.minX + halfWidth,
            maximum: canvas.maxX - halfWidth
        )

        let below = centeredFrame(
            at: GlobalPoint(x: verticalX, y: belowY),
            size: size
        )
        if contains(canvas, below), !intersects(below, protected) {
            return PointerCompanionLayoutResult(placement: .below, frame: below)
        }

        let above = centeredFrame(
            at: GlobalPoint(x: verticalX, y: aboveY),
            size: size
        )
        if contains(canvas, above), !intersects(above, protected) {
            return PointerCompanionLayoutResult(placement: .above, frame: above)
        }

        let right = centeredFrame(
            at: GlobalPoint(x: rightX, y: lateralY),
            size: size
        )
        if contains(canvas, right), !intersects(right, protected) {
            return PointerCompanionLayoutResult(placement: .right, frame: right)
        }

        let left = centeredFrame(
            at: GlobalPoint(x: leftX, y: lateralY),
            size: size
        )
        if contains(canvas, left), !intersects(left, protected) {
            return PointerCompanionLayoutResult(placement: .left, frame: left)
        }

        // Preserve cursor exclusion before full onscreen containment on pathological
        // display sizes. These checks stay scalar and allocation-free on the render path.
        if !intersects(below, protected) {
            return PointerCompanionLayoutResult(placement: .below, frame: below)
        }
        if !intersects(above, protected) {
            return PointerCompanionLayoutResult(placement: .above, frame: above)
        }
        if !intersects(right, protected) {
            return PointerCompanionLayoutResult(placement: .right, frame: right)
        }
        if !intersects(left, protected) {
            return PointerCompanionLayoutResult(placement: .left, frame: left)
        }

        let center = GlobalPoint(x: rightX, y: pointer.y)
        return PointerCompanionLayoutResult(
            placement: .right,
            frame: centeredFrame(at: center, size: size)
        )
    }

    private static func centeredFrame(at center: GlobalPoint, size: GlobalSize) -> GlobalRect {
        GlobalRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private static func contains(_ outer: GlobalRect, _ inner: GlobalRect) -> Bool {
        inner.minX >= outer.minX && inner.maxX <= outer.maxX &&
            inner.minY >= outer.minY && inner.maxY <= outer.maxY
    }

    private static func intersects(_ lhs: GlobalRect, _ rhs: GlobalRect) -> Bool {
        lhs.minX < rhs.maxX && lhs.maxX > rhs.minX &&
            lhs.minY < rhs.maxY && lhs.maxY > rhs.minY
    }

    private static func clamp(_ value: Double, minimum: Double, maximum: Double) -> Double {
        guard minimum <= maximum else { return (minimum + maximum) / 2 }
        return min(max(value, minimum), maximum)
    }
}

import CoreGraphics
import PointerCore

/// Keeps every decorative layer away from the real cursor glyph and its hotspot.
enum CompanionPlacement {
    static func protectedCursorRect(at pointer: CGPoint) -> CGRect {
        cgRect(
            PointerCompanionLayout.protectedCursorRect(
                at: GlobalPoint(x: pointer.x, y: pointer.y)
            )
        )
    }

    static func clusterSize(expanded: Bool) -> CGSize {
        expanded ? CGSize(width: 280, height: 190) : CGSize(width: 52, height: 40)
    }

    static func clusterRect(center: CGPoint, expanded: Bool) -> CGRect {
        clusterRect(center: center, size: clusterSize(expanded: expanded))
    }

    static func clusterRect(center: CGPoint, size: CGSize) -> CGRect {
        return CGRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    static func center(
        for pointer: CGPoint,
        inside canvas: CGRect,
        expanded: Bool
    ) -> CGPoint {
        center(
            for: pointer,
            inside: canvas,
            size: clusterSize(expanded: expanded),
            gap: expanded ? 12 : 5
        )
    }

    static func center(
        for pointer: CGPoint,
        inside canvas: CGRect,
        size: CGSize,
        gap: CGFloat = 5
    ) -> CGPoint {
        let result = PointerCompanionLayout.place(
            pointer: GlobalPoint(x: pointer.x, y: pointer.y),
            inside: GlobalRect(
                x: canvas.minX,
                y: canvas.minY,
                width: canvas.width,
                height: canvas.height
            ),
            size: GlobalSize(width: size.width, height: size.height),
            gap: gap
        )
        return CGPoint(x: result.frame.minX + size.width / 2, y: result.frame.minY + size.height / 2)
    }

    private static func cgRect(_ rect: GlobalRect) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: rect.origin.y,
            width: rect.size.width,
            height: rect.size.height
        )
    }
}

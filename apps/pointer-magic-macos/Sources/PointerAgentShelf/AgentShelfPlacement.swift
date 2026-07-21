import CoreGraphics
import PointerCore

enum AgentShelfPlacement {
    static let gap: CGFloat = 5

    static func frame(
        pointer: CGPoint,
        screenFrame: CGRect,
        shelfSize: CGSize
    ) -> CGRect {
        let result = PointerCompanionLayout.place(
            pointer: GlobalPoint(x: pointer.x, y: pointer.y),
            inside: GlobalRect(
                x: screenFrame.minX,
                y: screenFrame.minY,
                width: screenFrame.width,
                height: screenFrame.height
            ),
            size: GlobalSize(width: shelfSize.width, height: shelfSize.height),
            gap: gap
        )
        return CGRect(
            x: result.frame.minX,
            y: result.frame.minY,
            width: result.frame.size.width,
            height: result.frame.size.height
        )
    }
}

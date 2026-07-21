import CoreGraphics

/// A deliberate, one-way recovery gesture for the always-on shelf.
///
/// This is intentionally independent from the shake recognizer: dwelling in a
/// bottom corner can only request an unlocked follower. It can never park the
/// shelf or make the panel interactive.
struct AgentShelfCornerRestoreGesture {
    enum Corner: Equatable {
        case bottomLeft
        case bottomRight
    }

    private struct Screen: Equatable {
        let identifier: UInt32
        let frame: CGRect
    }

    private enum State {
        case outside
        case dwelling(screen: Screen, corner: Corner, enteredAtNs: UInt64)
        case latched(screen: Screen, corner: Corner)
        case suppressed(screen: Screen, corner: Corner)
    }

    private static let entryInset: CGFloat = 12
    private static let retentionInset: CGFloat = 20
    private static let dwellDurationNs: UInt64 = 2_000_000_000

    private var state: State = .outside
    private var lastTimestampNs: UInt64?

    mutating func observe(
        point: CGPoint,
        screenIdentifier: UInt32,
        screenFrame: CGRect,
        timestampNs: UInt64,
        buttonsArePressed: Bool
    ) -> Bool {
        if let lastTimestampNs, timestampNs < lastTimestampNs {
            reset()
            self.lastTimestampNs = timestampNs
            return false
        }
        lastTimestampNs = timestampNs

        let screen = Screen(identifier: screenIdentifier, frame: screenFrame)
        let entryCorner = corner(containing: point, in: screenFrame, inset: Self.entryInset)
        let retainedCorner = corner(
            containing: point,
            in: screenFrame,
            inset: Self.retentionInset
        )

        if buttonsArePressed {
            if let retainedCorner {
                state = .suppressed(screen: screen, corner: retainedCorner)
            } else {
                state = .outside
            }
            return false
        }

        switch state {
        case .outside:
            guard let entryCorner else { return false }
            state = .dwelling(
                screen: screen,
                corner: entryCorner,
                enteredAtNs: timestampNs
            )
            return false

        case let .dwelling(candidateScreen, candidateCorner, enteredAtNs):
            guard candidateScreen == screen,
                  retainedCorner == candidateCorner
            else {
                state = .outside
                return false
            }
            guard timestampNs >= enteredAtNs,
                  timestampNs - enteredAtNs >= Self.dwellDurationNs
            else { return false }
            state = .latched(screen: screen, corner: candidateCorner)
            return true

        case let .latched(candidateScreen, candidateCorner):
            guard candidateScreen == screen,
                  retainedCorner == candidateCorner
            else {
                state = .outside
                return false
            }
            return false

        case let .suppressed(candidateScreen, candidateCorner):
            guard candidateScreen == screen,
                  retainedCorner == candidateCorner
            else {
                state = .outside
                return false
            }
            return false
        }
    }

    mutating func reset() {
        state = .outside
        lastTimestampNs = nil
    }

    private func corner(
        containing point: CGPoint,
        in frame: CGRect,
        inset: CGFloat
    ) -> Corner? {
        guard frame.width > 0,
              frame.height > 0,
              point.y >= frame.minY,
              point.y <= frame.minY + inset
        else { return nil }

        if point.x >= frame.minX, point.x <= frame.minX + inset {
            return .bottomLeft
        }
        if point.x <= frame.maxX, point.x >= frame.maxX - inset {
            return .bottomRight
        }
        return nil
    }
}

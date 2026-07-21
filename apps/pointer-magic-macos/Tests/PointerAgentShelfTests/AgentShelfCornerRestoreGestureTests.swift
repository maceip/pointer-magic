import CoreGraphics
@testable import PointerAgentShelf
import Testing

@Suite("Agent shelf corner restore gesture")
struct AgentShelfCornerRestoreGestureTests {
    private let screen = CGRect(x: -1_440, y: -120, width: 1_440, height: 900)

    @Test("Either bottom corner restores after exactly two seconds")
    func bothBottomCorners() {
        for point in [
            CGPoint(x: -1_439, y: -119),
            CGPoint(x: -1, y: -119),
        ] {
            var gesture = AgentShelfCornerRestoreGesture()
            #expect(!observe(&gesture, point: point, timestampNs: 0))
            #expect(!observe(
                &gesture,
                point: point,
                timestampNs: 1_999_999_999
            ))
            #expect(observe(&gesture, point: point, timestampNs: 2_000_000_000))
            #expect(!observe(&gesture, point: point, timestampNs: 3_000_000_000))
        }
    }

    @Test("Small corner jitter is retained but leaving requires a fresh dwell")
    func hysteresisAndReentry() {
        var gesture = AgentShelfCornerRestoreGesture()
        #expect(!observe(
            &gesture,
            point: CGPoint(x: -1_439, y: -119),
            timestampNs: 0
        ))
        #expect(!observe(
            &gesture,
            point: CGPoint(x: -1_422, y: -102),
            timestampNs: 1_900_000_000
        ))
        #expect(observe(
            &gesture,
            point: CGPoint(x: -1_425, y: -105),
            timestampNs: 2_000_000_000
        ))

        #expect(!observe(
            &gesture,
            point: CGPoint(x: -1_400, y: -100),
            timestampNs: 2_100_000_000
        ))
        #expect(!observe(
            &gesture,
            point: CGPoint(x: -1_439, y: -119),
            timestampNs: 2_200_000_000
        ))
        #expect(!observe(
            &gesture,
            point: CGPoint(x: -1_439, y: -119),
            timestampNs: 4_199_999_999
        ))
        #expect(observe(
            &gesture,
            point: CGPoint(x: -1_439, y: -119),
            timestampNs: 4_200_000_000
        ))
    }

    @Test("Buttons suppress restoration until the pointer exits the corner")
    func buttonSuppression() {
        var gesture = AgentShelfCornerRestoreGesture()
        let corner = CGPoint(x: -1, y: -119)
        #expect(!observe(
            &gesture,
            point: corner,
            timestampNs: 0,
            buttonsArePressed: true
        ))
        #expect(!observe(&gesture, point: corner, timestampNs: 3_000_000_000))
        #expect(!observe(
            &gesture,
            point: CGPoint(x: -100, y: 0),
            timestampNs: 3_100_000_000
        ))
        #expect(!observe(&gesture, point: corner, timestampNs: 3_200_000_000))
        #expect(observe(&gesture, point: corner, timestampNs: 5_200_000_000))
    }

    @Test("Top corners, the bottom edge, and display changes cannot complete a dwell")
    func rejectsWrongGeometryAndDisplayChanges() {
        var gesture = AgentShelfCornerRestoreGesture()
        for point in [
            CGPoint(x: -1_439, y: 779),
            CGPoint(x: -720, y: -119),
            CGPoint(x: -1, y: 779),
        ] {
            #expect(!observe(&gesture, point: point, timestampNs: 0))
            #expect(!observe(&gesture, point: point, timestampNs: 3_000_000_000))
            gesture.reset()
        }

        let corner = CGPoint(x: -1_439, y: -119)
        #expect(!observe(&gesture, point: corner, timestampNs: 0))
        #expect(!observe(
            &gesture,
            point: corner,
            timestampNs: 2_100_000_000,
            screenIdentifier: 8
        ))
        #expect(!observe(
            &gesture,
            point: corner,
            timestampNs: 2_200_000_000,
            screenIdentifier: 8
        ))
        #expect(!observe(
            &gesture,
            point: corner,
            timestampNs: 4_199_999_999,
            screenIdentifier: 8
        ))
        #expect(observe(
            &gesture,
            point: corner,
            timestampNs: 4_200_000_000,
            screenIdentifier: 8
        ))
    }

    private func observe(
        _ gesture: inout AgentShelfCornerRestoreGesture,
        point: CGPoint,
        timestampNs: UInt64,
        buttonsArePressed: Bool = false,
        screenIdentifier: UInt32 = 7
    ) -> Bool {
        gesture.observe(
            point: point,
            screenIdentifier: screenIdentifier,
            screenFrame: screen,
            timestampNs: timestampNs,
            buttonsArePressed: buttonsArePressed
        )
    }
}

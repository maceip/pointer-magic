@preconcurrency import AppKit
@testable import PointerAgentShelf
import Testing

@Suite("Agent shelf compact presentation")
@MainActor
struct AgentShelfModeTests {
    private let presentation = AgentShelfPresentation(
        provider: "Cursor",
        state: "Working",
        directoryName: "webagent-ui",
        providerMark: .cursor
    )

    @Test("The shelf is one compact rounded pill with complete text")
    func compactGeometry() {
        let view = AgentShelfView(frame: CGRect(x: 0, y: 0, width: 220, height: 30))
        let size = view.apply(presentation)
        view.frame.size = size
        view.layoutSubtreeIfNeeded()

        #expect(size.height == 30)
        let measuredDirectoryWidth = ("webagent-ui" as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: 10.5, weight: .medium)]
        ).width
        let measuredStatusWidth = ("Working" as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .bold)]
        ).width
        let directoryWidth = max(measuredDirectoryWidth, view.renderedDirectoryIntrinsicWidth) + 4
        let statusWidth = max(measuredStatusWidth, view.renderedStateIntrinsicWidth) + 4
        let expectedWidth = ceil(
            20 + 14 + 5 + max(directoryWidth, statusWidth) + 4 + 22
        )

        #expect(size.width == expectedWidth)
        #expect(view.renderedProviderMark == .cursor)
        #expect(view.renderedDirectoryName == "webagent-ui")
        #expect(view.renderedState == "Working")
        #expect(view.renderedProviderMarkFrame.size == CGSize(width: 14, height: 14))
        #expect(view.renderedDirectoryFrame.width >= view.renderedDirectoryIntrinsicWidth + 4)
        #expect(view.renderedStateFrame.width >= view.renderedStateIntrinsicWidth + 4)
        #expect(view.renderedDirectoryFrame.minX == view.renderedStateFrame.minX)
        #expect(view.renderedStateFrame.maxX + 4 <= view.dismissHitFrame.minX)
        #expect(view.renderedStateFrame.minY > view.renderedDirectoryFrame.minY)
        #expect(view.renderedDirectoryLineBreakMode == .byClipping)
        #expect(view.renderedStateLineBreakMode == .byClipping)
        #expect(view.renderedCornerRadius == 15)
        #expect(view.clipsToRoundedShelf)
        #expect(view.usesTranslucentChrome)
        #expect(view.contentParticipatesInGlass)
        #expect(view.renderedDirectoryTextColor == NSColor.secondaryLabelColor)
        #expect(view.renderedStateTextColor == NSColor.labelColor)
        #expect(view.renderedProviderMarkColor == NSColor.labelColor)
    }

    @Test("Idle disclosure is only the active provider icon")
    func iconOnlyIdleGeometry() {
        let view = AgentShelfView(frame: CGRect(x: 0, y: 0, width: 220, height: 30))
        let currentShelfSize = view.apply(presentation)
        let idleSize = view.setDisclosureFraction(0)

        #expect(idleSize == CGSize(width: 30, height: 30))
        #expect(idleSize.width < currentShelfSize.width)
        #expect(view.renderedDisclosureFraction == 0)
        #expect(view.renderedProviderMark == .cursor)
        #expect(view.renderedProviderMarkFrame == CGRect(x: 8, y: 8, width: 14, height: 14))
        #expect(view.renderedDirectoryAlpha == 0)
        #expect(view.renderedStateAlpha == 0)
        #expect(view.renderedCornerRadius == 15)
        #expect(view.usesTranslucentChrome)
    }

    @Test("Every morph width stays between icon-only and the reviewed shelf")
    func disclosureNeverOvershoots() {
        let view = AgentShelfView(frame: CGRect(x: 0, y: 0, width: 220, height: 30))
        let maximumSize = view.apply(presentation)

        for step in 0 ... 20 {
            let fraction = CGFloat(step) / 20
            let size = view.setDisclosureFraction(fraction)
            #expect(size.width >= 30)
            #expect(size.width <= maximumSize.width)
            #expect(size.height == 30)
        }
    }

    @Test("Directory and status strings are never shortened or given ellipses")
    func textFitsIntrinsicWidth() {
        let directory = "example-substrate-agent-session-observer-with-a-long-directory-name"
        for state in ["Working", "Needs attention", "Waiting on a tool"] {
            let value = AgentShelfPresentation(
                provider: "Codex",
                state: state,
                directoryName: directory,
                providerMark: .codex
            )
            let view = AgentShelfView(frame: CGRect(x: 0, y: 0, width: 220, height: 30))
            let size = view.apply(value)
            view.frame.size = size
            view.layoutSubtreeIfNeeded()

            #expect(view.renderedDirectoryName == directory)
            #expect(view.renderedState == state)
            #expect(!view.renderedDirectoryName.contains("…"))
            #expect(!view.renderedState.contains("…"))
            #expect(view.renderedDirectoryLineBreakMode == .byClipping)
            #expect(view.renderedStateLineBreakMode == .byClipping)
            #expect(view.renderedDirectoryFrame.width >= view.renderedDirectoryIntrinsicWidth + 4)
            #expect(view.renderedStateFrame.width >= view.renderedStateIntrinsicWidth + 4)
            #expect(view.renderedStateFrame.maxX + 4 <= view.dismissHitFrame.minX)
        }
    }

    @Test("Every reviewed provider SVG rasterizes at tiny mark size")
    func providerMarksRasterize() {
        let view = AgentShelfProviderMarkView(frame: CGRect(x: 0, y: 0, width: 14, height: 14))
        for mark in [
            AgentShelfProviderMark.codex,
            .cursor,
            .claude,
            .geminiAntigravity,
        ] {
            view.apply(mark)
            #expect(view.image != nil)
            #expect(view.mark == mark)
        }
    }

    @Test("Controller accepts shared pointer samples while running")
    func controllerAcceptsPointerSamples() {
        let controller = AgentShelfController()
        controller.start()
        controller.acceptPointerSample(
            appKitPoint: CGPoint(x: 120, y: 240),
            timestampNs: DispatchTime.now().uptimeNanoseconds
        )
        #expect(controller.isRunning)
        controller.stop()
        #expect(!controller.isRunning)
    }
}

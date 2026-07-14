@preconcurrency import AppKit
import PointerCore
import PointerTransport
import QuartzCore

@MainActor
public final class HaloOverlayController: NSObject {
    private struct ScreenOverlay {
        var screen: NSScreen
        var displayID: CGDirectDisplayID
        var panel: OverlayPanel
        var canvas: HaloCanvasView
    }

    public var onInputBatch: ((PointerInputBatch) -> Void)?

    private let mailbox: MotionMailbox
    private let discreteRing: DiscreteRing
    private var overlays: [CGDirectDisplayID: ScreenOverlay] = [:]
    private var displayLink: CADisplayLink?
    private var activeDisplayID: CGDirectDisplayID?
    private var captureMode: PointerCaptureMode = .stopped
    private var reduceMotion = false
    private var scene: OverlayScene?
    private var lastMailboxVersion: UInt64 = 0
    private var lastFrame: PointerFrame?
    private var fallbackSequence: UInt64 = 0
    private var lastOverflowEpoch: UInt64 = 0
    private var isQuarantiningDiscreteInput = false
    private var quarantinedFrame: PointerFrame?
    private var renderLatency = LatencyWindow(capacity: 1_024)
    private var displayMaximumFPS: Float = 60
    private var isUsingActiveFrameRate = false
    private var lastMotionAtNs: UInt64 = 0
    private var canvasesAreVisible = false
    private var lastLatencyRecordedGeneration: UInt64?
    private var isRunning = false

    private static let activeTailNs: UInt64 = 200_000_000

    public init(mailbox: MotionMailbox, discreteRing: DiscreteRing) {
        self.mailbox = mailbox
        self.discreteRing = discreteRing
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    public func start(captureMode: PointerCaptureMode, reduceMotion: Bool) {
        guard !isRunning else { return }
        self.captureMode = captureMode
        self.reduceMotion = reduceMotion
        lastMailboxVersion = 0
        lastFrame = nil
        scene = nil
        lastMotionAtNs = 0
        canvasesAreVisible = false
        lastLatencyRecordedGeneration = nil
        isQuarantiningDiscreteInput = false
        quarantinedFrame = nil
        isUsingActiveFrameRate = false
        isRunning = true
        lastOverflowEpoch = discreteRing.overflowEpoch
        rebuildOverlays()

        if captureMode == .positionOnly {
            _ = acceptFallbackPosition(nowNs: DispatchTime.now().uptimeNanoseconds)
        }
        guard isRunning else { return }

        let initialAppKitPoint = NSEvent.mouseLocation
        let initialScreen = screen(containing: initialAppKitPoint) ?? NSScreen.main
        if let initialScreen {
            switchDisplayLink(to: initialScreen)
        }
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        captureMode = .stopped
        displayLink?.invalidate()
        displayLink = nil
        activeDisplayID = nil
        for overlay in overlays.values {
            overlay.panel.orderOut(nil)
        }
        lastFrame = nil
        scene = nil
        lastMotionAtNs = 0
        canvasesAreVisible = false
        lastLatencyRecordedGeneration = nil
        isQuarantiningDiscreteInput = false
        quarantinedFrame = nil
        isUsingActiveFrameRate = false
    }

    public func present(_ scene: OverlayScene?) {
        self.scene = scene
        if scene != nil {
            setFrameRate(active: true)
        } else {
            setCanvasesVisible(false)
            if captureMode == .positionOnly {
                setFrameRate(active: false)
            }
        }
    }

    public func refreshPositionOnlyFrame() -> PointerFrame? {
        guard isRunning, captureMode == .positionOnly else { return lastFrame }
        _ = acceptFallbackPosition(nowNs: DispatchTime.now().uptimeNanoseconds)
        guard isRunning else { return lastFrame }
        if let lastFrame,
           let screen = screen(containing: cgPoint(lastFrame.coordinates.appKitGlobal)),
           displayID(for: screen) != activeDisplayID
        {
            switchDisplayLink(to: screen)
        }
        return lastFrame
    }

    public func latencySummary() -> LatencySummary {
        renderLatency.summary()
    }

    @objc
    private func screenParametersChanged() {
        guard isRunning else { return }
        rebuildOverlays()
        if captureMode == .positionOnly {
            _ = acceptFallbackPosition(
                nowNs: DispatchTime.now().uptimeNanoseconds,
                force: true
            )
        }
        guard isRunning else { return }

        // A link attached to a disconnected display may never tick again. Invalidate it
        // unconditionally and choose a surviving screen from current physical state.
        displayLink?.invalidate()
        displayLink = nil
        activeDisplayID = nil
        let lastFrameScreen = lastFrame.flatMap {
            screen(containing: cgPoint($0.coordinates.appKitGlobal))
        }
        if let targetScreen = lastFrameScreen
            ?? screen(containing: NSEvent.mouseLocation)
            ?? NSScreen.main
        {
            switchDisplayLink(to: targetScreen)
        }
    }

    private func rebuildOverlays() {
        for overlay in overlays.values {
            overlay.panel.orderOut(nil)
        }
        overlays.removeAll(keepingCapacity: true)

        for screen in NSScreen.screens {
            guard let displayID = displayID(for: screen) else { continue }
            let canvas = HaloCanvasView(frame: CGRect(origin: .zero, size: screen.frame.size))
            canvas.isHidden = true
            let panel = OverlayPanel(screen: screen, contentView: canvas)
            overlays[displayID] = ScreenOverlay(
                screen: screen,
                displayID: displayID,
                panel: panel,
                canvas: canvas
            )
        }
    }

    private func switchDisplayLink(to screen: NSScreen) {
        guard let displayID = displayID(for: screen) else { return }
        if activeDisplayID == displayID, displayLink != nil {
            return
        }

        displayLink?.invalidate()
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        displayMaximumFPS = Float(max(60, screen.maximumFramesPerSecond))
        link.add(to: .main, forMode: .common)
        displayLink = link
        activeDisplayID = displayID
        let nowNs = DispatchTime.now().uptimeNanoseconds
        let motionIsActive = nowNs >= lastMotionAtNs &&
            nowNs - lastMotionAtNs <= Self.activeTailNs
        setFrameRate(active: scene != nil || motionIsActive, force: true)
    }

    @objc
    private func tick(_ link: CADisplayLink) {
        guard isRunning else { return }
        let nowNs = DispatchTime.now().uptimeNanoseconds
        var receivedMotion = false
        var pendingFrame: PointerFrame?

        if captureMode == .eventTap,
           let update = mailbox.read(afterVersion: lastMailboxVersion)
        {
            lastMailboxVersion = update.version
            let sample = update.sample
            pendingFrame = PointerFrame(
                generation: sample.sequence,
                sequence: sample.sequence,
                eventTimestampNs: sample.eventTimestampNs,
                observedTimestampNs: sample.observedTimestampNs,
                publishedTimestampNs: nowNs,
                coordinates: sample.coordinates,
                kind: sample.kind,
                buttons: PointerButtonMask(rawValue: sample.buttons),
                modifiers: PointerModifierFlags(rawValue: sample.flags)
            )
            receivedMotion = true
        } else if captureMode == .positionOnly {
            receivedMotion = acceptFallbackPosition(nowNs: nowNs)
        }
        guard isRunning else { return }

        if receivedMotion {
            lastMotionAtNs = nowNs
            setFrameRate(active: true)
        }

        // Once the fixed ring reports loss, quarantine both lanes until a bounded drain
        // actually observes the ring empty without another concurrent overflow. Retained
        // transitions are discarded: replaying either side of an unknown gap can invent a
        // clutch transition or let a click complete a shake.
        let overflowEpochBeforeDrain = discreteRing.overflowEpoch
        let discrete = discreteRing.count > 0 ? discreteRing.drain() : []
        let overflowEpochAfterDrain = discreteRing.overflowEpoch
        let detectedOverflow = overflowEpochBeforeDrain != lastOverflowEpoch ||
            overflowEpochAfterDrain != overflowEpochBeforeDrain
        if detectedOverflow, !isQuarantiningDiscreteInput {
            isQuarantiningDiscreteInput = true
            quarantinedFrame = pendingFrame ?? quarantinedFrame
            publish(
                PointerInputBatch(
                    frame: nil,
                    discreteEvents: [],
                    resynchronization: .beforeBatch
                )
            )
            guard isRunning else { return }
        }

        if isQuarantiningDiscreteInput {
            quarantinedFrame = pendingFrame ?? quarantinedFrame
            let observedStableEmpty = discrete.count < 128 &&
                overflowEpochAfterDrain == overflowEpochBeforeDrain
            if observedStableEmpty {
                let recoveryFrame = quarantinedFrame
                quarantinedFrame = nil
                isQuarantiningDiscreteInput = false
                lastOverflowEpoch = overflowEpochAfterDrain
                publish(
                    PointerInputBatch(
                        frame: recoveryFrame,
                        discreteEvents: [],
                        resynchronization: .transportRecovery
                    )
                )
            }
        } else if pendingFrame != nil || !discrete.isEmpty {
            publish(PointerInputBatch(frame: pendingFrame, discreteEvents: discrete))
        }
        guard isRunning else { return }

        if let scene, scene.expiresAtNs <= nowNs {
            self.scene = nil
        }

        guard scene != nil else {
            setCanvasesVisible(false)
            if nowNs >= lastMotionAtNs,
               nowNs - lastMotionAtNs > Self.activeTailNs
            {
                setFrameRate(active: false)
            }
            return
        }

        guard let frame = lastFrame,
              let screen = screen(containing: cgPoint(frame.coordinates.appKitGlobal)),
              let displayID = displayID(for: screen),
              let activeOverlay = overlays[displayID]
        else {
            return
        }

        if activeDisplayID != displayID {
            switchDisplayLink(to: screen)
        }
        canvasesAreVisible = true
        for (candidateID, overlay) in overlays {
            if candidateID == displayID {
                overlay.canvas.isHidden = false
                if !overlay.panel.isVisible {
                    overlay.panel.orderFrontRegardless()
                }
            } else {
                overlay.canvas.isHidden = true
                if overlay.panel.isVisible {
                    overlay.panel.orderOut(nil)
                }
            }
        }

        let appPoint = frame.coordinates.appKitGlobal
        let localPoint = CGPoint(
            x: appPoint.x - screen.frame.minX,
            y: appPoint.y - screen.frame.minY
        )
        let targetLocal = scene?.targetFrame.flatMap {
            convertQuartzRectToLocalAppKit($0, on: screen, displayID: displayID)
        }
        activeOverlay.canvas.render(
            pointerLocal: localPoint,
            targetLocal: targetLocal,
            scene: scene,
            timestamp: link.timestamp,
            reduceMotion: reduceMotion,
            backingScale: screen.backingScaleFactor
        )
        let submittedNs = DispatchTime.now().uptimeNanoseconds
        // A generation is timed once even if a higher layer changes scenes while the
        // pointer is stationary. Otherwise clutch-hold time is misreported as render time.
        if lastLatencyRecordedGeneration != frame.generation,
           submittedNs >= frame.observedTimestampNs
        {
            lastLatencyRecordedGeneration = frame.generation
            renderLatency.record(submittedNs - frame.observedTimestampNs)
        }
    }

    private func publish(_ batch: PointerInputBatch) {
        if let frame = batch.frame {
            lastFrame = frame
        }
        onInputBatch?(batch)
    }

    @discardableResult
    private func acceptFallbackPosition(nowNs: UInt64, force: Bool = false) -> Bool {
        let appKitPoint = NSEvent.mouseLocation
        if !force,
           let lastFrame,
           lastFrame.coordinates.appKitGlobal.distanceSquared(
               to: GlobalPoint(x: appKitPoint.x, y: appKitPoint.y)
           ) < 0.01
        {
            return false
        }
        guard let screen = screen(containing: appKitPoint),
              let displayID = displayID(for: screen)
        else {
            return false
        }

        let displayBounds = CGDisplayBounds(displayID)
        let localX = appKitPoint.x - screen.frame.minX
        let localY = appKitPoint.y - screen.frame.minY
        let quartzPoint = GlobalPoint(
            x: displayBounds.minX + localX,
            y: displayBounds.minY + screen.frame.height - localY
        )
        fallbackSequence &+= 1
        publish(
            PointerInputBatch(
                frame: PointerFrame(
                    generation: fallbackSequence,
                    sequence: fallbackSequence,
                    eventTimestampNs: nowNs,
                    observedTimestampNs: nowNs,
                    publishedTimestampNs: nowNs,
                    coordinates: PointerCoordinates(
                        quartzGlobal: quartzPoint,
                        appKitGlobal: GlobalPoint(x: appKitPoint.x, y: appKitPoint.y)
                    ),
                    kind: .fallback,
                    buttons: [],
                    modifiers: []
                ),
                discreteEvents: []
            )
        )
        return true
    }

    private func setFrameRate(active: Bool, force: Bool = false) {
        guard let displayLink else { return }
        guard force || active != isUsingActiveFrameRate else { return }
        isUsingActiveFrameRate = active

        if active {
            displayLink.isPaused = false
            displayLink.preferredFrameRateRange = CAFrameRateRange(
                minimum: min(60, displayMaximumFPS),
                maximum: displayMaximumFPS,
                preferred: displayMaximumFPS
            )
        } else {
            if captureMode == .positionOnly {
                displayLink.isPaused = true
                return
            }
            displayLink.isPaused = false
            let idleMaximum = min(30, displayMaximumFPS)
            displayLink.preferredFrameRateRange = CAFrameRateRange(
                minimum: idleMaximum,
                maximum: idleMaximum,
                preferred: idleMaximum
            )
        }
    }

    private func setCanvasesVisible(_ visible: Bool) {
        guard visible != canvasesAreVisible else { return }
        canvasesAreVisible = visible
        if !visible {
            for overlay in overlays.values {
                overlay.canvas.isHidden = true
                if overlay.panel.isVisible {
                    overlay.panel.orderOut(nil)
                }
            }
        }
    }

    private func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) })
    }

    private func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }

    private func convertQuartzRectToLocalAppKit(
        _ rect: GlobalRect,
        on screen: NSScreen,
        displayID: CGDirectDisplayID
    ) -> CGRect? {
        let displayBounds = CGDisplayBounds(displayID)
        let quartzRect = CGRect(
            x: rect.origin.x,
            y: rect.origin.y,
            width: rect.size.width,
            height: rect.size.height
        )
        guard displayBounds.intersects(quartzRect) else { return nil }

        return CGRect(
            x: quartzRect.minX - displayBounds.minX,
            y: screen.frame.height - (quartzRect.maxY - displayBounds.minY),
            width: quartzRect.width,
            height: quartzRect.height
        )
    }

    private func cgPoint(_ point: GlobalPoint) -> CGPoint {
        CGPoint(x: point.x, y: point.y)
    }
}

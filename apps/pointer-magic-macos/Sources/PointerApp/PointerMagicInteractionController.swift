@preconcurrency import AppKit
import PointerMagicKit
import PointerCore

/// Demo feature layer for the explicit menu / Right Option perception clutch.
///
/// Shelf parking owns the wiggle recognizer. This controller never runs a second
/// shake detector for the same motion, so one gesture cannot open Perception
/// underneath a parked shelf.
@MainActor
final class PointerMagicInteractionController {
    private let bedrock: PointerBedrock
    private let pinnedPanel = PinnedGlassPanelController()
    private let perception: PerceptionCoordinator
    private let perceptionOutline = PerceptionOutlineController()

    private var clutchState: PointerClutchState = .idle
    private var latestFrame: PointerFrame?
    private var inputObservation: PointerInputObservation?
    private var expiryTask: Task<Void, Never>?
    private var pinnedPointerFrame: PointerFrame?
    private var currentSampleID: UUID?
    private var currentSample: PerceptionSample?
    private var hasExplicitCandidateSelection = false
    private var isStarted = false
    private var supportsGlobalInput = false

    private static let activeLifetimeNs: UInt64 = 20_000_000_000

    init(bedrock: PointerBedrock) {
        self.bedrock = bedrock
        perception = PerceptionCoordinator(bedrock: bedrock)

        pinnedPanel.onPointerEntered = { [weak self] in
            self?.latchPanel()
        }
        pinnedPanel.onFollowPointer = { [weak self] in
            self?.resumeFollowing()
        }
        pinnedPanel.onCandidateChanged = { [weak self] index in
            self?.selectCandidate(at: index)
        }
        pinnedPanel.onFeedback = { [weak self] feedback in
            self?.recordFeedback(feedback)
        }
        pinnedPanel.onScreenParametersChanged = { [weak self] in
            self?.dismiss()
        }
        pinnedPanel.onClose = { [weak self] in
            self?.dismiss()
        }
    }

    func start(captureMode: PointerCaptureMode) {
        guard !isStarted else { return }
        isStarted = true
        supportsGlobalInput = captureMode == .eventTap

        inputObservation = bedrock.observeOrderedInput { [weak self] input in
            guard let self else { return }
            switch input {
            case let .frame(frame):
                self.accept(frame)
            case let .discrete(event):
                self.accept(event)
            }
        }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        if let inputObservation {
            bedrock.removeInputObservation(inputObservation)
            self.inputObservation = nil
        }
        expiryTask?.cancel()
        expiryTask = nil
        perception.stop()
        perceptionOutline.hide()
        pinnedPanel.hide()
        bedrock.clearOverlay()
        clutchState = .idle
        latestFrame = nil
        pinnedPointerFrame = nil
        currentSampleID = nil
        currentSample = nil
        hasExplicitCandidateSelection = false
        supportsGlobalInput = false
    }

    /// Menu fallback for accessibility, permission setup, and deterministic demos.
    func activateNow() {
        guard isStarted, let frame = bedrock.currentFrame() ?? latestFrame else { return }
        guard case .idle = clutchState else {
            dismiss()
            return
        }
        beginFollowing(from: frame)
        if !supportsGlobalInput {
            handleRightOption(isDown: true)
        }
    }

    var primaryActionTitle: String {
        clutchState == .idle ? "Show Pointer Magic here" : "Hide Pointer Magic"
    }

    var statusText: String {
        switch clutchState {
        case .idle:
            "Idle — activate Perception from this menu"
        case .following: "Following — hold the right Option key"
        case .pinning: "Panel fixed — move the pointer onto it"
        case .latched: "Panel ready"
        }
    }

    var instructionText: String {
        supportsGlobalInput
            ? "Wiggle to park · click to open · ✦ to release"
            : "Wiggle or ✦ to park · click to open · ✦ to release"
    }

    private func accept(_ frame: PointerFrame) {
        latestFrame = frame
        let nowNs = DispatchTime.now().uptimeNanoseconds

        if case .latched = clutchState {
            // A frozen perception sample remains inspectable until the user explicitly
            // chooses Keep scanning, Close, or Escape.
        } else if let lease = clutchState.lease, lease.isExpired(at: nowNs) {
            expire(nowNs: nowNs)
            return
        }

        guard case .idle = clutchState else { return }
        perception.observe(frame)
    }

    private func accept(_ event: PointerDiscreteEvent) {
        switch event.kind {
        case .rightOptionDown, .rightOptionUp, .rightCommandDown, .rightCommandUp:
            if let transition = event.kind.interactionModifierTransition {
                accept(transition)
            }
        case .resynchronize:
            if clutchState != .idle {
                dismiss()
            }
        case .buttonDown, .buttonUp, .scroll:
            break
        }
    }

    private func accept(_ transition: PointerInteractionModifierTransition) {
        switch transition {
        case let .pressed(modifier):
            if modifier == .rightOption {
                handleRightOption(isDown: true)
            }
        case let .released(modifier):
            if modifier == .rightOption {
                handleRightOption(isDown: false)
            }
        }
    }

    private func beginFollowing(from frame: PointerFrame) {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        let lease = PointerClutchLease(
            generation: frame.generation,
            expiresAtNs: nowNs &+ Self.activeLifetimeNs
        )
        clutchState = PointerClutchReducer.reduce(
            state: clutchState,
            event: .beginFollowing(lease: lease, nowNs: nowNs)
        )
        perception.cancelLiveSample()
        perception.cancelFrozenSample()
        perceptionOutline.hide()
        pinnedPointerFrame = nil
        currentSampleID = nil
        currentSample = nil
        hasExplicitCandidateSelection = false
        pinnedPanel.hide()
        presentFollower(using: bedrock.currentFrame() ?? frame, lease: lease)
        scheduleExpiry(for: lease)
    }

    private func presentFollower(using frame: PointerFrame, lease: PointerClutchLease) {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        guard !lease.isExpired(at: nowNs) else {
            expire(nowNs: nowNs)
            return
        }

        let scene = OverlayScene(
            sourceID: "pointer-magic.right-option-clutch",
            generation: frame.generation,
            createdAtNs: nowNs,
            expiresAtNs: lease.expiresAtNs,
            anchor: frame.coordinates.quartzGlobal,
            title: "Hold the right Option key",
            items: []
        )
        do {
            try bedrock.present(scene)
        } catch OverlayValidationError.staleGeneration {
            // A newer display-link frame can supersede a buffered public frame. Retry
            // once with the actor-owned current value; never relax generation checks.
            guard let current = bedrock.currentFrame(), current.generation != frame.generation
            else { return }
            let currentScene = OverlayScene(
                sourceID: scene.sourceID,
                generation: current.generation,
                createdAtNs: nowNs,
                expiresAtNs: lease.expiresAtNs,
                anchor: current.coordinates.quartzGlobal,
                title: scene.title,
                items: []
            )
            try? bedrock.present(currentScene)
        } catch {
            // Rendering failure is isolated from capture and clutch state.
        }
    }

    private func handleRightOption(isDown: Bool) {
        guard isStarted else { return }
        let nowNs = DispatchTime.now().uptimeNanoseconds
        let event: PointerClutchEvent = isDown
            ? .optionDown(nowNs: nowNs)
            : .optionUp(nowNs: nowNs)
        let previous = clutchState
        clutchState = PointerClutchReducer.reduce(state: previous, event: event)

        switch (previous, clutchState) {
        case (.following, .pinning):
            pinAtCurrentPointer()
        case (.pinning, .following):
            cancelPinAndResume()
        case (_, .idle):
            dismiss()
        default:
            break
        }
    }

    private func pinAtCurrentPointer() {
        guard let frame = bedrock.currentFrame() ?? latestFrame else {
            dismiss()
            return
        }

        bedrock.clearOverlay()
        guard let screen = NSScreen.screens.first(where: {
            NSMouseInRect(
                CGPoint(x: frame.coordinates.appKitGlobal.x, y: frame.coordinates.appKitGlobal.y),
                $0.frame,
                false
            )
        }) ?? NSScreen.main else {
            dismiss()
            return
        }
        let layout = PointerCompanionLayout.place(
            pointer: frame.coordinates.appKitGlobal,
            inside: GlobalRect(
                x: screen.visibleFrame.minX,
                y: screen.visibleFrame.minY,
                width: screen.visibleFrame.width,
                height: screen.visibleFrame.height
            ),
            size: GlobalSize(
                width: PinnedGlassPanelController.Metrics.perceptionLensSize.width,
                height: PinnedGlassPanelController.Metrics.perceptionLensSize.height
            ),
            gap: 5
        )
        let collapsedFrame = collapsedFrame(
            alignedTo: layout.frame,
            placement: layout.placement
        )
        let sampleID = UUID()
        hasExplicitCandidateSelection = false
        pinnedPointerFrame = frame
        currentSampleID = sampleID
        currentSample = PerceptionSample(
            sampleID: sampleID,
            snapshot: PerceptionSnapshot(
                generation: frame.generation,
                pointer: frame.coordinates.quartzGlobal,
                requestedAtNs: DispatchTime.now().uptimeNanoseconds,
                capturedAtNs: DispatchTime.now().uptimeNanoseconds,
                state: .enriching,
                candidates: []
            ),
            viewModel: .acquiring(sampleID: sampleID)
        )
        perception.beginFrozenSample(
            frame: frame,
            sampleID: sampleID
        ) { [weak self] sample in
            self?.accept(sample)
        }
        pinnedPanel.showPinned(
            frame: CGRect(
                x: collapsedFrame.minX,
                y: collapsedFrame.minY,
                width: collapsedFrame.size.width,
                height: collapsedFrame.size.height
            ),
            placement: layout.placement,
            label: "Move here to inspect"
        )
    }

    private func latchPanel() {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        let previous = clutchState
        clutchState = PointerClutchReducer.reduce(
            state: previous,
            event: .pointerEnteredPanel(nowNs: nowNs)
        )
        guard case .pinning = previous, case .latched = clutchState else { return }
        expiryTask?.cancel()
        expiryTask = nil
        let model = currentSample?.viewModel
            ?? PerceptionLensViewModel.acquiring(sampleID: currentSampleID ?? UUID())
        pinnedPanel.showPerceptionLens(model)
        updateOutline()
    }

    private func accept(_ sample: PerceptionSample) {
        guard sample.sampleID == currentSampleID else { return }
        var sample = sample
        if hasExplicitCandidateSelection, let previous = currentSample {
            let selectedID = previous.snapshot.selectedObjectID
                ?? previous.viewModel.selectedCandidate?.id
            sample.viewModel.selectedIndex = selectedID.flatMap { selectedID in
                sample.viewModel.candidates.firstIndex { $0.id == selectedID }
            } ?? 0
            if sample.snapshot.candidates.indices.contains(sample.viewModel.selectedIndex) {
                sample.snapshot.selectedObjectID = sample.snapshot.candidates[
                    sample.viewModel.selectedIndex
                ].id
            }
        }
        currentSample = sample
        guard case .latched = clutchState else { return }
        pinnedPanel.updatePerceptionLens(sample.viewModel)
        updateOutline()
    }

    private func selectCandidate(at index: Int) {
        guard var sample = currentSample,
              sample.viewModel.candidates.indices.contains(index)
        else { return }
        sample.viewModel.selectedIndex = index
        hasExplicitCandidateSelection = true
        if sample.snapshot.candidates.indices.contains(index) {
            sample.snapshot.selectedObjectID = sample.snapshot.candidates[index].id
        }
        currentSample = sample
        updateOutline()
    }

    private func recordFeedback(_ feedback: PerceptionFeedbackKind) {
        guard let sample = currentSample else { return }
        let index = sample.viewModel.selectedIndex
        Task { [weak self] in
            let recorded = await PerceptionFeedbackRecorder.shared.record(
                sample: sample,
                selectedIndex: index,
                feedback: feedback
            )
            guard let self, self.currentSampleID == sample.sampleID else { return }
            self.pinnedPanel.setFeedbackStatus(recorded: recorded)
        }
    }

    private func updateOutline() {
        guard case .latched = clutchState,
              let sample = currentSample,
              sample.snapshot.candidates.indices.contains(sample.viewModel.selectedIndex)
        else {
            perceptionOutline.hide()
            return
        }
        let candidate = sample.snapshot.candidates[sample.viewModel.selectedIndex]
        guard let bounds = candidate.bounds.value else {
            perceptionOutline.hide()
            return
        }
        perceptionOutline.show(
            quartzFrame: bounds,
            confidence: candidate.bounds.confidence,
            inferred: candidate.bounds.knowledge != .observed
        )
    }

    private func collapsedFrame(
        alignedTo lensFrame: GlobalRect,
        placement: PointerCompanionPlacement
    ) -> CGRect {
        let size = PinnedGlassPanelController.Metrics.collapsedSize
        let midX = lensFrame.minX + lensFrame.size.width / 2
        let midY = lensFrame.minY + lensFrame.size.height / 2
        switch placement {
        case .below:
            return CGRect(
                x: midX - size.width / 2,
                y: lensFrame.maxY - size.height,
                width: size.width,
                height: size.height
            )
        case .above:
            return CGRect(
                x: midX - size.width / 2,
                y: lensFrame.minY,
                width: size.width,
                height: size.height
            )
        case .right:
            return CGRect(
                x: lensFrame.minX,
                y: midY - size.height / 2,
                width: size.width,
                height: size.height
            )
        case .left:
            return CGRect(
                x: lensFrame.maxX - size.width,
                y: midY - size.height / 2,
                width: size.width,
                height: size.height
            )
        }
    }

    private func cancelPinAndResume() {
        perception.cancelFrozenSample()
        perceptionOutline.hide()
        pinnedPointerFrame = nil
        currentSampleID = nil
        currentSample = nil
        hasExplicitCandidateSelection = false
        pinnedPanel.hide()
        guard case let .following(lease) = clutchState,
              let frame = bedrock.currentFrame() ?? latestFrame
        else {
            dismiss()
            return
        }
        presentFollower(using: frame, lease: lease)
    }

    private func resumeFollowing() {
        guard let frame = bedrock.currentFrame() ?? latestFrame else {
            dismiss()
            return
        }
        // This is an explicit new scan, not a continuation of the activation lease.
        beginFollowing(from: frame)
    }

    private func scheduleExpiry(for lease: PointerClutchLease) {
        expiryTask?.cancel()
        let delay = lease.expiresAtNs &- DispatchTime.now().uptimeNanoseconds
        expiryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.expire(nowNs: DispatchTime.now().uptimeNanoseconds)
        }
    }

    private func expire(nowNs: UInt64) {
        clutchState = PointerClutchReducer.reduce(
            state: clutchState,
            event: .expiry(nowNs: nowNs)
        )
        if case .idle = clutchState {
            dismiss()
        }
    }

    private func dismiss() {
        clutchState = PointerClutchReducer.reduce(state: clutchState, event: .escape)
        expiryTask?.cancel()
        expiryTask = nil
        perception.cancelFrozenSample()
        perceptionOutline.hide()
        pinnedPointerFrame = nil
        currentSampleID = nil
        currentSample = nil
        hasExplicitCandidateSelection = false
        pinnedPanel.hide()
        bedrock.clearOverlay()
    }
}

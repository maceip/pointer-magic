@preconcurrency import AppKit
import PointerMagicKit
import PointerCore
import PointerMacPerception
import PointerMacSceneDiscovery
import PointerShelfContracts
import PointerShelfRuntime

/// Soft enrichment lane beside the shelf follower (game-loop two-lane model).
///
/// Hard rule: pointer follow never awaits this type. Agent compact docs are applied
/// on the present lane elsewhere. OCR + sample provider + merge write into a
/// generation-fenced mailbox; late or superseded results are dropped.
@MainActor
final class ContextShelfHost {
    /// Coalesce AX/agent churn before spending an enrichment attempt.
    static let settleNanoseconds: UInt64 = 100_000_000

    let runtime = ShelfProviderRuntime()
    let agentProvider = AgentShelfProvider()
    let sampleProvider = SampleContextShelfProvider()

    private let assembler = ContextAssembler()
    private let bedrock: PointerBedrock
    private let sceneDiscovery: MacSceneDiscoveryController
    private let perceptionEngine = VisualPerceptionEngine()

    private var mailbox = ShelfEnrichmentMailbox()
    private var latestSemantic: SemanticSnapshot?
    private var latestPerception: VisualPerceptionResult?
    private var semanticTask: Task<Void, Never>?
    private var enrichmentTask: Task<Void, Never>?
    private var revision: UInt64 = 0
    private var lastCommittedFingerprint: String?
    private var lastDocument: ShelfDocument?
    private var isEnabled = false
    private var isParked = false

    /// Fired only when an enrichment attempt is still current at commit time.
    var onCommittedDocument: ((ShelfDocument) -> Void)?
    var onStatus: ((String) -> Void)?

    init(bedrock: PointerBedrock, sceneDiscovery: MacSceneDiscoveryController) {
        self.bedrock = bedrock
        self.sceneDiscovery = sceneDiscovery
    }

    func start() async {
        isEnabled = true
        await runtime.register(agentProvider)
        await runtime.register(sampleProvider)
        semanticTask?.cancel()
        semanticTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await snapshot in self.bedrock.semanticUpdates() {
                guard !Task.isCancelled, self.isEnabled else { return }
                self.latestSemantic = snapshot
                self.noteSemanticSettle()
            }
        }
    }

    func stop() {
        isEnabled = false
        isParked = false
        semanticTask?.cancel()
        semanticTask = nil
        cancelEnrichment()
        lastCommittedFingerprint = nil
        lastDocument = nil
        Task { await runtime.releasePark() }
    }

    /// Records the agent snapshot for merge and kicks enrichment. Does not paint.
    func noteAgentSnapshot(_ snapshot: AgentShelfProvider.Snapshot?) {
        publishAgentSnapshot(snapshot)
    }

    /// Compatibility alias used by AppDelegate present-lane wiring.
    func publishAgentSnapshot(_ snapshot: AgentShelfProvider.Snapshot?) {
        agentProvider.publish(snapshot)
        if let snapshot {
            lastDocument = ShelfDocument.compact(
                id: snapshot.identityKey,
                providerId: AgentShelfProvider.providerID,
                revision: snapshot.revision,
                provider: snapshot.provider,
                state: snapshot.state,
                directoryName: snapshot.directoryName,
                providerMark: snapshot.providerMark
            )
        } else {
            lastDocument = nil
            lastCommittedFingerprint = nil
        }
        requestEnrichment()
    }

    func noteSemanticSettle() {
        requestEnrichment()
    }

    func setAgentActivateHandler(
        _ handler: @escaping @Sendable (String) async -> ShelfActionResult
    ) {
        agentProvider.setActivateHandler(handler)
    }

    func park() {
        isParked = true
        cancelEnrichment()
        let document = lastDocument
        Task { await runtime.park(document: document) }
    }

    func releasePark() {
        isParked = false
        Task { await runtime.releasePark() }
        requestEnrichment()
    }

    func invoke(actionId: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.runtime.invoke(actionId: actionId)
            if !result.message.isEmpty {
                self.onStatus?(result.message)
            } else {
                self.onStatus?(result.outcome.rawValue)
            }
        }
    }

    private func requestEnrichment() {
        guard isEnabled, !isParked else { return }
        let attempt = mailbox.beginAttempt()
        enrichmentTask?.cancel()
        perceptionEngine.cancelAll()
        enrichmentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: Self.settleNanoseconds)
            guard !Task.isCancelled, self.isEnabled, !self.isParked else { return }
            guard self.mailbox.isCurrent(attempt) else { return }
            await self.runEnrichment(attempt: attempt)
        }
    }

    private func cancelEnrichment() {
        enrichmentTask?.cancel()
        enrichmentTask = nil
        perceptionEngine.cancelAll()
        // Supersede any in-flight attempt so a late completion cannot commit.
        mailbox.beginAttempt()
    }

    private func runEnrichment(attempt: UInt64) async {
        guard let frame = bedrock.currentFrame() else { return }

        if VisualPerceptionEngine.hasScreenRecordingPermission {
            await refreshPerceptionIfPossible(frame: frame)
        }
        guard !Task.isCancelled, mailbox.isCurrent(attempt), !isParked else { return }

        revision &+= 1
        let packet = assembler.assemble(
            makeAssemblyInput(frame: frame, revision: revision)
        )
        guard mailbox.isCurrent(attempt) else { return }

        let proposed = await runtime.propose(using: packet)
        guard let proposed,
              let document = mailbox.commitIfCurrent(attempt: attempt, document: proposed)
        else { return }
        guard !isParked else { return }

        let fingerprint = document.dismissFingerprint + "|" +
            document.actions.map(\.id).joined(separator: ",") + "|" +
            (document.primary?.chips.map(\.text).joined(separator: "/") ?? "")
        guard fingerprint != lastCommittedFingerprint else { return }

        lastCommittedFingerprint = fingerprint
        lastDocument = document
        onCommittedDocument?(document)
    }

    private func refreshPerceptionIfPossible(frame: PointerFrame) async {
        let point = frame.coordinates.quartzGlobal
        let request = VisualPerceptionRequest(
            generation: frame.generation,
            point: PerceptionPoint(x: point.x, y: point.y),
            includeImageClassifications: false,
            includeForegroundSummary: false,
            includeCropPNG: false,
            excludeCurrentApplication: true
        )
        let result = await perceptionEngine.analyze(request)
        guard !Task.isCancelled else { return }
        if result.state == .fresh || result.state == .partial {
            latestPerception = result
        }
    }

    private func makeAssemblyInput(
        frame: PointerFrame,
        revision: UInt64
    ) -> ContextAssemblyInput {
        let semantic = latestSemantic.map { snapshot -> ContextAssemblySemanticInput in
            let target = snapshot.target
            return ContextAssemblySemanticInput(
                state: snapshot.state.rawValue,
                targetID: target?.id.rawValue.uuidString,
                processID: target?.processID,
                bundleIdentifier: target?.bundleIdentifier,
                role: target?.role,
                subrole: target?.subrole,
                label: target?.label,
                directValue: target?.directValue,
                textAtPoint: target?.textAtPoint,
                textRangeFrame: target?.textRangeFrame,
                frame: target?.frame,
                isEditable: target?.isEditable,
                sensitivityIsSecure: target?.sensitivity == .secure
            )
        }

        let perception = latestPerception.map { result -> ContextAssemblyPerceptionInput in
            ContextAssemblyPerceptionInput(
                state: result.state.rawValue,
                observations: result.textObservations.map { observation in
                    ContextAssemblyOCRObservation(
                        text: observation.text,
                        confidence: observation.confidence,
                        bounds: GlobalRect(
                            x: observation.globalBounds.minX,
                            y: observation.globalBounds.minY,
                            width: observation.globalBounds.size.width,
                            height: observation.globalBounds.size.height
                        )
                    )
                },
                cropBounds: result.crop.map {
                    GlobalRect(
                        x: $0.globalRect.minX,
                        y: $0.globalRect.minY,
                        width: $0.globalRect.size.width,
                        height: $0.globalRect.size.height
                    )
                },
                pixelWidth: result.crop?.pixelWidth,
                pixelHeight: result.crop?.pixelHeight,
                thumbToken: result.crop == nil ? nil : "perception-\(result.generation)"
            )
        }

        return ContextAssemblyInput(
            revision: revision,
            generation: frame.generation,
            sequence: frame.sequence,
            assembledAtNs: DispatchTime.now().uptimeNanoseconds,
            point: frame.coordinates.quartzGlobal,
            displayID: nil,
            semantic: semantic,
            perception: perception,
            scene: makeSceneInput(at: frame.coordinates.quartzGlobal)
        )
    }

    private func makeSceneInput(at quartzPoint: GlobalPoint) -> ContextAssemblySceneInput? {
        let fallback = ContextAssemblySceneInput(
            bundleIdentifier: latestSemantic?.target?.bundleIdentifier,
            applicationName: nil,
            windowTitle: nil,
            processID: latestSemantic?.target?.processID,
            isStale: false
        )
        guard let point = MacGlobalPoint(x: quartzPoint.x, y: quartzPoint.y) else {
            return fallback
        }
        let probe = sceneDiscovery.probeCache(atQuartzGlobal: point, limit: 4)
        guard let candidate = probe?.candidates.first else { return fallback }
        return ContextAssemblySceneInput(
            bundleIdentifier: latestSemantic?.target?.bundleIdentifier,
            applicationName: nil,
            windowTitle: latestSemantic?.target?.label,
            processID: latestSemantic?.target?.processID,
            isStale: candidate.spatial.isDependencyStale || candidate.spatial.isHistorical
        )
    }
}

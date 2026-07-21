@preconcurrency import AppKit
import PointerMagicKit
import PointerCore
import PointerMacPerception

struct PerceptionSample {
    var sampleID: UUID
    var snapshot: PerceptionSnapshot
    var viewModel: PerceptionLensViewModel
}

/// Progressive perception runs beside the pointer bedrock. Pointer events only
/// schedule/cancel work; AX, capture, OCR, and Vision remain on their owned workers.
@MainActor
final class PerceptionCoordinator {
    private let bedrock: PointerBedrock
    private let liveVisual = VisualPerceptionEngine()
    private let frozenVisual = VisualPerceptionEngine()
    private var liveTask: Task<Void, Never>?
    private var liveWorkerID: UUID?
    private var liveAcquisitionTask: Task<Void, Never>?
    private var liveAcquisitionID: UUID?
    private var frozenTask: Task<Void, Never>?
    private var latestFrame: PointerFrame?
    private var settleDeadlineNs: UInt64 = 0
    private(set) var latestLiveSample: PerceptionSample?

    private static let settleDelayNs: UInt64 = 70_000_000

    init(bedrock: PointerBedrock) {
        self.bedrock = bedrock
    }

    func stop() {
        cancelLiveSample()
        cancelFrozenSample()
        latestLiveSample = nil
    }

    /// Maintains a quiet best-current hypothesis while the pointer is idle. The
    /// result stays internal until the user explicitly invokes the Perception Lens.
    func observe(_ frame: PointerFrame) {
        if liveAcquisitionTask != nil {
            liveAcquisitionTask?.cancel()
            liveAcquisitionTask = nil
            liveAcquisitionID = nil
            liveVisual.cancelAll()
        }
        latestFrame = frame
        settleDeadlineNs = DispatchTime.now().uptimeNanoseconds &+ Self.settleDelayNs
        guard liveTask == nil else { return }
        let workerID = UUID()
        liveWorkerID = workerID
        liveTask = Task { @MainActor [weak self] in
            await self?.runLiveLoop(workerID: workerID)
        }
    }

    private func runLiveLoop(workerID: UUID) async {
        while !Task.isCancelled {
            let deadline = settleDeadlineNs
            let nowNs = DispatchTime.now().uptimeNanoseconds
            if deadline > nowNs {
                do {
                    try await Task.sleep(nanoseconds: deadline - nowNs)
                } catch {
                    break
                }
            }
            guard !Task.isCancelled else { break }
            guard deadline == settleDeadlineNs else { continue }
            guard let frame = latestFrame else { break }

            let acquisitionID = UUID()
            liveAcquisitionID = acquisitionID
            liveAcquisitionTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let sampleID = UUID()
                await self.acquire(
                    frame: frame,
                    sampleID: sampleID,
                    visualEngine: self.liveVisual,
                    semanticDetail: .enriched,
                    semanticDeadlineNs: 60_000_000,
                    accurateVisualText: false,
                    includeCropImage: false,
                    excludeCurrentApplication: false
                ) { [weak self] sample in
                    guard self?.latestFrame?.generation == frame.generation else { return }
                    self?.latestLiveSample = sample
                }
                if self.liveAcquisitionID == acquisitionID {
                    self.liveAcquisitionID = nil
                    self.liveAcquisitionTask = nil
                }
            }
            break
        }
        if liveWorkerID == workerID {
            liveWorkerID = nil
            liveTask = nil
        }
    }

    /// Starts a fresh, session-scoped sample at the original pinned point. The
    /// callback first receives AX evidence, then a stable-order fused update.
    func beginFrozenSample(
        frame: PointerFrame,
        sampleID: UUID,
        onUpdate: @escaping @MainActor (PerceptionSample) -> Void
    ) {
        cancelLiveSample()
        cancelFrozenSample()
        frozenTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.acquire(
                frame: frame,
                sampleID: sampleID,
                visualEngine: self.frozenVisual,
                semanticDetail: .enriched,
                semanticDeadlineNs: 150_000_000,
                accurateVisualText: true,
                includeCropImage: true,
                excludeCurrentApplication: true,
                onUpdate: onUpdate
            )
        }
    }

    func cancelFrozenSample() {
        frozenTask?.cancel()
        frozenTask = nil
        frozenVisual.cancelAll()
    }

    func cancelLiveSample() {
        liveTask?.cancel()
        liveAcquisitionTask?.cancel()
        liveTask = nil
        liveWorkerID = nil
        liveAcquisitionTask = nil
        liveAcquisitionID = nil
        latestFrame = nil
        settleDeadlineNs = 0
        liveVisual.cancelAll()
    }

    private func acquire(
        frame: PointerFrame,
        sampleID: UUID,
        visualEngine: VisualPerceptionEngine,
        semanticDetail: SemanticDetail,
        semanticDeadlineNs: UInt64,
        accurateVisualText: Bool,
        includeCropImage: Bool,
        excludeCurrentApplication: Bool,
        onUpdate: @escaping @MainActor (PerceptionSample) -> Void
    ) async {
        let requestedAtNs = DispatchTime.now().uptimeNanoseconds
        let semantic = await bedrock.resolve(
            SemanticRequest(
                generation: frame.generation,
                point: frame.coordinates.quartzGlobal,
                requestedAtNs: requestedAtNs,
                deadlineNs: semanticDeadlineNs,
                detail: semanticDetail
            )
        )
        guard !Task.isCancelled else { return }

        onUpdate(
            makeSample(
                sampleID: sampleID,
                frame: frame,
                semantic: semantic,
                visual: nil,
                requestedAtNs: requestedAtNs,
                includeCropImage: includeCropImage
            )
        )

        guard semantic.target?.sensitivity == .ordinary else {
            let completedAtNs = DispatchTime.now().uptimeNanoseconds
            let restricted = VisualPerceptionResult(
                generation: frame.generation,
                requestedAtNs: requestedAtNs,
                completedAtNs: completedAtNs,
                state: .unavailable,
                failure: .sensitivityRestricted,
                diagnostics: [
                    PerceptionDiagnostic(
                        stage: .capture,
                        message: "Visual analysis is disabled unless Accessibility positively classifies the target as ordinary."
                    ),
                ]
            )
            onUpdate(
                makeSample(
                    sampleID: sampleID,
                    frame: frame,
                    semantic: semantic,
                    visual: restricted,
                    requestedAtNs: requestedAtNs,
                    includeCropImage: includeCropImage
                )
            )
            return
        }

        guard let target = semantic.target,
              let visualCrop = visualCrop(
                for: target,
                pointer: frame.coordinates.quartzGlobal
              )
        else {
            let completedAtNs = DispatchTime.now().uptimeNanoseconds
            let ungrounded = VisualPerceptionResult(
                generation: frame.generation,
                requestedAtNs: requestedAtNs,
                completedAtNs: completedAtNs,
                state: .unavailable,
                failure: .captureScopeNotGrounded,
                diagnostics: [
                    PerceptionDiagnostic(
                        stage: .capture,
                        message: "Visual analysis requires a fresh, bounded text or image target whose crop does not include neighboring UI."
                    ),
                ]
            )
            onUpdate(
                makeSample(
                    sampleID: sampleID,
                    frame: frame,
                    semantic: semantic,
                    visual: ungrounded,
                    requestedAtNs: requestedAtNs,
                    includeCropImage: includeCropImage
                )
            )
            return
        }
        let isImageTarget = semantic.target.map {
            objectKind(forAXRole: $0.role) == .image
        } ?? false
        let visual = await visualEngine.analyze(
            VisualPerceptionRequest(
                generation: frame.generation,
                point: PerceptionPoint(
                    x: frame.coordinates.quartzGlobal.x,
                    y: frame.coordinates.quartzGlobal.y
                ),
                cropCenter: visualCrop.center,
                cropSizePoints: visualCrop.size,
                textRecognitionLevel: accurateVisualText ? .accurate : .fast,
                includeImageClassifications: isImageTarget,
                includeForegroundSummary: false,
                includeCropPNG: includeCropImage,
                excludeCurrentApplication: excludeCurrentApplication
            )
        )
        guard !Task.isCancelled else { return }
        onUpdate(
            makeSample(
                sampleID: sampleID,
                frame: frame,
                semantic: semantic,
                visual: visual,
                requestedAtNs: requestedAtNs,
                includeCropImage: includeCropImage
            )
        )
    }

    private func visualCrop(
        for target: SemanticTarget,
        pointer: GlobalPoint
    ) -> (center: PerceptionPoint, size: PerceptionSize)? {
        let kind = objectKind(forAXRole: target.role)
        guard kind == .text || kind == .image else { return nil }
        let frame = kind == .text && target.textAtPoint != nil
            ? target.textRangeFrame ?? target.frame
            : target.frame
        guard let frame,
              frame.contains(pointer, inset: 1),
              frame.size.width >= 16,
              frame.size.height >= 16,
              frame.size.width <= 720,
              frame.size.height <= 560
        else {
            return nil
        }

        return (
            PerceptionPoint(
                x: frame.minX + frame.size.width / 2,
                y: frame.minY + frame.size.height / 2
            ),
            PerceptionSize(width: frame.size.width, height: frame.size.height)
        )
    }

    private func makeSample(
        sampleID: UUID,
        frame: PointerFrame,
        semantic: SemanticSnapshot,
        visual: VisualPerceptionResult?,
        requestedAtNs: UInt64,
        includeCropImage: Bool
    ) -> PerceptionSample {
        let capturedAtNs = max(
            semantic.capturedAtNs,
            visual?.completedAtNs ?? semantic.capturedAtNs
        )
        let axFreshness = PerceptionFreshness(
            state: .current,
            observedAtNs: semantic.capturedAtNs,
            validUntilNs: semantic.capturedAtNs &+ 1_000_000_000
        )
        let visualObservedAtNs = visual?.completedAtNs ?? capturedAtNs
        let visualFreshness = PerceptionFreshness(
            state: .current,
            observedAtNs: visualObservedAtNs,
            validUntilNs: visualObservedAtNs &+ 1_000_000_000
        )

        var candidates: [PerceivedObject] = []
        if let target = semantic.target {
            candidates.append(axObject(
                target,
                capturedAtNs: semantic.capturedAtNs,
                freshness: axFreshness
            ))
        }
        if let visual {
            if !candidates.isEmpty,
               candidates[0].kind.value == .image,
               !visual.imageClassifications.isEmpty
            {
                let labels = visual.imageClassifications.prefix(4).map(\.identifier)
                let topConfidence = Double(visual.imageClassifications[0].confidence)
                candidates[0].meaning = field(
                    labels.joined(separator: " · "),
                    knowledge: .inferred,
                    confidence: topConfidence,
                    freshness: visualFreshness,
                    evidence: [
                        PerceptionEvidence(
                            source: .vision,
                            capturedAtNs: visual.completedAtNs,
                            detail: "Classification of the semantic object crop"
                        ),
                    ]
                )
            }
            candidates.append(contentsOf: visualObjects(
                visual,
                pointer: frame.coordinates.quartzGlobal,
                freshness: visualFreshness,
                excludingDuplicateOf: candidates.first
            ))
        }
        if candidates.isEmpty {
            candidates.append(unknownObject(
                at: frame.coordinates.quartzGlobal,
                freshness: axFreshness
            ))
        }

        candidates = rankCandidates(candidates, around: frame.coordinates.quartzGlobal)

        // Candidate order freezes with the combined sample. AX truth leads; visual
        // candidates are ordered by containment, confidence, and proximity.
        let snapshot = PerceptionSnapshot(
            generation: frame.generation,
            pointer: frame.coordinates.quartzGlobal,
            requestedAtNs: requestedAtNs,
            capturedAtNs: capturedAtNs,
            state: visual.map { snapshotState(semantic: semantic, visual: $0) } ?? .enriching,
            selectedObjectID: candidates.first?.id,
            candidates: candidates
        )
        return PerceptionSample(
            sampleID: sampleID,
            snapshot: snapshot,
            viewModel: lensViewModel(
                sampleID: sampleID,
                snapshot: snapshot,
                semantic: semantic,
                visual: visual,
                includeCropImage: includeCropImage
            )
        )
    }

    private func axObject(
        _ target: SemanticTarget,
        capturedAtNs: UInt64,
        freshness: PerceptionFreshness
    ) -> PerceivedObject {
        let evidence = PerceptionEvidence(
            source: .accessibility,
            capturedAtNs: capturedAtNs,
            sourceIdentifier: target.bundleIdentifier,
            detail: target.role
        )
        let kind = objectKind(forAXRole: target.role)
        let bounds = target.textAtPoint == nil
            ? target.frame
            : target.textRangeFrame ?? target.frame
        let ownerName = NSRunningApplication(
            processIdentifier: target.processID
        )?.localizedName
        let owner = PerceptionOwner(
            processID: target.processID,
            bundleIdentifier: target.bundleIdentifier,
            applicationName: ownerName
        )
        let surface = surfaceProvenance(for: target, kind: kind)
        let author = authorProvenance(for: surface.value)
        let content = PerceptionContent(
            label: target.label,
            textAtPoint: target.textAtPoint,
            elementValue: target.directValue,
            mediaType: kind == .image ? "image" : nil
        )
        let meaning = derivedMeaning(for: target, kind: kind)

        return PerceivedObject(
            id: PerceptionObjectID(rawValue: target.id.rawValue),
            kind: field(kind, knowledge: .observed, confidence: 1, freshness: freshness, evidence: [evidence]),
            bounds: field(bounds, knowledge: bounds == nil ? .unknown : .observed, confidence: bounds == nil ? 0 : 1, freshness: freshness, evidence: [evidence]),
            content: field(
                content,
                knowledge: target.textAtPoint == nil && target.directValue == nil && target.label == nil
                    ? .unknown
                    : .observed,
                confidence: target.textAtPoint == nil && target.directValue == nil && target.label == nil
                    ? 0
                    : 1,
                freshness: freshness,
                evidence: [evidence]
            ),
            meaning: meaning.map {
                field($0, knowledge: .derivedKnowledge, confidence: 0, freshness: freshness, evidence: [
                    PerceptionEvidence(source: .derived, capturedAtNs: evidence.capturedAtNs, detail: "AX role and label"),
                ])
            },
            owner: field(owner, knowledge: .observed, confidence: 1, freshness: freshness, evidence: [evidence]),
            surface: field(surface.value, knowledge: surface.knowledge, confidence: surface.confidence, freshness: freshness, evidence: [evidence]),
            author: field(
                author.value,
                knowledge: author.knowledge,
                confidence: 0,
                freshness: freshness,
                evidence: author.value == .unknown ? [] : [
                    PerceptionEvidence(
                        source: .derived,
                        capturedAtNs: evidence.capturedAtNs,
                        detail: "Conservative inference from the AX surface type"
                    ),
                ]
            )
        )
    }

    private func visualObjects(
        _ visual: VisualPerceptionResult,
        pointer: GlobalPoint,
        freshness: PerceptionFreshness,
        excludingDuplicateOf axObject: PerceivedObject?
    ) -> [PerceivedObject] {
        let nowNs = visual.completedAtNs
        let ocrEvidence = PerceptionEvidence(
            source: .opticalCharacterRecognition,
            capturedAtNs: nowNs,
            detail: visual.crop?.capturePath.rawValue
        )
        let axText = (
            axObject?.content?.value?.textAtPoint
                ?? axObject?.content?.value?.elementValue
        )?.trimmingCharacters(in: .whitespacesAndNewlines)

        var textObjects = visual.textObservations.compactMap { observation -> PerceivedObject? in
            let text = observation.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            if let axText,
               axText.caseInsensitiveCompare(text) == .orderedSame
            {
                return nil
            }
            let bounds = globalRect(observation.globalBounds)
            let distance = distanceSquared(from: pointer, to: bounds)
            guard distance <= 180 * 180 else { return nil }
            let confidence = Double(observation.confidence)
            return PerceivedObject(
                kind: field(.text, knowledge: .inferred, confidence: confidence, freshness: freshness, evidence: [ocrEvidence]),
                bounds: field(bounds, knowledge: .inferred, confidence: confidence, freshness: freshness, evidence: [ocrEvidence]),
                content: field(
                    PerceptionContent(text: text),
                    knowledge: .inferred,
                    confidence: confidence,
                    freshness: freshness,
                    evidence: [ocrEvidence]
                ),
                meaning: nil,
                owner: nil,
                surface: field(.renderedPixels, knowledge: .inferred, confidence: 0, freshness: freshness, evidence: [ocrEvidence]),
                author: field(.unknown, knowledge: .unknown, confidence: 0, freshness: freshness, evidence: [])
            )
        }

        textObjects.sort { lhs, rhs in
            let lhsContains = lhs.bounds.value?.contains(pointer, inset: 3) == true
            let rhsContains = rhs.bounds.value?.contains(pointer, inset: 3) == true
            if lhsContains != rhsContains { return lhsContains }
            let lhsDistance = lhs.bounds.value.map { distanceSquared(from: pointer, to: $0) } ?? .greatestFiniteMagnitude
            let rhsDistance = rhs.bounds.value.map { distanceSquared(from: pointer, to: $0) } ?? .greatestFiniteMagnitude
            if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
            return (lhs.content?.confidence ?? 0) > (rhs.content?.confidence ?? 0)
        }
        return Array(textObjects.prefix(8))
    }

    private func unknownObject(
        at point: GlobalPoint,
        freshness: PerceptionFreshness
    ) -> PerceivedObject {
        PerceivedObject(
            kind: field(.unknown, knowledge: .unknown, confidence: 0, freshness: freshness, evidence: []),
            bounds: field(nil, knowledge: .unknown, confidence: 0, freshness: freshness, evidence: []),
            surface: field(.unknown, knowledge: .unknown, confidence: 0, freshness: freshness, evidence: []),
            author: field(.unknown, knowledge: .unknown, confidence: 0, freshness: freshness, evidence: [])
        )
    }

    private func rankCandidates(
        _ candidates: [PerceivedObject],
        around pointer: GlobalPoint
    ) -> [PerceivedObject] {
        candidates.enumerated().sorted { lhs, rhs in
            let lhsRank = candidateRank(lhs.element, around: pointer)
            let rhsRank = candidateRank(rhs.element, around: pointer)
            if lhsRank.bucket != rhsRank.bucket { return lhsRank.bucket < rhsRank.bucket }
            if lhsRank.distance != rhsRank.distance { return lhsRank.distance < rhsRank.distance }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private func candidateRank(
        _ candidate: PerceivedObject,
        around pointer: GlobalPoint
    ) -> (bucket: Int, distance: Double) {
        let bounds = candidate.bounds.value
        let contains = bounds?.contains(pointer, inset: 3) == true
        let distance = bounds.map { distanceSquared(from: pointer, to: $0) }
            ?? .greatestFiniteMagnitude
        let kind = candidate.kind.value ?? .unknown
        let isOCR = candidate.kind.evidence.contains {
            $0.source == .opticalCharacterRecognition
        }

        let hasPointText = candidate.content?.value?.textAtPoint?.isEmpty == false
        if contains, (kind == .control || kind == .image || hasPointText), !isOCR {
            return (0, distance)
        }
        if contains, isOCR { return (1, distance) }
        if contains, [.text, .container, .document, .table, .canvas].contains(kind) {
            return (2, distance)
        }
        if contains { return (3, distance) }
        return (4, distance)
    }

    private func distanceSquared(from point: GlobalPoint, to rect: GlobalRect) -> Double {
        let dx: Double
        if point.x < rect.minX {
            dx = rect.minX - point.x
        } else if point.x > rect.maxX {
            dx = point.x - rect.maxX
        } else {
            dx = 0
        }
        let dy: Double
        if point.y < rect.minY {
            dy = rect.minY - point.y
        } else if point.y > rect.maxY {
            dy = point.y - rect.maxY
        } else {
            dy = 0
        }
        return dx * dx + dy * dy
    }

    private func lensViewModel(
        sampleID: UUID,
        snapshot: PerceptionSnapshot,
        semantic: SemanticSnapshot,
        visual: VisualPerceptionResult?,
        includeCropImage: Bool
    ) -> PerceptionLensViewModel {
        let cropImage = includeCropImage ? visual?.cropPNG.flatMap(NSImage.init(data:)) : nil
        let axTargetID = semantic.target.map { PerceptionObjectID(rawValue: $0.id.rawValue) }
        let candidates = snapshot.candidates.map { object in
            let isAX = object.id == axTargetID
            let content = object.content?.value
            let directText: PerceptionLensFieldViewModel
            if isAX, let text = content?.textAtPoint {
                directText = PerceptionLensFieldViewModel(
                    value: text,
                    evidence: "AX range",
                    confidence: nil,
                    knowledge: .observed
                )
            } else if isAX, let value = content?.elementValue ?? content?.label {
                directText = PerceptionLensFieldViewModel(
                    value: value,
                    evidence: content?.elementValue == nil ? "AX label" : "AX value",
                    confidence: nil,
                    knowledge: .observed
                )
            } else {
                directText = .unknown
            }
            let ocrText: PerceptionLensFieldViewModel
            if isAX,
               let visual,
               let objectBounds = object.bounds.value
            {
                let observations = visual.textObservations.filter { observation in
                    let center = GlobalPoint(
                        x: observation.globalBounds.minX + observation.globalBounds.size.width / 2,
                        y: observation.globalBounds.minY + observation.globalBounds.size.height / 2
                    )
                    return objectBounds.contains(
                        center,
                        inset: 4
                    ) && distanceSquared(
                        from: snapshot.pointer,
                        to: globalRect(observation.globalBounds)
                    ) <= 100 * 100
                }.sorted { lhs, rhs in
                    let lhsBounds = globalRect(lhs.globalBounds)
                    let rhsBounds = globalRect(rhs.globalBounds)
                    let lhsContains = lhsBounds.contains(snapshot.pointer, inset: 3)
                    let rhsContains = rhsBounds.contains(snapshot.pointer, inset: 3)
                    if lhsContains != rhsContains { return lhsContains }
                    return distanceSquared(from: snapshot.pointer, to: lhsBounds)
                        < distanceSquared(from: snapshot.pointer, to: rhsBounds)
                }
                let observation = observations.first
                let text = observation?.text ?? ""
                let confidence = observation.map { Double($0.confidence) }
                ocrText = PerceptionLensFieldViewModel(
                    value: text.isEmpty ? nil : text,
                    evidence: "OCR",
                    confidence: confidence,
                    knowledge: text.isEmpty ? .unknown : .inferred
                )
            } else if !isAX && object.kind.value == .text {
                ocrText = lensField(content?.text, field: object.content, fallbackEvidence: "OCR")
            } else {
                ocrText = .unknown
            }
            let owner = object.owner?.value
            let sourceParts = [
                owner?.applicationName,
                object.surface.value?.rawValue.humanized,
                object.author.value.map { "author \($0.rawValue.humanized)" },
            ].compactMap { $0 }
            let title = content?.label
                ?? content?.textAtPoint
                ?? content?.elementValue
                ?? content?.text
                ?? object.kind.value?.rawValue.humanized
                ?? "Unknown"
            return PerceptionCandidateViewModel(
                id: object.id,
                kind: object.kind.value ?? .unknown,
                title: String(title.prefix(120)),
                score: nil,
                crop: cropImage,
                bounds: object.bounds.value,
                directText: directText,
                ocrText: ocrText,
                meaning: lensField(object.meaning?.value, field: object.meaning, fallbackEvidence: "model"),
                source: PerceptionLensFieldViewModel(
                    value: sourceParts.isEmpty ? nil : sourceParts.joined(separator: " · "),
                    evidence: owner == nil ? "inferred" : "AX + inference",
                    confidence: nil,
                    knowledge: object.surface.knowledge == .unknown ? .unknown : .ambiguous
                )
            )
        }
        let visualStatus: String
        if let visual {
            visualStatus = visual.failure == nil
                ? "pixels/OCR \(milliseconds(visual.totalLatencyNs))"
                : "pixels \(visual.failure!.rawValue.humanized)"
        } else {
            visualStatus = "pixels pending"
        }
        let phase: PerceptionLensViewModel.Phase = switch snapshot.state {
        case .fresh: .frozen
        case .enriching: .acquiring
        case .partial: .partial
        case .unavailable, .failed, .superseded: .unavailable
        }
        let meaningStatus: String
        if snapshot.candidates.contains(where: {
            $0.meaning?.evidence.contains(where: { $0.source == .vision }) == true
        }) {
            meaningStatus = "meaning evidence Vision (sample)"
        } else if snapshot.candidates.contains(where: { $0.meaning?.value != nil }) {
            meaningStatus = "meaning evidence AX-derived (sample)"
        } else if visual == nil {
            meaningStatus = "meaning pending"
        } else {
            meaningStatus = "meaning unavailable"
        }
        return PerceptionLensViewModel(
            sampleID: sampleID,
            phase: phase,
            candidates: candidates,
            selectedIndex: 0,
            status: "AX \(milliseconds(semantic.resolutionLatencyNs)) · \(visualStatus) · \(meaningStatus)"
        )
    }

    private func lensField<Value>(
        _ value: String?,
        field: PerceptionField<Value>?,
        fallbackEvidence: String
    ) -> PerceptionLensFieldViewModel where Value: Codable & Hashable & Sendable {
        let source = field?.evidence.first?.source
        let rawModelConfidence = source == .opticalCharacterRecognition || source == .vision
            ? field?.confidence
            : nil
        return PerceptionLensFieldViewModel(
            value: value,
            evidence: field?.evidence.first.map { evidenceLabel($0.source) } ?? fallbackEvidence,
            confidence: rawModelConfidence,
            knowledge: field?.knowledge ?? .unknown
        )
    }

    private func snapshotState(
        semantic: SemanticSnapshot,
        visual: VisualPerceptionResult
    ) -> PerceptionSnapshotState {
        switch visual.state {
        case .fresh:
            return semantic.target == nil ? .partial : .fresh
        case .partial:
            return .partial
        case .unavailable:
            return semantic.target == nil ? .unavailable : .partial
        case .failed:
            return .partial
        case .superseded:
            return .superseded
        }
    }

    private func objectKind(forAXRole role: String) -> PerceptionObjectKind {
        switch role {
        case "AXStaticText", "AXTextField", "AXTextArea": .text
        case "AXImage": .image
        case "AXButton", "AXCheckBox", "AXRadioButton", "AXSlider", "AXPopUpButton",
             "AXMenuItem", "AXLink", "AXDisclosureTriangle", "AXSwitch": .control
        case "AXTable", "AXOutline", "AXList": .table
        case "AXDocument", "AXWebArea", "AXPDFArea": .document
        case "AXGroup", "AXScrollArea", "AXSplitGroup", "AXWindow": .container
        default: .unknown
        }
    }

    private func surfaceProvenance(
        for target: SemanticTarget,
        kind: PerceptionObjectKind
    ) -> (value: PerceptionSurfaceProvenance, knowledge: PerceptionKnowledgeState, confidence: Double) {
        let systemChromeBundles: Set<String> = [
            "com.apple.controlcenter",
            "com.apple.systemuiserver",
            "com.apple.dock",
            "com.apple.notificationcenterui",
        ]
        if let bundle = target.bundleIdentifier?.lowercased(), systemChromeBundles.contains(bundle) {
            return (.systemChrome, .inferred, 0)
        }
        if kind == .text, target.isEditable == true {
            return (.editableContent, .inferred, 0)
        }
        if target.role.contains("Web") || target.ancestors.contains(where: { $0.role.contains("Web") }) {
            return (.webContent, .inferred, 0)
        }
        if kind == .control { return (.applicationChrome, .inferred, 0) }
        if kind == .document || target.ancestors.contains(where: {
            $0.role == "AXDocument" || $0.role == "AXWebArea" || $0.role == "AXPDFArea"
        }) {
            return (.documentContent, .inferred, 0)
        }
        return (.unknown, .unknown, 0)
    }

    private func authorProvenance(
        for surface: PerceptionSurfaceProvenance
    ) -> (value: PerceptionAuthorProvenance, knowledge: PerceptionKnowledgeState) {
        switch surface {
        case .systemChrome:
            return (.system, .inferred)
        case .applicationChrome:
            return (.application, .inferred)
        case .editableContent:
            return (.localUser, .inferred)
        case .documentContent, .webContent, .remotePixels, .renderedPixels, .unknown:
            return (.unknown, .unknown)
        }
    }

    private func derivedMeaning(
        for target: SemanticTarget,
        kind: PerceptionObjectKind
    ) -> String? {
        let label = target.textAtPoint ?? target.label
        guard let label, !label.isEmpty else { return target.roleDescription }
        if kind == .control {
            let role = target.roleDescription ?? target.role.replacingOccurrences(of: "AX", with: "")
            return "\(role) labeled \(label)"
        }
        return nil
    }

    private func field<Value>(
        _ value: Value?,
        knowledge: PerceptionKnowledgeState,
        confidence: Double,
        freshness: PerceptionFreshness,
        evidence: [PerceptionEvidence]
    ) -> PerceptionField<Value> where Value: Codable & Hashable & Sendable {
        PerceptionField(
            value: value,
            knowledge: knowledge,
            confidence: confidence,
            freshness: freshness,
            evidence: evidence
        )
    }

    private func globalRect(_ rect: PerceptionRect) -> GlobalRect {
        GlobalRect(
            x: rect.origin.x,
            y: rect.origin.y,
            width: rect.size.width,
            height: rect.size.height
        )
    }

    private func evidenceLabel(_ source: PerceptionEvidenceSource) -> String {
        switch source {
        case .accessibility, .accessibilityTextRange: "AX"
        case .opticalCharacterRecognition: "OCR"
        case .screenPixels: "pixels"
        case .vision: "Vision"
        case .browserDOM: "DOM"
        case .applicationAdapter: "app"
        case .semanticModel: "model"
        case .windowMetadata: "window"
        case .temporalTracking: "tracking"
        case .userCorrection: "user"
        case .derived: "derived"
        }
    }

    private func milliseconds(_ nanoseconds: UInt64) -> String {
        String(format: "%.0f ms", Double(nanoseconds) / 1_000_000)
    }
}

private extension PerceptionKnowledgeState {
    static var derivedKnowledge: PerceptionKnowledgeState { .inferred }
}

private extension String {
    var humanized: String {
        replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
            .lowercased()
    }
}

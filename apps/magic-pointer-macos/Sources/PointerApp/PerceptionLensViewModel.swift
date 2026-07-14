@preconcurrency import AppKit
import PointerCore

enum PerceptionFeedbackKind: String, CaseIterable {
    case rightObject = "Correct"
    case wrongObject = "Wrong object"
    case wrongBounds = "Wrong bounds"
    case wrongDirectText = "Wrong direct text"
    case wrongOCRText = "Wrong OCR text"
    case wrongMeaning = "Wrong meaning"
    case shouldBeUnknown = "Should be unknown"
}

struct PerceptionLensFieldViewModel {
    var value: String?
    var evidence: String
    var confidence: Double?
    var knowledge: PerceptionKnowledgeState

    static let unknown = PerceptionLensFieldViewModel(
        value: nil,
        evidence: "unknown",
        confidence: nil,
        knowledge: .unknown
    )

    var renderedValue: String {
        guard let value, !value.isEmpty else { return "Unknown" }
        return value
    }

    var renderedEvidence: String {
        if knowledge == .observed { return "\(evidence) · observed" }
        guard let confidence else { return "\(evidence) · \(knowledge.rawValue)" }
        return "\(evidence) raw \(String(format: "%.2f", confidence))"
    }
}

struct PerceptionCandidateViewModel: Identifiable {
    var id: PerceptionObjectID
    var kind: PerceptionObjectKind
    var title: String
    var score: Double?
    var crop: NSImage?
    var bounds: GlobalRect?
    var directText: PerceptionLensFieldViewModel
    var ocrText: PerceptionLensFieldViewModel
    var meaning: PerceptionLensFieldViewModel
    var source: PerceptionLensFieldViewModel
}

struct PerceptionLensViewModel {
    enum Phase: String {
        case acquiring = "Acquiring"
        case frozen = "Frozen"
        case partial = "Partial"
        case unavailable = "Unavailable"
    }

    var sampleID: UUID
    var phase: Phase
    var candidates: [PerceptionCandidateViewModel]
    var selectedIndex: Int
    var status: String

    static func acquiring(sampleID: UUID) -> PerceptionLensViewModel {
        PerceptionLensViewModel(
            sampleID: sampleID,
            phase: .acquiring,
            candidates: [
                PerceptionCandidateViewModel(
                    id: PerceptionObjectID(),
                    kind: .unknown,
                    title: "Looking at the pinned point…",
                    score: nil,
                    crop: nil,
                    bounds: nil,
                    directText: .unknown,
                    ocrText: .unknown,
                    meaning: .unknown,
                    source: .unknown
                ),
            ],
            selectedIndex: 0,
            status: "AX pending · pixels pending · OCR pending · meaning pending"
        )
    }

    var selectedCandidate: PerceptionCandidateViewModel? {
        guard candidates.indices.contains(selectedIndex) else { return nil }
        return candidates[selectedIndex]
    }
}

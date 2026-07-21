import Foundation
import PointerCore

actor PerceptionFeedbackRecorder {
    struct CandidateRecord: Codable, Sendable {
        var id: PerceptionObjectID
        var kind: PerceptionObjectKind?
        var kindKnowledge: PerceptionKnowledgeState
        var bounds: GlobalRect?
        var boundsKnowledge: PerceptionKnowledgeState
        var surface: PerceptionSurfaceProvenance?
        var evidenceSources: [PerceptionEvidenceSource]
    }

    struct Record: Codable, Sendable {
        var recordedAt: Date
        var sampleID: UUID
        var generation: UInt64
        var selectedIndex: Int
        var selectedObjectID: PerceptionObjectID?
        var feedback: String
        var candidates: [CandidateRecord]
    }

    static let shared = PerceptionFeedbackRecorder()

    private let encoder: JSONEncoder
    private let fileURL: URL
    private let maximumBytes = 5 * 1_024 * 1_024

    private init() {
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let directory = root.appendingPathComponent("Pointer Magic", isDirectory: true)
        fileURL = directory.appendingPathComponent("perception-feedback.jsonl")
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
    }

    func record(
        sample: PerceptionSample,
        selectedIndex: Int,
        feedback: PerceptionFeedbackKind
    ) -> Bool {
        let candidate = sample.snapshot.candidates.indices.contains(selectedIndex)
            ? sample.snapshot.candidates[selectedIndex]
            : nil
        let record = Record(
            recordedAt: Date(),
            sampleID: sample.sampleID,
            generation: sample.snapshot.generation,
            selectedIndex: selectedIndex,
            selectedObjectID: candidate?.id,
            feedback: feedback.rawValue,
            candidates: sample.snapshot.candidates.map { candidate in
                CandidateRecord(
                    id: candidate.id,
                    kind: candidate.kind.value,
                    kindKnowledge: candidate.kind.knowledge,
                    bounds: candidate.bounds.value,
                    boundsKnowledge: candidate.bounds.knowledge,
                    surface: candidate.surface.value,
                    evidenceSources: Array(Set(
                        candidate.kind.evidence.map(\.source)
                            + candidate.bounds.evidence.map(\.source)
                            + (candidate.content?.evidence.map(\.source) ?? [])
                            + (candidate.meaning?.evidence.map(\.source) ?? [])
                    )).sorted { $0.rawValue < $1.rawValue }
                )
            }
        )

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: fileURL.deletingLastPathComponent().path
            )
            var data = try encoder.encode(record)
            data.append(0x0A)
            guard data.count <= maximumBytes else { return false }
            let existingSize = (try? FileManager.default.attributesOfItem(
                atPath: fileURL.path
            )[.size] as? NSNumber)?.uint64Value ?? 0
            let incomingSize = UInt64(data.count)
            if FileManager.default.fileExists(atPath: fileURL.path),
               existingSize <= UInt64(maximumBytes) - incomingSize
            {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: fileURL, options: .atomic)
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
            return true
        } catch {
            // Feedback must never interfere with the live perception experiment.
            return false
        }
    }
}

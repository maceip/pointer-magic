import Foundation
import PointerCore
import PointerShelfContracts

/// Builds a budgeted `PointerContextPacket` from host-bridged AX, OCR, and scene inputs.
public struct ContextAssembler: Sendable {
    public var minimumOCRConfidence: Float

    public init(minimumOCRConfidence: Float = 0.35) {
        self.minimumOCRConfidence = minimumOCRConfidence
    }

    public func assemble(_ input: ContextAssemblyInput) -> PointerContextPacket {
        let secure = input.semantic?.sensitivityIsSecure == true
        var snippets: [PointerContextSnippet] = []

        if !secure, let selected = trimmed(input.semantic?.textAtPoint), !selected.isEmpty {
            snippets.append(
                PointerContextSnippet(
                    id: "selection-0",
                    text: selected,
                    bounds: input.semantic?.textRangeFrame,
                    provenance: .selection
                )
            )
        }

        if !secure, let label = trimmed(input.semantic?.label), !label.isEmpty {
            snippets.append(
                PointerContextSnippet(
                    id: "ax-label",
                    text: label,
                    bounds: input.semantic?.frame,
                    provenance: .ax
                )
            )
        }

        if !secure, let value = trimmed(input.semantic?.directValue), !value.isEmpty {
            snippets.append(
                PointerContextSnippet(
                    id: "ax-value",
                    text: value,
                    bounds: input.semantic?.frame,
                    provenance: .ax
                )
            )
        }

        if !secure, let perception = input.perception {
            let ranked = perception.observations
                .filter { $0.confidence >= minimumOCRConfidence }
                .sorted { $0.confidence > $1.confidence }
            for (index, observation) in ranked.prefix(6).enumerated() {
                guard let text = trimmed(observation.text), !text.isEmpty else { continue }
                if snippets.contains(where: { $0.text.caseInsensitiveCompare(text) == .orderedSame }) {
                    continue
                }
                snippets.append(
                    PointerContextSnippet(
                        id: "ocr-\(index)",
                        text: text,
                        bounds: observation.bounds,
                        provenance: .ocr
                    )
                )
            }
        }

        let hitTarget: PointerContextHitTarget
        if secure {
            hitTarget = PointerContextHitTarget(
                targetID: input.semantic?.targetID,
                role: input.semantic?.role,
                subrole: input.semantic?.subrole,
                bounds: input.semantic?.frame,
                isEditable: input.semantic?.isEditable
            )
        } else {
            hitTarget = PointerContextHitTarget(
                targetID: input.semantic?.targetID,
                role: input.semantic?.role,
                subrole: input.semantic?.subrole,
                title: trimmed(input.semantic?.label),
                value: trimmed(input.semantic?.directValue),
                selectedText: trimmed(input.semantic?.textAtPoint),
                bounds: input.semantic?.frame ?? input.semantic?.textRangeFrame,
                isEditable: input.semantic?.isEditable
            )
        }

        let appWindow = PointerContextAppWindow(
            bundleIdentifier: input.scene?.bundleIdentifier ?? input.semantic?.bundleIdentifier,
            applicationName: input.scene?.applicationName,
            windowTitle: secure ? nil : input.scene?.windowTitle,
            processID: input.scene?.processID ?? input.semantic?.processID
        )

        let thumb: PointerContextThumbToken?
        if let token = input.perception?.thumbToken {
            thumb = PointerContextThumbToken(
                token: token,
                bounds: input.perception?.cropBounds,
                pixelWidth: input.perception?.pixelWidth,
                pixelHeight: input.perception?.pixelHeight
            )
        } else {
            thumb = nil
        }

        return PointerContextPacket(
            revision: input.revision,
            generation: input.generation,
            sequence: input.sequence,
            assembledAtNs: input.assembledAtNs,
            point: input.point,
            displayID: input.displayID,
            freshness: freshness(for: input),
            appWindow: appWindow,
            hitTarget: hitTarget,
            snippets: snippets,
            thumb: thumb
        )
    }

    private func freshness(for input: ContextAssemblyInput) -> PointerContextFreshness {
        let semanticState = input.semantic?.state
        let perceptionState = input.perception?.state
        let sceneStale = input.scene?.isStale == true

        if semanticState == "unavailable" || semanticState == "failed",
           perceptionState == "unavailable" || perceptionState == "failed" || perceptionState == nil
        {
            return .stale
        }

        if sceneStale
            || semanticState == "partial"
            || semanticState == "cached"
            || perceptionState == "partial"
        {
            return .partial
        }

        if semanticState == "fresh" || perceptionState == "fresh" || semanticState == nil {
            return .current
        }

        return .partial
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let collapsed = value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }
}

@preconcurrency import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
@preconcurrency import Vision

struct VisionAnalysisOutput: Sendable {
    var png: Data?
    var text: [PerceptionTextObservation]
    var classifications: [PerceptionImageClassification]
    var foreground: PerceptionForegroundSummary?
    var diagnostics: [PerceptionDiagnostic]
}

enum VisionImageAnalyzer {
    static func analyze(
        capture: CapturedImage,
        request: VisualPerceptionRequest,
        shouldCancel: @Sendable () -> Bool = { false }
    ) -> VisionAnalysisOutput {
        let image = capture.image
        let globalRect = capture.globalRect
        var output = VisionAnalysisOutput(
            png: nil,
            text: [],
            classifications: [],
            foreground: nil,
            diagnostics: []
        )

        if request.includeCropPNG, !shouldCancel() {
            do {
                output.png = try encodePNG(image)
            } catch {
                output.diagnostics.append(
                    PerceptionDiagnostic(stage: .cropEncoding, message: error.localizedDescription)
                )
            }
        }

        if !shouldCancel() {
            do {
                output.text = try recognizeText(
                    in: image,
                    globalRect: globalRect,
                    level: request.textRecognitionLevel
                )
            } catch {
                output.diagnostics.append(
                    PerceptionDiagnostic(stage: .textRecognition, message: error.localizedDescription)
                )
            }
        }

        if request.includeImageClassifications, !shouldCancel() {
            do {
                output.classifications = try classify(
                    image,
                    maximumCount: request.maximumClassificationCount,
                    minimumConfidence: request.minimumClassificationConfidence
                )
            } catch {
                output.diagnostics.append(
                    PerceptionDiagnostic(stage: .imageClassification, message: error.localizedDescription)
                )
            }
        }

        if request.includeForegroundSummary, !shouldCancel() {
            do {
                output.foreground = try foregroundSummary(image)
            } catch {
                output.diagnostics.append(
                    PerceptionDiagnostic(stage: .foregroundSegmentation, message: error.localizedDescription)
                )
            }
        }

        return output
    }

    private static func recognizeText(
        in image: CGImage,
        globalRect: CGRect,
        level: PerceptionTextRecognitionLevel
    ) throws -> [PerceptionTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level == .fast ? .fast : .accurate
        request.usesLanguageCorrection = level == .accurate
        request.automaticallyDetectsLanguage = true
        request.minimumTextHeight = 0.008

        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        try handler.perform([request])

        return (request.results ?? []).compactMap { observation in
            let candidates = observation.topCandidates(3)
            guard let top = candidates.first else { return nil }
            let normalized = observation.boundingBox
            let quartz = quartzGlobalRect(fromVisionRect: normalized, crop: globalRect)
            return PerceptionTextObservation(
                text: top.string,
                confidence: top.confidence,
                normalizedBounds: perceptionRect(normalized),
                globalBounds: perceptionRect(quartz),
                alternateCandidates: candidates.dropFirst().map {
                    RecognizedTextCandidate(text: $0.string, confidence: $0.confidence)
                }
            )
        }
        .sorted {
            if abs($0.globalBounds.minY - $1.globalBounds.minY) > 3 {
                return $0.globalBounds.minY < $1.globalBounds.minY
            }
            return $0.globalBounds.minX < $1.globalBounds.minX
        }
    }

    private static func classify(
        _ image: CGImage,
        maximumCount: Int,
        minimumConfidence: Float
    ) throws -> [PerceptionImageClassification] {
        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        try handler.perform([request])

        let count = min(max(maximumCount, 0), 32)
        let threshold = min(max(minimumConfidence, 0), 1)
        return (request.results ?? [])
            .filter { $0.confidence >= threshold }
            .prefix(count)
            .map {
                PerceptionImageClassification(
                    identifier: $0.identifier,
                    confidence: $0.confidence
                )
            }
    }

    private static func foregroundSummary(_ image: CGImage) throws -> PerceptionForegroundSummary? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first else { return nil }
        let mask = observation.instanceMask
        return PerceptionForegroundSummary(
            salientInstanceCount: observation.allInstances.count,
            maskPixelWidth: CVPixelBufferGetWidth(mask),
            maskPixelHeight: CVPixelBufferGetHeight(mask)
        )
    }

    private static func encodePNG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw PerceptionEncodingError.destinationCreationFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw PerceptionEncodingError.finalizationFailed
        }
        return data as Data
    }

    private static func quartzGlobalRect(fromVisionRect rect: CGRect, crop: CGRect) -> CGRect {
        CGRect(
            x: crop.minX + rect.minX * crop.width,
            y: crop.minY + (1 - rect.maxY) * crop.height,
            width: rect.width * crop.width,
            height: rect.height * crop.height
        )
    }

    private static func perceptionRect(_ rect: CGRect) -> PerceptionRect {
        PerceptionRect(
            x: rect.origin.x,
            y: rect.origin.y,
            width: rect.width,
            height: rect.height
        )
    }
}

private enum PerceptionEncodingError: LocalizedError {
    case destinationCreationFailed
    case finalizationFailed

    var errorDescription: String? {
        switch self {
        case .destinationCreationFailed:
            "Could not create a PNG image destination."
        case .finalizationFailed:
            "Could not finalize the PNG crop."
        }
    }
}

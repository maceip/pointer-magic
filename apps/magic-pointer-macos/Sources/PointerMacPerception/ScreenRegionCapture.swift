@preconcurrency import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

final class CapturedImage: @unchecked Sendable {
    let image: CGImage
    let globalRect: CGRect
    let path: PerceptionCapturePath

    init(image: CGImage, globalRect: CGRect, path: PerceptionCapturePath) {
        self.image = image
        self.globalRect = globalRect
        self.path = path
    }
}

enum RegionCaptureOutcome: @unchecked Sendable {
    case success(CapturedImage)
    case failure(VisualPerceptionFailure, String)
}

final class ScreenRegionCapture: @unchecked Sendable {
    typealias Completion = @Sendable (RegionCaptureOutcome) -> Void

    func capture(
        point: CGPoint,
        requestedSize: CGSize,
        excludeCurrentApplication: Bool,
        completion: @escaping Completion
    ) {
        guard requestedSize.width.isFinite,
              requestedSize.height.isFinite,
              requestedSize.width > 0,
              requestedSize.height > 0
        else {
            completion(.failure(.invalidCropSize, "Crop width and height must be finite and positive."))
            return
        }

        guard CGPreflightScreenCaptureAccess() else {
            completion(
                .failure(
                    .screenRecordingPermissionDenied,
                    "Screen Recording permission has not been granted. The perception engine does not request it implicitly."
                )
            )
            return
        }

        let safeSize = CGSize(
            width: min(max(requestedSize.width, 1), 1_024),
            height: min(max(requestedSize.height, 1), 1_024)
        )
        let requestedRect = CGRect(
            x: point.x - safeSize.width / 2,
            y: point.y - safeSize.height / 2,
            width: safeSize.width,
            height: safeSize.height
        )
        var displayID: CGDirectDisplayID = 0
        var displayCount: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &displayID, &displayCount) == .success,
              displayCount == 1
        else {
            completion(.failure(.pointOutsideDisplays, "The crop center is not inside an active display."))
            return
        }
        let boundedRect = requestedRect.intersection(CGDisplayBounds(displayID))
        guard !boundedRect.isNull, boundedRect.width >= 1, boundedRect.height >= 1 else {
            completion(.failure(.pointOutsideDisplays, "The crop does not intersect an active display."))
            return
        }

        if excludeCurrentApplication {
            captureDisplayFallback(
                point: point,
                rect: boundedRect,
                excludeCurrentApplication: true,
                completion: completion
            )
        } else if #available(macOS 26.0, *) {
            captureConfiguredDisplayAgnostic(rect: boundedRect, completion: completion)
        } else if #available(macOS 15.2, *) {
            captureDisplayAgnostic(rect: boundedRect, completion: completion)
        } else {
            captureDisplayFallback(
                point: point,
                rect: boundedRect,
                excludeCurrentApplication: false,
                completion: completion
            )
        }
    }

    @available(macOS 26.0, *)
    private func captureConfiguredDisplayAgnostic(
        rect: CGRect,
        completion: @escaping Completion
    ) {
        let configuration = SCScreenshotConfiguration()
        configuration.showsCursor = false
        configuration.dynamicRange = .sdr

        SCScreenshotManager.captureScreenshot(
            rect: rect,
            configuration: configuration
        ) { output, error in
            if let image = output?.sdrImage {
                completion(
                    .success(
                        CapturedImage(
                            image: image,
                            globalRect: rect,
                            path: .screenCaptureKitConfiguredRegion
                        )
                    )
                )
                return
            }

            completion(
                .failure(
                    Self.failure(for: error),
                    error?.localizedDescription ?? "ScreenCaptureKit returned no SDR image."
                )
            )
        }
    }

    @available(macOS 15.2, *)
    private func captureDisplayAgnostic(rect: CGRect, completion: @escaping Completion) {
        // This is the public display-agnostic, bounded ScreenCaptureKit API. Despite
        // being prominent in the macOS 26 SDK, it is available back to macOS 15.2.
        SCScreenshotManager.captureImage(in: rect) { image, error in
            if let image {
                completion(
                    .success(
                        CapturedImage(
                            image: image,
                            globalRect: rect,
                            path: .screenCaptureKitRegion
                        )
                    )
                )
                return
            }

            completion(
                .failure(
                    Self.failure(for: error),
                    error?.localizedDescription ?? "ScreenCaptureKit returned no image."
                )
            )
        }
    }

    private func captureDisplayFallback(
        point: CGPoint,
        rect: CGRect,
        excludeCurrentApplication: Bool,
        completion: @escaping Completion
    ) {
        SCShareableContent.getExcludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        ) { content, error in
            guard let content else {
                completion(
                    .failure(
                        Self.failure(for: error),
                        error?.localizedDescription ?? "ScreenCaptureKit shareable content is unavailable."
                    )
                )
                return
            }

            guard let display = content.displays.first(where: { $0.frame.contains(point) }) else {
                completion(.failure(.pointOutsideDisplays, "The pointer is not inside a capturable display."))
                return
            }

            let boundedRect = rect.intersection(display.frame)
            guard !boundedRect.isNull, boundedRect.width >= 1, boundedRect.height >= 1 else {
                completion(.failure(.pointOutsideDisplays, "The crop does not intersect a capturable display."))
                return
            }

            let excludedApplications = excludeCurrentApplication
                ? content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                : []
            if excludeCurrentApplication, excludedApplications.isEmpty {
                completion(
                    .failure(
                        .captureUnavailable,
                        "Magic Pointer could not exclude its own panel from the frozen crop."
                    )
                )
                return
            }
            let filter = SCContentFilter(
                display: display,
                excludingApplications: excludedApplications,
                exceptingWindows: []
            )
            let configuration = SCStreamConfiguration()
            configuration.showsCursor = false
            configuration.capturesAudio = false
            configuration.sourceRect = CGRect(
                x: boundedRect.minX - display.frame.minX,
                y: boundedRect.minY - display.frame.minY,
                width: boundedRect.width,
                height: boundedRect.height
            )

            let pixelScale = max(
                1,
                CGFloat(CGDisplayPixelsWide(display.displayID)) / max(display.frame.width, 1)
            )
            configuration.width = max(1, Int((boundedRect.width * pixelScale).rounded()))
            configuration.height = max(1, Int((boundedRect.height * pixelScale).rounded()))

            SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            ) { image, captureError in
                if let image {
                    completion(
                        .success(
                            CapturedImage(
                                image: image,
                                globalRect: boundedRect,
                                path: .screenCaptureKitDisplayFallback
                            )
                        )
                    )
                    return
                }

                completion(
                    .failure(
                        Self.failure(for: captureError),
                        captureError?.localizedDescription ?? "ScreenCaptureKit returned no image."
                    )
                )
            }
        }
    }

    private static func failure(for error: Error?) -> VisualPerceptionFailure {
        guard let error = error as NSError? else { return .captureFailed }
        if error.domain == SCStreamErrorDomain,
           error.code == SCStreamError.Code.userDeclined.rawValue
        {
            return .screenRecordingPermissionDenied
        }
        return .captureFailed
    }
}

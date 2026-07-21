import Foundation
@testable import PointerMacSceneDiscovery
import PointerSceneContracts
import Testing

@Suite("screen dirty-region normalization")
struct ScreenDirtyRegionNormalizationTests {
    @Test("pixel metadata maps through the exact shared virtual desktop revision")
    func exactRevisionMapping() throws {
        let fixture = try makeSnapshot()
        let frame = ScreenDirtyRegionFrame(
            displayID: 41,
            topologyRevision: fixture.topologyRevision,
            outputWidth: 100,
            outputHeight: 50,
            dirtyRects: [try #require(ScreenDirtyPixelRect(
                x: 10,
                y: 5,
                width: 20,
                height: 10
            ))]
        )

        let result = try ScreenDirtyRegionNormalizer.normalize(
            frame,
            through: fixture
        )
        let region = try #require(result.regions.first)
        #expect(result.regions.count == 1)
        #expect(region.coordinateSpace == fixture.virtualDesktop.descriptor.coordinateSpace)
        #expect(region.rect.origin.x == 20)
        #expect(region.rect.origin.y == 10)
        #expect(region.rect.size.width == 40)
        #expect(region.rect.size.height == 20)
    }

    @Test("clipping and adjacency coalescing remain conservative and bounded")
    func clippingAndCoalescing() throws {
        let snapshot = try makeSnapshot()
        let rects = [
            try #require(ScreenDirtyPixelRect(x: -10, y: -10, width: 30, height: 30)),
            try #require(ScreenDirtyPixelRect(x: 19, y: 19, width: 10, height: 10)),
            try #require(ScreenDirtyPixelRect(x: 80, y: 40, width: 30, height: 20)),
        ]
        let result = try ScreenDirtyRegionNormalizer.normalize(
            ScreenDirtyRegionFrame(
                displayID: 41,
                topologyRevision: snapshot.topologyRevision,
                outputWidth: 100,
                outputHeight: 50,
                dirtyRects: rects
            ),
            through: snapshot
        )

        #expect(result.acceptedInputRectCount == 3)
        #expect(result.didCoalesce)
        #expect(result.regions.count == 2)
        #expect(result.regions.allSatisfy { region in
            region.rect.origin.x >= 0 && region.rect.origin.y >= 0 &&
                region.rect.origin.x + region.rect.size.width <= 200 &&
                region.rect.origin.y + region.rect.size.height <= 100
        })
    }

    @Test("callback truncation and output-budget overflow fail closed")
    func overflowFailsClosed() throws {
        let snapshot = try makeSnapshot()
        let unit = try #require(ScreenDirtyPixelRect(x: 1, y: 1, width: 1, height: 1))
        let truncated = ScreenDirtyRegionFrame(
            displayID: 41,
            topologyRevision: snapshot.topologyRevision,
            outputWidth: 100,
            outputHeight: 50,
            dirtyRects: [unit],
            didTruncateInput: true
        )
        #expect(throws: ScreenDirtyRegionNormalizationError.callbackMetadataOverflow) {
            try ScreenDirtyRegionNormalizer.normalize(truncated, through: snapshot)
        }

        let separated = [
            try #require(ScreenDirtyPixelRect(x: 1, y: 1, width: 1, height: 1)),
            try #require(ScreenDirtyPixelRect(x: 20, y: 20, width: 1, height: 1)),
            try #require(ScreenDirtyPixelRect(x: 40, y: 40, width: 1, height: 1)),
        ]
        #expect(throws: ScreenDirtyRegionNormalizationError.outputRegionBudgetExceeded(limit: 2)) {
            try ScreenDirtyRegionNormalizer.normalize(
                ScreenDirtyRegionFrame(
                    displayID: 41,
                    topologyRevision: snapshot.topologyRevision,
                    outputWidth: 100,
                    outputHeight: 50,
                    dirtyRects: separated
                ),
                through: snapshot,
                policy: ScreenDirtyRegionNormalizationPolicy(
                    maximumInputRects: 8,
                    maximumOutputRegions: 2
                )
            )
        }
    }

    @Test("caller budgets clamp to hard maxima and overflow remains conservative")
    func configurableBudgetsAreHardClamped() throws {
        let snapshot = try makeSnapshot()
        let policy = ScreenDirtyRegionNormalizationPolicy(
            maximumInputRects: .max,
            maximumOutputRegions: .max
        )
        #expect(policy.maximumInputRects ==
            ScreenDirtyRegionNormalizationPolicy.hardMaximumInputRects)
        #expect(policy.maximumOutputRegions ==
            ScreenDirtyRegionNormalizationPolicy.hardMaximumOutputRegions)
        #expect(ScreenDirtyRegionCallbackBudget.clampedMaximumRectsPerFrame(.max) ==
            ScreenDirtyRegionNormalizationPolicy.hardMaximumInputRects)

        let unit = try #require(ScreenDirtyPixelRect(x: 1, y: 1, width: 1, height: 1))
        let oversizedInput = Array(
            repeating: unit,
            count: ScreenDirtyRegionNormalizationPolicy.hardMaximumInputRects + 1
        )
        #expect(throws: ScreenDirtyRegionNormalizationError.callbackMetadataOverflow) {
            try ScreenDirtyRegionNormalizer.normalize(
                ScreenDirtyRegionFrame(
                    displayID: 41,
                    topologyRevision: snapshot.topologyRevision,
                    outputWidth: 100,
                    outputHeight: 50,
                    dirtyRects: oversizedInput
                ),
                through: snapshot,
                policy: policy
            )
        }

        let separated = (0 ... ScreenDirtyRegionNormalizationPolicy.hardMaximumOutputRegions)
            .compactMap { index in
                ScreenDirtyPixelRect(
                    x: Double(index * 5),
                    y: 1,
                    width: 1,
                    height: 1
                )
            }
        #expect(separated.count ==
            ScreenDirtyRegionNormalizationPolicy.hardMaximumOutputRegions + 1)
        #expect(throws: ScreenDirtyRegionNormalizationError.outputRegionBudgetExceeded(
            limit: ScreenDirtyRegionNormalizationPolicy.hardMaximumOutputRegions
        )) {
            try ScreenDirtyRegionNormalizer.normalize(
                ScreenDirtyRegionFrame(
                    displayID: 41,
                    topologyRevision: snapshot.topologyRevision,
                    outputWidth: 100,
                    outputHeight: 50,
                    dirtyRects: separated
                ),
                through: snapshot,
                policy: policy
            )
        }
    }

    @Test("a frame cannot be remapped through a different topology revision")
    func revisionMismatchFailsClosed() throws {
        let snapshot = try makeSnapshot()
        let rect = try #require(ScreenDirtyPixelRect(x: 1, y: 1, width: 2, height: 2))
        #expect(throws: ScreenDirtyRegionNormalizationError.coordinateRevisionMismatch(
            expected: snapshot.topologyRevision,
            actual: snapshot.topologyRevision + 1
        )) {
            try ScreenDirtyRegionNormalizer.normalize(
                ScreenDirtyRegionFrame(
                    displayID: 41,
                    topologyRevision: snapshot.topologyRevision + 1,
                    outputWidth: 100,
                    outputHeight: 50,
                    dirtyRects: [rect]
                ),
                through: snapshot
            )
        }
    }

    private func makeSnapshot() throws -> MacDesktopCoordinateSnapshot {
        let registry = MacDesktopCoordinateRegistry(device: DevicePrincipalID())
        return try registry.update(with: [
            MacDisplaySnapshot(
                displayID: 41,
                displayUUID: UUID(uuidString: "00000000-0000-0000-0000-000000000041"),
                globalBounds: try #require(MacGlobalRect(
                    x: -100,
                    y: 50,
                    width: 200,
                    height: 100
                )),
                pixelWidth: 400,
                pixelHeight: 200,
                rotationQuarterTurns: 0,
                scaleFactor: 2,
                isMain: true
            ),
        ])
    }
}

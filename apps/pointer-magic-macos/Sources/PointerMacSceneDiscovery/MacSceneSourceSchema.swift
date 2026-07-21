import PointerSceneContracts

/// Closed local schemas used both to authorize ingestion and to scope broad
/// source invalidations. Keeping these beside the producers prevents lifecycle
/// orchestration from becoming a source-of-truth for observation fields.
enum MacSceneSourceSchema {
    static func kind(for role: MacSceneDiscoverySourceRole) -> SceneSourceKind {
        switch role {
        case .workspace: .windowMetadata
        case .accessibility: .accessibility
        case .screenDirtyRegions: .screenPixels
        }
    }

    static func capabilities(
        for role: MacSceneDiscoverySourceRole
    ) -> Set<SceneSourceCapability> {
        switch role {
        case .workspace:
            [
                .applicationLifecycle,
                .windowTopology,
                .geometry,
                .coverageReporting,
                .onDemandRefresh,
                .checkpoints,
            ]
        case .accessibility:
            [
                .structuredHierarchy,
                .geometry,
                .sensitivityClassification,
                .coverageReporting,
                .onDemandRefresh,
                .checkpoints,
            ]
        case .screenDirtyRegions:
            [
                .dirtyRegions,
                .coverageReporting,
                .onDemandRefresh,
                .checkpoints,
            ]
        }
    }

    static func evidenceKinds(
        for role: MacSceneDiscoverySourceRole
    ) -> Set<SceneEvidenceKind> {
        switch role {
        case .workspace: [.windowMetadata]
        case .accessibility: [.accessibility]
        case .screenDirtyRegions: [.screenPixels]
        }
    }

    static func fields(
        for role: MacSceneDiscoverySourceRole
    ) -> Set<SceneFieldKey> {
        switch role {
        case .workspace: workspaceFields
        case .accessibility: accessibilityFields
        case .screenDirtyRegions: screenDirtyRegionFields
        }
    }

    static let workspaceFields: Set<SceneFieldKey> = sceneFields([
        "object.kind",
        "geometry.bounds",
        "display.id",
        "display.isMain",
        "display.pixelWidth",
        "display.pixelHeight",
        "display.rotationQuarterTurns",
        "display.scaleFactor",
        "display.surfaceID",
        "application.pid",
        "application.bundleIdentifier",
        "application.name",
        "application.isActive",
        "application.isHidden",
        "window.id",
        "window.layer",
        "window.alpha",
        "window.isOnScreen",
        "window.sharingState",
        "window.frontToBackIndex",
    ])

    static let accessibilityFields: Set<SceneFieldKey> = sceneFields([
        "object.kind",
        "application.pid",
        "accessibility.role",
        "accessibility.subrole",
        "accessibility.content",
        "geometry.bounds",
    ])

    static let screenDirtyRegionFields: Set<SceneFieldKey> = sceneFields([
        "object.kind",
        "display.id",
        "screen.dirtyDisplayBounds",
        "screen.dirtyRevision",
    ])

    static let objectKindField = try! SceneFieldKey("object.kind")
    static let geometryBoundsField = try! SceneFieldKey("geometry.bounds")
    static let displayIDField = try! SceneFieldKey("display.id")
    static let screenDirtyDisplayBoundsField = try! SceneFieldKey(
        "screen.dirtyDisplayBounds"
    )
    static let screenDirtyRevisionField = try! SceneFieldKey("screen.dirtyRevision")

    private static func sceneFields(_ names: [String]) -> Set<SceneFieldKey> {
        Set(names.map { try! SceneFieldKey($0) })
    }
}

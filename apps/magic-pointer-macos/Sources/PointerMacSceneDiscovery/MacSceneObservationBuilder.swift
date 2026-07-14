import Foundation
import PointerSceneContracts

public enum MacSceneObservationBuilderError: Error, Equatable, Sendable {
    case observationLimitExceeded(actual: Int, maximum: Int)
    case coordinateDeviceMismatch
    case coordinateDisplaySetMismatch
}

public struct MacSceneObservationBuilder: Sendable {
    public let device: DevicePrincipalID
    public let sourceEpoch: SceneSourceEpoch
    private let identityRegistry: MacSceneIdentityRegistry

    public init(device: DevicePrincipalID, sourceEpoch: SceneSourceEpoch) {
        self.device = device
        self.sourceEpoch = sourceEpoch
        self.identityRegistry = MacSceneIdentityRegistry()
    }

    public func makeCheckpoint(
        from census: MacDesktopCensus,
        coordinateSnapshot: MacDesktopCoordinateSnapshot,
        observedAtSourceMonotonicNs: UInt64
    ) throws -> SceneCheckpoint {
        guard coordinateSnapshot.device == device else {
            throw MacSceneObservationBuilderError.coordinateDeviceMismatch
        }
        guard Set(coordinateSnapshot.displayMappings.map(\.display)) == Set(census.displays) else {
            throw MacSceneObservationBuilderError.coordinateDisplaySetMismatch
        }
        let displayMappings = Dictionary(
            uniqueKeysWithValues: coordinateSnapshot.displayMappings.map {
                ($0.display.displayID, $0)
            }
        )

        let maximumObservationCount = 1 + census.displays.count +
            census.applications.count + census.windows.count
        guard maximumObservationCount <= 500 else {
            throw MacSceneObservationBuilderError.observationLimitExceeded(
                actual: maximumObservationCount,
                maximum: 500
            )
        }

        return try identityRegistry.withReconciledIdentities(for: census) { identities in
            try checkpoint(
                census: census,
                coordinateSnapshot: coordinateSnapshot,
                displayMappings: displayMappings,
                identities: identities,
                observedAt: observedAtSourceMonotonicNs
            )
        }
    }

    private func checkpoint(
        census: MacDesktopCensus,
        coordinateSnapshot: MacDesktopCoordinateSnapshot,
        displayMappings: [UInt32: MacDesktopCoordinateMapper.DisplayMapping],
        identities: MacSceneIdentitySnapshot,
        observedAt: UInt64
    ) throws -> SceneCheckpoint {
        var observations: [SceneObservation] = []
        observations.reserveCapacity(
            1 + census.displays.count + census.applications.count + census.windows.count
        )
        observations.append(try virtualDesktopObservation(
            coordinateSnapshot.virtualDesktop,
            observedAt: observedAt
        ))

        for display in census.displays {
            guard let mapping = displayMappings[display.displayID],
                  let virtualRegion = coordinateSnapshot.mapQuartzGlobalRect(
                      display.globalBounds
                  )
            else {
                continue
            }
            observations.append(try displayObservation(
                display,
                mapping: mapping,
                virtualRegion: virtualRegion,
                observedAt: observedAt
            ))
        }

        let applications = census.applications.sorted { $0.processID < $1.processID }
        let applicationPIDs = Set(applications.map(\.processID))
        for application in applications {
            guard let objectID = identities.applicationObjectID(
                processID: application.processID
            ) else {
                continue
            }
            observations.append(try applicationObservation(
                application,
                objectID: objectID,
                observedAt: observedAt
            ))
        }

        for window in census.windows {
            // Every window uses the one virtual-desktop logical surface. A window that
            // crosses physical displays therefore remains a complete spatial object.
            guard let region = coordinateSnapshot.mapQuartzGlobalRect(window.globalBounds),
                  let objectID = identities.windowObjectID(for: window),
                  let ownerObjectID = identities.applicationObjectID(
                      processID: window.ownerProcessID
                  )
            else {
                continue
            }
            observations.append(try windowObservation(
                window,
                objectID: objectID,
                mappedRegion: region,
                parentApplicationObjectID: applicationPIDs.contains(window.ownerProcessID)
                    ? ownerObjectID
                    : nil,
                observedAt: observedAt
            ))
        }
        return try SceneCheckpoint(observations: observations)
    }

    private func virtualDesktopObservation(
        _ mapping: MacDesktopCoordinateMapper.VirtualDesktopMapping,
        observedAt: UInt64
    ) throws -> SceneObservation {
        let fullBounds = try SceneRect(
            x: 0,
            y: 0,
            width: mapping.globalBounds.width,
            height: mapping.globalBounds.height
        )
        return try SceneObservation(
            subject: virtualDesktopKey(),
            observedAtSourceMonotonicNs: observedAt,
            claims: [
                try claim(.objectKind, .text("virtualDesktop")),
                try claim(.displaySurfaceID, .digest(mapping.surface.surfaceID.description)),
                try claim(
                    .geometryBounds,
                    .region(SurfaceRegion(
                        coordinateSpace: mapping.descriptor.coordinateSpace,
                        rect: fullBounds
                    ))
                ),
            ]
        )
    }

    private func displayObservation(
        _ display: MacDisplaySnapshot,
        mapping: MacDesktopCoordinateMapper.DisplayMapping,
        virtualRegion: SurfaceRegion,
        observedAt: UInt64
    ) throws -> SceneObservation {
        return try SceneObservation(
            subject: objectKey(SceneStableIdentifiers.workspaceDisplay(
                surface: mapping.surface,
                device: device
            )),
            parent: virtualDesktopKey(),
            observedAtSourceMonotonicNs: observedAt,
            claims: [
                try claim(.objectKind, .text("display")),
                try claim(.displayID, .unsignedInteger(UInt64(display.displayID))),
                try claim(.displayIsMain, .boolean(display.isMain)),
                try claim(.displayPixelWidth, .unsignedInteger(UInt64(display.pixelWidth))),
                try claim(.displayPixelHeight, .unsignedInteger(UInt64(display.pixelHeight))),
                try claim(
                    .displayRotationQuarterTurns,
                    .unsignedInteger(UInt64(display.rotationQuarterTurns))
                ),
                try claim(.displayScaleFactor, .number(display.scaleFactor)),
                try claim(.displaySurfaceID, .digest(mapping.surface.surfaceID.description)),
                try claim(
                    .geometryBounds,
                    .region(virtualRegion)
                ),
            ]
        )
    }

    private func applicationObservation(
        _ application: MacApplicationSnapshot,
        objectID: SourceObjectID,
        observedAt: UInt64
    ) throws -> SceneObservation {
        var claims = [
            try claim(.objectKind, .text("application")),
            try claim(.applicationPID, .signedInteger(Int64(application.processID))),
            try claim(.applicationIsActive, .boolean(application.isActive)),
            try claim(.applicationIsHidden, .boolean(application.isHidden)),
        ]
        if let bundleIdentifier = application.bundleIdentifier {
            claims.append(try claim(.applicationBundleIdentifier, .text(bundleIdentifier)))
        }
        if let localizedName = application.localizedName {
            claims.append(try claim(.applicationName, .text(localizedName)))
        }
        return try SceneObservation(
            subject: objectKey(objectID),
            observedAtSourceMonotonicNs: observedAt,
            claims: claims
        )
    }

    private func windowObservation(
        _ window: MacWindowSnapshot,
        objectID: SourceObjectID,
        mappedRegion: SurfaceRegion,
        parentApplicationObjectID: SourceObjectID?,
        observedAt: UInt64
    ) throws -> SceneObservation {
        var claims = [
            try claim(.objectKind, .text("window")),
            try claim(.windowID, .unsignedInteger(UInt64(window.windowID))),
            try claim(.applicationPID, .signedInteger(Int64(window.ownerProcessID))),
            try claim(.windowLayer, .signedInteger(Int64(window.layer))),
            try claim(.windowAlpha, .number(window.alpha)),
            try claim(.windowIsOnScreen, .boolean(window.isOnScreen)),
            try claim(.windowFrontToBackIndex, .unsignedInteger(UInt64(window.frontToBackIndex))),
            try claim(.geometryBounds, .region(mappedRegion)),
        ]
        if let sharingState = window.sharingState {
            claims.append(try claim(.windowSharingState, .unsignedInteger(UInt64(sharingState))))
        }
        if let ownerName = window.ownerName {
            claims.append(try claim(.applicationName, .text(ownerName)))
        }
        return try SceneObservation(
            subject: objectKey(objectID),
            parent: parentApplicationObjectID.map(objectKey),
            observedAtSourceMonotonicNs: observedAt,
            claims: claims
        )
    }

    private func virtualDesktopKey() -> SourceObjectKey {
        objectKey(kind: 0x5644_4553, value: 0)
    }

    private func objectKey(kind: UInt32, value: UInt64) -> SourceObjectKey {
        SourceObjectKey(
            sourceEpoch: sourceEpoch,
            objectID: SceneStableIdentifiers.object(kind: kind, value: value)
        )
    }

    private func objectKey(_ objectID: SourceObjectID) -> SourceObjectKey {
        SourceObjectKey(sourceEpoch: sourceEpoch, objectID: objectID)
    }

    private func claim(
        _ field: MacSceneField,
        _ value: SceneFieldValue,
        sensitivity: SceneDataSensitivity = .ordinary
    ) throws -> SceneFieldClaim {
        try SceneFieldClaim(
            field: field.key,
            value: value,
            knowledge: .observed,
            confidence: 1,
            sensitivity: sensitivity,
            evidence: [try SceneEvidence(kind: .windowMetadata)]
        )
    }
}

private enum MacSceneField: String {
    case objectKind = "object.kind"
    case geometryBounds = "geometry.bounds"
    case displayID = "display.id"
    case displayIsMain = "display.isMain"
    case displayPixelWidth = "display.pixelWidth"
    case displayPixelHeight = "display.pixelHeight"
    case displayRotationQuarterTurns = "display.rotationQuarterTurns"
    case displayScaleFactor = "display.scaleFactor"
    case displaySurfaceID = "display.surfaceID"
    case applicationPID = "application.pid"
    case applicationBundleIdentifier = "application.bundleIdentifier"
    case applicationName = "application.name"
    case applicationIsActive = "application.isActive"
    case applicationIsHidden = "application.isHidden"
    case windowID = "window.id"
    case windowLayer = "window.layer"
    case windowAlpha = "window.alpha"
    case windowIsOnScreen = "window.isOnScreen"
    case windowSharingState = "window.sharingState"
    case windowFrontToBackIndex = "window.frontToBackIndex"

    var key: SceneFieldKey { try! SceneFieldKey(rawValue) }
}

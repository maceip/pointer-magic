import Foundation
import PointerSceneContracts

struct MacWindowIncarnationKey: Hashable, Sendable {
    let ownerApplicationObjectID: SourceObjectID
    let windowID: UInt32
}

struct MacSceneIdentitySnapshot: Sendable {
    let applicationObjectIDs: [Int32: SourceObjectID]
    let windowObjectIDs: [MacWindowIncarnationKey: SourceObjectID]

    func applicationObjectID(processID: Int32) -> SourceObjectID? {
        applicationObjectIDs[processID]
    }

    func windowObjectID(for window: MacWindowSnapshot) -> SourceObjectID? {
        guard let owner = applicationObjectIDs[window.ownerProcessID] else { return nil }
        return windowObjectIDs[MacWindowIncarnationKey(
            ownerApplicationObjectID: owner,
            windowID: window.windowID
        )]
    }
}

/// Source-epoch-local identity authority for workspace applications and windows.
/// A public launch date distinguishes PID reuse when available. Without it, only
/// an observed absence can prove a new application incarnation. A window is scoped
/// to that application incarnation and is retired as soon as a complete census no
/// longer contains it.
///
/// Public CGWindow metadata cannot prove that a window was destroyed and its numeric
/// ID reused between two otherwise continuous censuses. This registry deliberately
/// does not reach for private AXWindowNumber, CGS, or SLS APIs to fill that gap.
final class MacSceneIdentityRegistry: @unchecked Sendable {
    private struct ApplicationState: Sendable {
        let launchDate: Date?
        let objectID: SourceObjectID
    }

    private struct ApplicationMarker: Sendable {
        let launchDate: Date?
    }

    private let lock = NSLock()
    private var applications: [Int32: ApplicationState] = [:]
    private var windows: [MacWindowIncarnationKey: SourceObjectID] = [:]

    /// Candidate state commits only if checkpoint construction succeeds. A failed
    /// checkpoint therefore cannot advance source identity behind the event stream.
    func withReconciledIdentities<Result>(
        for census: MacDesktopCensus,
        _ body: (MacSceneIdentitySnapshot) throws -> Result
    ) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }

        let applicationMarkers = canonicalApplicationMarkers(census.applications)
        let presentProcessIDs = Set(applicationMarkers.keys).union(
            census.windows.lazy.map(\.ownerProcessID)
        )
        var candidateApplications: [Int32: ApplicationState] = [:]
        candidateApplications.reserveCapacity(presentProcessIDs.count)

        for processID in presentProcessIDs.sorted() where processID > 0 {
            let launchDate: Date?
            if let marker = applicationMarkers[processID] {
                launchDate = marker.launchDate
            } else {
                // A window owner can fall outside the bounded application list.
                // Preserve its last public marker rather than inventing a restart.
                launchDate = applications[processID]?.launchDate
            }
            if let existing = applications[processID],
               existing.launchDate == launchDate
            {
                candidateApplications[processID] = existing
            } else {
                candidateApplications[processID] = ApplicationState(
                    launchDate: launchDate,
                    objectID: SourceObjectID()
                )
            }
        }

        var candidateWindows: [MacWindowIncarnationKey: SourceObjectID] = [:]
        candidateWindows.reserveCapacity(census.windows.count)
        for window in census.windows {
            guard let owner = candidateApplications[window.ownerProcessID]?.objectID else {
                continue
            }
            let key = MacWindowIncarnationKey(
                ownerApplicationObjectID: owner,
                windowID: window.windowID
            )
            candidateWindows[key] = candidateWindows[key] ?? windows[key] ?? SourceObjectID()
        }

        let snapshot = MacSceneIdentitySnapshot(
            applicationObjectIDs: candidateApplications.mapValues(\.objectID),
            windowObjectIDs: candidateWindows
        )
        let result = try body(snapshot)
        applications = candidateApplications
        windows = candidateWindows
        return result
    }

    private func canonicalApplicationMarkers(
        _ snapshots: [MacApplicationSnapshot]
    ) -> [Int32: ApplicationMarker] {
        var result: [Int32: ApplicationMarker] = [:]
        for snapshot in snapshots.sorted(by: applicationOrder) where snapshot.processID > 0 {
            if result[snapshot.processID] == nil {
                result[snapshot.processID] = ApplicationMarker(
                    launchDate: snapshot.launchDate
                )
            }
        }
        return result
    }

    private func applicationOrder(
        _ lhs: MacApplicationSnapshot,
        _ rhs: MacApplicationSnapshot
    ) -> Bool {
        if lhs.processID != rhs.processID { return lhs.processID < rhs.processID }
        switch (lhs.launchDate, rhs.launchDate) {
        case let (left?, right?) where left != right:
            return left < right
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        default:
            return (lhs.bundleIdentifier ?? "") < (rhs.bundleIdentifier ?? "")
        }
    }
}

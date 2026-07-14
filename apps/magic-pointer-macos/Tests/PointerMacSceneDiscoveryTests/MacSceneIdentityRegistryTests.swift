import Foundation
@testable import PointerMacSceneDiscovery
import PointerSceneContracts
import Testing

@Suite("workspace source-local identity registry")
struct MacSceneIdentityRegistryTests {
    @Test("an unchanged census reuses application and window identities")
    func stableCensusReusesIdentities() throws {
        let registry = MacSceneIdentityRegistry()
        let census = census(
            applications: [application(processID: 101, launchOffset: 1)],
            windows: [window(windowID: 7, ownerProcessID: 101)]
        )

        let first = registry.withReconciledIdentities(for: census) { $0 }
        let second = registry.withReconciledIdentities(for: census) { $0 }

        #expect(try applicationID(in: first, processID: 101) ==
            applicationID(in: second, processID: 101))
        #expect(try windowID(in: first, window: census.windows[0]) ==
            windowID(in: second, window: census.windows[0]))
    }

    @Test("a changed public launch date creates a new process incarnation")
    func processRestartCreatesNewIdentities() throws {
        let registry = MacSceneIdentityRegistry()
        let firstCensus = census(
            applications: [application(processID: 101, launchOffset: 1)],
            windows: [window(windowID: 7, ownerProcessID: 101)]
        )
        let restartedCensus = census(
            applications: [application(processID: 101, launchOffset: 2)],
            windows: [window(windowID: 7, ownerProcessID: 101)]
        )

        let first = registry.withReconciledIdentities(for: firstCensus) { $0 }
        let restarted = registry.withReconciledIdentities(for: restartedCensus) { $0 }

        #expect(try applicationID(in: first, processID: 101) !=
            applicationID(in: restarted, processID: 101))
        #expect(try windowID(in: first, window: firstCensus.windows[0]) !=
            windowID(in: restarted, window: restartedCensus.windows[0]))
    }

    @Test("a numeric window ID moving to another owner creates a new identity")
    func ownerChangeCreatesNewWindowIdentity() throws {
        let registry = MacSceneIdentityRegistry()
        let applications = [
            application(processID: 101, launchOffset: 1),
            application(processID: 202, launchOffset: 1),
        ]
        let firstCensus = census(
            applications: applications,
            windows: [window(windowID: 7, ownerProcessID: 101)]
        )
        let movedCensus = census(
            applications: applications,
            windows: [window(windowID: 7, ownerProcessID: 202)]
        )

        let first = registry.withReconciledIdentities(for: firstCensus) { $0 }
        let moved = registry.withReconciledIdentities(for: movedCensus) { $0 }

        #expect(try applicationID(in: first, processID: 101) ==
            applicationID(in: moved, processID: 101))
        #expect(try applicationID(in: first, processID: 202) ==
            applicationID(in: moved, processID: 202))
        #expect(try windowID(in: first, window: firstCensus.windows[0]) !=
            windowID(in: moved, window: movedCensus.windows[0]))
    }

    @Test("a window gets a new identity after an observed absence")
    func windowReappearanceCreatesNewIdentity() throws {
        let registry = MacSceneIdentityRegistry()
        let application = application(processID: 101, launchOffset: 1)
        let visibleCensus = census(
            applications: [application],
            windows: [window(windowID: 7, ownerProcessID: 101)]
        )

        let first = registry.withReconciledIdentities(for: visibleCensus) { $0 }
        _ = registry.withReconciledIdentities(
            for: census(applications: [application], windows: [])
        ) { $0 }
        let reappeared = registry.withReconciledIdentities(for: visibleCensus) { $0 }

        #expect(try applicationID(in: first, processID: 101) ==
            applicationID(in: reappeared, processID: 101))
        #expect(try windowID(in: first, window: visibleCensus.windows[0]) !=
            windowID(in: reappeared, window: visibleCensus.windows[0]))
    }

    @Test("an application and its windows get new identities after observed absence")
    func applicationReappearanceCreatesNewIdentitiesWithoutLaunchDate() throws {
        let registry = MacSceneIdentityRegistry()
        let visibleCensus = census(
            applications: [application(processID: 101, launchOffset: nil)],
            windows: [window(windowID: 7, ownerProcessID: 101)]
        )

        let first = registry.withReconciledIdentities(for: visibleCensus) { $0 }
        _ = registry.withReconciledIdentities(
            for: census(applications: [], windows: [])
        ) { $0 }
        let reappeared = registry.withReconciledIdentities(for: visibleCensus) { $0 }

        #expect(try applicationID(in: first, processID: 101) !=
            applicationID(in: reappeared, processID: 101))
        #expect(try windowID(in: first, window: visibleCensus.windows[0]) !=
            windowID(in: reappeared, window: visibleCensus.windows[0]))
    }

    private func census(
        applications: [MacApplicationSnapshot],
        windows: [MacWindowSnapshot]
    ) -> MacDesktopCensus {
        MacDesktopCensus(displays: [], applications: applications, windows: windows)
    }

    private func application(
        processID: Int32,
        launchOffset: TimeInterval?
    ) -> MacApplicationSnapshot {
        MacApplicationSnapshot(
            processID: processID,
            bundleIdentifier: "example.\(processID)",
            localizedName: "Example \(processID)",
            isActive: false,
            isHidden: false,
            launchDate: launchOffset.map { Date(timeIntervalSince1970: $0) }
        )
    }

    private func window(
        windowID: UInt32,
        ownerProcessID: Int32
    ) -> MacWindowSnapshot {
        MacWindowSnapshot(
            windowID: windowID,
            ownerProcessID: ownerProcessID,
            ownerName: "Example",
            globalBounds: MacGlobalRect(x: 0, y: 0, width: 100, height: 100)!,
            layer: 0,
            alpha: 1,
            isOnScreen: true,
            sharingState: 1,
            frontToBackIndex: 0
        )
    }

    private func applicationID(
        in snapshot: MacSceneIdentitySnapshot,
        processID: Int32
    ) throws -> SourceObjectID {
        try #require(snapshot.applicationObjectID(processID: processID))
    }

    private func windowID(
        in snapshot: MacSceneIdentitySnapshot,
        window: MacWindowSnapshot
    ) throws -> SourceObjectID {
        try #require(snapshot.windowObjectID(for: window))
    }
}

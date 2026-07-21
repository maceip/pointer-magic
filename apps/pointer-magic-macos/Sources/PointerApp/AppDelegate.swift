@preconcurrency import AppKit
import PointerMagicKit
import PointerAgentContracts
import PointerAgentHost
import PointerAgentShelf
import PointerCore
import PointerMacAgentFocus
import PointerMacPerception
import PointerMacSceneDiscovery
import PointerShelfContracts
import PointerShelfRuntime

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var bedrock: PointerBedrock!
    private var interactionController: PointerMagicInteractionController!
    private var sceneDiscoveryController: MacSceneDiscoveryController!
    private var agentObservationHost: AgentObservationHost!
    private var shelfSession: ShelfSessionCoordinator!
    private var contextShelfHost: ContextShelfHost!
    private var agentFocusController: MacAgentTUIFocusController!
    private var agentShelfTask: Task<Void, Never>?
    private var agentFocusTask: Task<Void, Never>?
    private var shelfInputObservation: PointerInputObservation?
    private var agentByShelfIdentity: [ShelfItemIdentity: AgentProviderSessionIdentity] = [:]
    private var latestShelfDocument: ShelfDocument?
    private var agentSwitchStatus = "Click ✦ to park the shelf"
    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    private var enabled = true
    private var terminationIsDraining = false
    private var terminationReplySent = false
    private var terminationDeadlineTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let configuration = PointerConfiguration(
            semanticPolicy: .onDemand,
            allowPositionOnlyFallback: true,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        bedrock = PointerBedrock(configuration: configuration)
        interactionController = PointerMagicInteractionController(bedrock: bedrock)
        // One process-local device identity and observation session. This is
        // deliberately not persisted; source epochs are recreated on every restart.
        sceneDiscoveryController = MacSceneDiscoveryController()
        agentObservationHost = AgentObservationHost()
        shelfSession = ShelfSessionCoordinator()
        contextShelfHost = ContextShelfHost(
            bedrock: bedrock,
            sceneDiscovery: sceneDiscoveryController
        )
        agentFocusController = MacAgentTUIFocusController()
        wireShelfSession()
        wireContextShelfHost()
        configureStatusItem()

        Task { [weak self] in
            guard let self else { return }
            await startEnabledSystems()
            rebuildMenu()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        agentShelfTask?.cancel()
        agentFocusTask?.cancel()
        removeShelfInputObservation()
        interactionController.stop()
        contextShelfHost?.stop()
        shelfSession.stop()
        bedrock.requestStop()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationIsDraining else { return .terminateLater }
        terminationIsDraining = true
        enabled = false
        agentShelfTask?.cancel()
        agentShelfTask = nil
        agentFocusTask?.cancel()
        agentFocusTask = nil
        removeShelfInputObservation()
        interactionController.stop()
        contextShelfHost?.stop()
        shelfSession.stop()

        // AppKit termination is synchronous, but source coverage and receiver
        // registrations must close before process exit. terminateLater provides
        // that bounded async drain without blocking the main thread.
        Task { [sceneDiscoveryController, agentObservationHost, bedrock] in
            async let sceneStop = sceneDiscoveryController?.stop()
            async let agentStop: Void = agentObservationHost?.stop() ?? ()
            await bedrock?.stop()
            _ = await sceneStop
            _ = await agentStop
            self.finishTermination(sender)
        }
        terminationDeadlineTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            self?.finishTermination(sender)
        }
        return .terminateLater
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func wireShelfSession() {
        shelfSession.isEnabled = { [weak self] in
            self?.enabled ?? false
        }
        shelfSession.isFocusInFlight = { [weak self] in
            self?.agentFocusTask != nil
        }
        shelfSession.parkTargetProvider = { [weak self] in
            self?.resolveParkTarget()
        }
        shelfSession.restoreTargetProvider = { [weak self] in
            self?.resolveRestoreTarget()
        }
        shelfSession.onActivate = { [weak self] identity in
            self?.focusShelfItem(identity)
        }
        shelfSession.onAction = { [weak self] actionID in
            self?.contextShelfHost.invoke(actionId: actionID)
        }
        shelfSession.onStatusChange = { [weak self] message in
            self?.agentSwitchStatus = message
        }
        shelfSession.onNeedsMenuRebuild = { [weak self] in
            self?.rebuildMenu()
        }
        shelfSession.onParked = { [weak self] in
            self?.contextShelfHost.park()
        }
        shelfSession.onReleased = { [weak self] in
            self?.contextShelfHost.releasePark()
        }
    }

    private func wireContextShelfHost() {
        // Present lane: agent snapshot → applyUpdate (elsewhere).
        // Soft lane: enrichment mailbox → passive applyEnrichment only.
        contextShelfHost.onCommittedDocument = { [weak self] document in
            guard let self else { return }
            self.latestShelfDocument = document
            let identity = self.shelfSession.stickyIdentity ?? ShelfItemIdentity(document.id)
            self.shelfSession.applyEnrichment(identity: identity, presentation: document)
        }
        contextShelfHost.onStatus = { [weak self] message in
            guard let self else { return }
            self.agentSwitchStatus = message
            if self.shelfSession.isParked {
                self.shelfSession.showInteractionStatus(message)
            }
        }
        contextShelfHost.setAgentActivateHandler { [weak self] identityKey in
            guard let self else {
                return .unavailable("Pointer Magic is unavailable")
            }
            let identity = ShelfItemIdentity(identityKey)
            await MainActor.run {
                self.focusShelfItem(identity)
            }
            return .completed()
        }
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let image = Self.menuBarIconImage() {
                button.image = image
                button.imagePosition = .imageOnly
                button.title = ""
                button.imageScaling = .scaleProportionallyDown
            } else {
                button.title = "✦"
            }
            button.toolTip = "Click to park the agent shelf · Right-click for menu"
            button.target = self
            button.action = #selector(statusItemPressed(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusMenu = NSMenu(title: "Pointer Magic")
        statusMenu.delegate = self
        rebuildMenu()
    }

    private static func menuBarIconImage() -> NSImage? {
        let candidates = [
            Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
            Bundle.module.url(forResource: "MenuBarIcon", withExtension: "png"),
        ].compactMap { $0 }
        guard let url = candidates.first,
              let image = NSImage(contentsOf: url)
        else { return nil }
        // Black silhouette + alpha gradient; template tinting follows the menu bar.
        image.isTemplate = true
        let pixelSize = image.size
        let height: CGFloat = 16
        let width = max(height, pixelSize.width * (height / max(pixelSize.height, 1)))
        image.size = NSSize(width: width, height: height)
        return image
    }

    private func rebuildMenu() {
        guard let menu = statusMenu else { return }
        menu.removeAllItems()

        let shelfAction = NSMenuItem(
            title: shelfSession.controller.isLockedForInteraction
                ? "Release Agent Shelf"
                : "Park Agent Shelf Here",
            action: #selector(toggleAgentShelfParking),
            keyEquivalent: ""
        )
        shelfAction.target = self
        shelfAction.isEnabled = enabled
        menu.addItem(shelfAction)
        menu.addItem(.separator())

        let toggle = NSMenuItem(
            title: "Pointer Magic",
            action: #selector(togglePointer),
            keyEquivalent: ""
        )
        toggle.target = self
        toggle.state = enabled ? .on : .off
        menu.addItem(toggle)

        let activate = NSMenuItem(
            title: interactionController.primaryActionTitle,
            action: #selector(activatePointer),
            keyEquivalent: ""
        )
        activate.target = self
        activate.isEnabled = enabled
        menu.addItem(activate)
        menu.addItem(.separator())

        if needsPermissionAction {
            let grant = NSMenuItem(
                title: "Request Next Permission…",
                action: #selector(grantPermissions),
                keyEquivalent: ""
            )
            grant.target = self
            menu.addItem(grant)

            let restart = NSMenuItem(
                title: "Reload Permission State",
                action: #selector(restartCapture),
                keyEquivalent: "r"
            )
            restart.target = self
            menu.addItem(restart)
            menu.addItem(.separator())
        }

        let quit = NSMenuItem(
            title: "Quit Pointer Magic",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)
    }

    private var needsPermissionAction: Bool {
        let status = bedrock.permissionStatus()
        return status.inputMonitoring != .granted
            || status.accessibility != .granted
            || !VisualPerceptionEngine.hasScreenRecordingPermission
    }

    @objc
    private func statusItemPressed(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            rebuildMenu()
            guard let button = statusItem.button else { return }
            statusMenu.popUp(
                positioning: nil,
                at: NSPoint(x: button.bounds.minX, y: button.bounds.minY),
                in: button
            )
            return
        }
        toggleAgentShelfParking()
    }

    @objc
    private func toggleAgentShelfParking() {
        shelfSession.toggleParkFromMenu()
    }

    @objc
    private func togglePointer() {
        enabled.toggle()
        if enabled {
            Task { [weak self] in
                guard let self else { return }
                await startEnabledSystems()
                rebuildMenu()
            }
        } else {
            Task { [weak self] in
                guard let self else { return }
                await stopEnabledSystems()
                rebuildMenu()
            }
        }
    }

    @objc
    private func grantPermissions() {
        // Native prompts only. Each request registers the app in the correct
        // privacy list and routes the user there. No custom alert or deep link:
        // those competed with the native prompt and opened incomplete panes.
        let status = bedrock.permissionStatus()
        if status.inputMonitoring != .granted {
            _ = bedrock.requestPermission(.inputMonitoring)
        } else if status.accessibility != .granted {
            _ = bedrock.requestPermission(.accessibility)
        } else if !VisualPerceptionEngine.hasScreenRecordingPermission {
            _ = VisualPerceptionEngine.requestScreenRecordingPermission()
        }
        rebuildMenu()
    }

    @objc
    private func restartCapture() {
        Task { [weak self] in
            guard let self else { return }
            await stopEnabledSystems()
            guard enabled else {
                rebuildMenu()
                return
            }
            await startEnabledSystems()
            rebuildMenu()
        }
    }

    @objc
    private func activatePointer() {
        interactionController.activateNow()
        rebuildMenu()
    }

    @objc
    private func quit() {
        NSApp.terminate(nil)
    }

    private func startEnabledSystems() async {
        guard enabled else { return }
        async let discoveryStatus = sceneDiscoveryController.start()
        await agentObservationHost.start()
        shelfSession.start()
        await contextShelfHost.start()
        installShelfInputObservation()
        _ = await agentObservationHost.refreshNow()
        startAgentShelfUpdates()
        let report = await bedrock.start()
        if enabled, report.started {
            interactionController.start(captureMode: report.captureMode)
        }
        _ = await discoveryStatus
    }

    private func stopEnabledSystems() async {
        agentShelfTask?.cancel()
        agentShelfTask = nil
        agentFocusTask?.cancel()
        agentFocusTask = nil
        removeShelfInputObservation()
        interactionController.stop()
        contextShelfHost.stop()
        shelfSession.stop()
        async let discoveryStatus = sceneDiscoveryController.stop()
        async let agentStop: Void = agentObservationHost.stop()
        await bedrock.stop()
        _ = await discoveryStatus
        _ = await agentStop
    }

    private func installShelfInputObservation() {
        removeShelfInputObservation()
        let shelf = shelfSession.controller
        shelfInputObservation = bedrock.observeOrderedInput { input in
            guard case let .frame(frame) = input else { return }
            let point = frame.coordinates.appKitGlobal
            shelf.acceptPointerSample(
                appKitPoint: CGPoint(x: point.x, y: point.y),
                timestampNs: frame.observedTimestampNs
            )
        }
    }

    private func removeShelfInputObservation() {
        if let shelfInputObservation {
            bedrock.removeInputObservation(shelfInputObservation)
            self.shelfInputObservation = nil
        }
    }

    private func startAgentShelfUpdates() {
        guard agentShelfTask == nil else { return }
        refreshAgentShelf()
        agentShelfTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let updates = await self.agentObservationHost.updates()
            for await _ in updates {
                guard !Task.isCancelled else { return }
                self.refreshAgentShelf()
            }
        }
    }

    private func refreshAgentShelf() {
        let snapshot = agentObservationHost.cachedSnapshot()
        rememberSessions(snapshot.sessions)

        guard case let .session(identity) = snapshot.attentionSelection.target,
              let session = snapshot.sessions.first(where: { $0.identity == identity }),
              session.liveness == .live
        else {
            contextShelfHost.noteAgentSnapshot(nil)
            let stickyStillLive = shelfSession.stickyIdentity.map { sticky in
                guard let agentIdentity = agentByShelfIdentity[sticky] else { return false }
                return snapshot.sessions.contains {
                    $0.identity == agentIdentity && $0.liveness == .live
                }
            } ?? false
            shelfSession.noteAttentionGap(stickyStillLive: stickyStillLive)
            return
        }

        let shelfIdentity = shelfItemIdentity(for: identity)
        let presentation = shelfPresentation(for: session)
        // Present lane: immediate compact agent doc. Soft lane kicked separately.
        latestShelfDocument = presentation.asShelfDocument(id: shelfIdentity.rawValue)
        shelfSession.applyUpdate(identity: shelfIdentity, presentation: presentation)
        contextShelfHost.noteAgentSnapshot(
            AgentShelfProvider.Snapshot(
                identityKey: shelfIdentity.rawValue,
                provider: presentation.provider,
                providerMark: presentation.providerMark.rawValue,
                directoryName: presentation.directoryName,
                state: presentation.state,
                revision: 1
            )
        )
    }

    private func resolveParkTarget() -> (
        identity: ShelfItemIdentity,
        presentation: ShelfDocument
    )? {
        if let document = latestShelfDocument ?? shelfSession.lastPresentation,
           !document.isEmpty
        {
            let identity = shelfSession.stickyIdentity ?? ShelfItemIdentity(document.id)
            return (identity, document)
        }

        let snapshot = agentObservationHost.cachedSnapshot()
        rememberSessions(snapshot.sessions)

        let identity: AgentProviderSessionIdentity?
        if shelfSession.controller.isVisible,
           let sticky = shelfSession.stickyIdentity,
           let visible = agentByShelfIdentity[sticky]
        {
            identity = visible
        } else if case let .dismissed(key) = shelfSession.phase {
            identity = agentByShelfIdentity[key.identity]
        } else if case let .session(selectedIdentity) = snapshot.attentionSelection.target {
            identity = selectedIdentity
        } else {
            identity = nil
        }
        guard let identity,
              let session = snapshot.sessions.first(where: { $0.identity == identity }),
              session.liveness == .live
        else { return nil }
        let shelfIdentity = shelfItemIdentity(for: identity)
        return (
            shelfIdentity,
            shelfPresentation(for: session).asShelfDocument(id: shelfIdentity.rawValue)
        )
    }

    private func resolveRestoreTarget() -> (
        identity: ShelfItemIdentity,
        presentation: ShelfDocument
    )? {
        if let document = latestShelfDocument ?? shelfSession.lastPresentation,
           !document.isEmpty
        {
            let identity = shelfSession.stickyIdentity ?? ShelfItemIdentity(document.id)
            return (identity, document)
        }

        let snapshot = agentObservationHost.cachedSnapshot()
        rememberSessions(snapshot.sessions)

        let attentionIdentity: AgentProviderSessionIdentity?
        if case let .session(identity) = snapshot.attentionSelection.target {
            attentionIdentity = identity
        } else {
            attentionIdentity = nil
        }
        let candidateIdentities = [
            shelfSession.activeIdentity.flatMap { agentByShelfIdentity[$0] },
            attentionIdentity,
            shelfSession.stickyIdentity.flatMap { agentByShelfIdentity[$0] },
        ].compactMap { $0 }

        guard let session = candidateIdentities.lazy.compactMap({ candidate in
            snapshot.sessions.first(where: {
                $0.identity == candidate && $0.liveness == .live
            })
        }).first else {
            return nil
        }
        let shelfIdentity = shelfItemIdentity(for: session.identity)
        return (
            shelfIdentity,
            shelfPresentation(for: session).asShelfDocument(id: shelfIdentity.rawValue)
        )
    }

    private func focusShelfItem(_ shelfIdentity: ShelfItemIdentity) {
        guard let identity = agentByShelfIdentity[shelfIdentity] else {
            agentSwitchStatus = "That item is no longer available"
            shelfSession.cancelFocusKeepParked(status: agentSwitchStatus)
            return
        }

        let snapshot = agentObservationHost.cachedSnapshot()
        guard let session = snapshot.sessions.first(where: { $0.identity == identity }),
              session.liveness == .live
        else {
            agentSwitchStatus = "That agent is no longer running"
            shelfSession.cancelFocusKeepParked(status: agentSwitchStatus)
            return
        }

        shelfSession.showInteractionStatus("Switching to \(providerName(identity.provider))…")
        // beginFocus already suspended the park lease; keep it suspended for the
        // whole handoff so Automation prompts cannot expire the shelf.
        shelfSession.controller.suspendInteractionLease()
        let focusController = agentFocusController!
        agentFocusTask = Task { @MainActor [weak self] in
            let result = await focusController.focus(session)
            guard let self, !Task.isCancelled else { return }
            agentFocusTask = nil
            applyAgentFocusResult(result, provider: identity.provider)
            if case .focused = result {
                shelfSession.endFocus(restoreFollow: true)
            } else {
                shelfSession.cancelFocusKeepParked(status: self.agentSwitchStatus)
            }
            rebuildMenu()
        }
    }

    private func rememberSessions(_ sessions: [AgentSessionSnapshot]) {
        for session in sessions {
            agentByShelfIdentity[shelfItemIdentity(for: session.identity)] = session.identity
        }
    }

    private func shelfItemIdentity(for identity: AgentProviderSessionIdentity) -> ShelfItemIdentity {
        ShelfItemIdentity(
            identity.provider.stableIdentifier + "\u{1f}" + identity.nativeSessionID
        )
    }

    private func shelfPresentation(for session: AgentSessionSnapshot) -> AgentShelfPresentation {
        let provider = session.displayLabel ?? providerName(session.identity.provider)
        return AgentShelfPresentation(
            provider: provider,
            state: stateName(session),
            directoryName: shelfDirectoryName(for: session),
            providerMark: shelfProviderMark(session.identity.provider)
        )
    }

    private func shelfDirectoryName(for session: AgentSessionSnapshot) -> String {
        let path = session.canonicalWorkingDirectory ??
            session.canonicalWorktreeRoot ??
            session.processes.compactMap(\.process.canonicalWorkingDirectory).first
        guard let path, !path.isEmpty else { return "Unknown folder" }
        let name = URL(fileURLWithPath: path).standardizedFileURL.lastPathComponent
        return name.isEmpty ? path : name
    }

    private func shelfProviderMark(_ provider: AgentProvider) -> AgentShelfProviderMark {
        switch provider {
        case .codex: .codex
        case .claudeCode: .claude
        case .cursor: .cursor
        case let .other(value): AgentShelfProviderMark(providerName: value)
        }
    }

    private func applyAgentFocusResult(
        _ result: AgentTUIFocusResult,
        provider: AgentProvider
    ) {
        switch result {
        case .focused:
            agentSwitchStatus = "Switched to \(providerName(provider))"
        case .permissionDenied:
            agentSwitchStatus = "Allow Automation for Ghostty/Terminal in Settings"
        case let .unavailable(reason):
            agentSwitchStatus = switch reason {
            case .ambiguousSurface:
                "More than one terminal matches this folder"
            case .noMatchingSurface:
                "Could not find this agent's terminal"
            case .terminalApplicationNotRunning:
                "The target terminal host is not running"
            case .sessionNotLive, .noLiveProcess, .processExited:
                "That agent is no longer running"
            case .hostBootChanged, .processIdentityChanged, .processTerminalChanged:
                "The agent moved; type there once and retry"
            case .missingActionTimeWorkingDirectory:
                "The terminal folder is unavailable"
            case .terminalIdentityUnavailable:
                "Ghostty 1.4 is needed to identify this terminal"
            }
        case let .failed(failure):
            agentSwitchStatus = failure.message.isEmpty
                ? "Could not switch to that terminal"
                : failure.message
        }
    }

    private func providerName(_ provider: AgentProvider) -> String {
        switch provider {
        case .codex: "Codex"
        case .claudeCode: "Claude"
        case .cursor: "Cursor"
        case let .other(value): value
        }
    }

    private func stateName(_ session: AgentSessionSnapshot) -> String {
        if session.execution == .failed || session.attentionDemand == .failure {
            return "Needs attention"
        }
        switch session.attentionDemand {
        case .question, .permission, .confirmation:
            return "Needs input"
        case .verification where session.execution == .completed:
            return "Ready for review"
        case .unknown, .none, .verification, .failure:
            break
        }
        return switch session.execution {
        case .working: "Working"
        case .waitingForTool: "Waiting on a tool"
        case .completed: "Done"
        case .failed: "Needs attention"
        case .idle: "Idle"
        case .starting: "Starting"
        case .unknown: "Active"
        }
    }

    private func finishTermination(_ sender: NSApplication) {
        guard terminationIsDraining, !terminationReplySent else { return }
        terminationReplySent = true
        terminationDeadlineTask?.cancel()
        terminationDeadlineTask = nil
        sender.reply(toApplicationShouldTerminate: true)
    }
}

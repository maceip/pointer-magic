@preconcurrency import AppKit
import MagicPointerKit
import PointerCore
import PointerMacPerception
import PointerMacSceneDiscovery

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var bedrock: PointerBedrock!
    private var interactionController: MagicPointerInteractionController!
    private var sceneDiscoveryController: MacSceneDiscoveryController!
    private var statusItem: NSStatusItem!
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
        interactionController = MagicPointerInteractionController(bedrock: bedrock)
        // One process-local device identity and observation session. This is
        // deliberately not persisted; source epochs are recreated on every restart.
        sceneDiscoveryController = MacSceneDiscoveryController()
        configureStatusItem()

        Task { [weak self] in
            guard let self else { return }
            await startEnabledSystems()
            rebuildMenu()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        interactionController.stop()
        bedrock.requestStop()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationIsDraining else { return .terminateLater }
        terminationIsDraining = true
        enabled = false
        interactionController.stop()

        // AppKit termination is synchronous, but source coverage and receiver
        // registrations must close before process exit. terminateLater provides
        // that bounded async drain without blocking the main thread.
        Task { [sceneDiscoveryController, bedrock] in
            async let sceneStop = sceneDiscoveryController?.stop()
            await bedrock?.stop()
            _ = await sceneStop
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

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.title = "✦"
        statusItem.button?.toolTip = "Magic Pointer"
        let menu = NSMenu(title: "Magic Pointer")
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()
    }

    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        let toggle = NSMenuItem(
            title: "Magic Pointer",
            action: #selector(togglePointer),
            keyEquivalent: ""
        )
        toggle.target = self
        toggle.state = enabled ? .on : .off
        menu.addItem(toggle)
        menu.addItem(.separator())

        let health = bedrock.health()
        menu.addItem(statusLine("Interaction", value: interactionController.statusText))
        menu.addItem(statusLine("Capture", value: readable(health.captureMode.rawValue)))
        menu.addItem(
            statusLine(
                "Input monitoring",
                value: readable(health.permissions.inputMonitoring.rawValue)
            )
        )
        menu.addItem(
            statusLine(
                "Accessibility",
                value: readable(health.permissions.accessibility.rawValue)
            )
        )
        menu.addItem(
            statusLine(
                "Screen recording",
                value: VisualPerceptionEngine.hasScreenRecordingPermission ? "Granted" : "Not granted"
            )
        )
        menu.addItem(.separator())

        let activate = NSMenuItem(
            title: interactionController.primaryActionTitle,
            action: #selector(activatePointer),
            keyEquivalent: ""
        )
        activate.target = self
        activate.isEnabled = enabled
        menu.addItem(activate)
        menu.addItem(statusLine("How to use", value: interactionController.instructionText))
        menu.addItem(.separator())

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

        menu.addItem(
            statusLine(
                "Render submit p95",
                value: milliseconds(health.renderSubmitLatency.p95Ns)
            )
        )
        menu.addItem(
            statusLine(
                "Tap callback p99 ≤",
                value: microseconds(health.eventTap.callbackP99UpperBoundNs)
            )
        )
        menu.addItem(
            statusLine(
                "Tap interruptions",
                value: String(health.eventTap.tapDisabledCount)
            )
        )
        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit Magic Pointer",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)
    }

    private func statusLine(_ title: String, value: String) -> NSMenuItem {
        let item = NSMenuItem(title: "\(title): \(value)", action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
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
        let report = await bedrock.start()
        if enabled, report.started {
            interactionController.start(captureMode: report.captureMode)
        }
        _ = await discoveryStatus
    }

    private func stopEnabledSystems() async {
        interactionController.stop()
        async let discoveryStatus = sceneDiscoveryController.stop()
        await bedrock.stop()
        _ = await discoveryStatus
    }

    private func finishTermination(_ sender: NSApplication) {
        guard terminationIsDraining, !terminationReplySent else { return }
        terminationReplySent = true
        terminationDeadlineTask?.cancel()
        terminationDeadlineTask = nil
        sender.reply(toApplicationShouldTerminate: true)
    }

    private func readable(_ value: String) -> String {
        value
            .replacingOccurrences(of: "Only", with: " only")
            .replacingOccurrences(of: "eventTap", with: "event tap")
            .capitalized
    }

    private func milliseconds(_ nanoseconds: UInt64) -> String {
        guard nanoseconds > 0 else { return "—" }
        return String(format: "%.2f ms", Double(nanoseconds) / 1_000_000)
    }

    private func microseconds(_ nanoseconds: UInt64) -> String {
        guard nanoseconds > 0, nanoseconds != UInt64.max else { return "—" }
        return String(format: "%.0f µs", Double(nanoseconds) / 1_000)
    }
}

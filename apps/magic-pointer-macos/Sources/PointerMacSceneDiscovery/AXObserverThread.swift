@preconcurrency import ApplicationServices
import CoreFoundation
import Foundation
import PointerSceneContracts

/// Owns every AXObserver and its run-loop source on one dedicated thread. The
/// utility scan lane submits already-known elements; this thread performs only
/// observer lifecycle and registration work, never semantic AX reads.
final class AXObserverThread: @unchecked Sendable {
    private enum StartDisposition {
        case ready
        case unavailable
        case launch(Thread)
        case awaitExistingThread
    }

    fileprivate final class CallbackContext: @unchecked Sendable {
        let processID: Int32
        let mailbox: BoundedSceneTokenMailbox<AXSceneWorkToken>

        init(processID: Int32, mailbox: BoundedSceneTokenMailbox<AXSceneWorkToken>) {
            self.processID = processID
            self.mailbox = mailbox
        }
    }

    private struct RegisteredElement {
        let spec: AXObserverElementSpec
        var notifications: [String]
    }

    private final class ObserverRecord: @unchecked Sendable {
        let observer: AXObserver
        let callbackContext: CallbackContext
        var elements: [SourceObjectID: RegisteredElement] = [:]

        init(observer: AXObserver, callbackContext: CallbackContext) {
            self.observer = observer
            self.callbackContext = callbackContext
        }
    }

    private let mailbox: BoundedSceneTokenMailbox<AXSceneWorkToken>
    private let lock = NSLock()
    private var desiredByProcess: [Int32: [SourceObjectID: AXObserverElementSpec]] = [:]
    private var desiredRevision: UInt64 = 0
    private var runLoop: CFRunLoop?
    private var controlSource: CFRunLoopSource?
    private var thread: Thread?
    private var readinessWaiters: [CheckedContinuation<Bool, Never>] = []
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var ready = false
    private var stopping = false
    private var finished = false
    private var runLoopIterationCount: UInt64 = 0

    init(mailbox: BoundedSceneTokenMailbox<AXSceneWorkToken>) {
        self.mailbox = mailbox
    }

    /// Launches the run-loop thread and asynchronously waits for readiness. The
    /// caller never condition-waits on a cooperative executor. Cancelling startup
    /// requests shutdown and resumes only after the owned thread has finished.
    func start() async -> Bool {
        switch prepareStart() {
        case .ready:
            return true
        case .unavailable:
            return false
        case let .launch(thread):
            thread.start()
        case .awaitExistingThread:
            break
        }

        return await withTaskCancellationHandler {
            await waitForReadiness()
        } onCancel: {
            requestStop()
        }
    }

    private func prepareStart() -> StartDisposition {
        lock.lock()
        if ready {
            lock.unlock()
            return .ready
        }
        if stopping || finished {
            lock.unlock()
            return .unavailable
        }
        if thread == nil {
            let thread = Thread { [weak self] in self?.threadMain() }
            thread.name = "MagicPointer.AXObserverRunLoop"
            thread.qualityOfService = .utility
            self.thread = thread
            lock.unlock()
            return .launch(thread)
        } else {
            lock.unlock()
            return .awaitExistingThread
        }
    }

    func replaceTrackedElements(_ elements: [AXObserverElementSpec]) {
        var grouped: [Int32: [SourceObjectID: AXObserverElementSpec]] = [:]
        for element in elements {
            grouped[element.processID, default: [:]][element.objectID] = element
        }

        lock.lock()
        guard !stopping else {
            lock.unlock()
            return
        }
        desiredByProcess = grouped
        desiredRevision = desiredRevision == UInt64.max ? 1 : desiredRevision + 1
        let runLoop = self.runLoop
        let controlSource = self.controlSource
        lock.unlock()
        signal(controlSource: controlSource, runLoop: runLoop)
    }

    func stop() async {
        requestStop()
        await waitUntilStopped()
    }

    private func waitForReadiness() async -> Bool {
        await withCheckedContinuation { waiter in
            lock.lock()
            if ready {
                lock.unlock()
                waiter.resume(returning: true)
            } else if stopping || finished {
                lock.unlock()
                waiter.resume(returning: false)
            } else {
                readinessWaiters.append(waiter)
                lock.unlock()
            }
        }
    }

    private func requestStop() {
        lock.lock()
        if !stopping { stopping = true }
        let runLoop = self.runLoop
        let controlSource = self.controlSource
        let finishWithoutThread = thread == nil && !finished
        lock.unlock()

        signal(controlSource: controlSource, runLoop: runLoop)
        if let runLoop {
            CFRunLoopStop(runLoop)
        }
        if finishWithoutThread { finish() }
    }

    private func waitUntilStopped() async {
        await withCheckedContinuation { waiter in
            lock.lock()
            if finished {
                lock.unlock()
                waiter.resume()
            } else {
                stopWaiters.append(waiter)
                lock.unlock()
            }
        }
    }

    private func threadMain() {
        guard let currentRunLoop = CFRunLoopGetCurrent() else {
            finish()
            return
        }
        var sourceContext = CFRunLoopSourceContext(
            version: 0,
            info: nil,
            retain: nil,
            release: nil,
            copyDescription: nil,
            equal: nil,
            hash: nil,
            schedule: nil,
            cancel: nil,
            perform: { _ in }
        )
        guard let currentControlSource = CFRunLoopSourceCreate(
            kCFAllocatorDefault,
            0,
            &sourceContext
        ) else {
            finish()
            return
        }
        CFRunLoopAddSource(currentRunLoop, currentControlSource, .defaultMode)

        lock.lock()
        runLoop = currentRunLoop
        controlSource = currentControlSource
        let mayRun = !stopping
        ready = mayRun
        let readinessWaiters = self.readinessWaiters
        self.readinessWaiters.removeAll(keepingCapacity: false)
        lock.unlock()
        for waiter in readinessWaiters { waiter.resume(returning: mayRun) }

        var records: [Int32: ObserverRecord] = [:]
        var appliedRevision: UInt64 = 0

        while true {
            lock.lock()
            if runLoopIterationCount < UInt64.max {
                runLoopIterationCount += 1
            }
            let shouldStop = stopping
            let revision = desiredRevision
            let desired = desiredByProcess
            lock.unlock()
            if shouldStop { break }

            if revision != appliedRevision {
                reconcile(records: &records, desired: desired, runLoop: currentRunLoop)
                appliedRevision = revision
            }
            // The owned manual source keeps an otherwise-empty run loop alive.
            // Desired-state changes and shutdown signal it, so idle startup blocks
            // without polling while reconciliation remains prompt.
            CFRunLoopRunInMode(
                .defaultMode,
                CFTimeInterval.greatestFiniteMagnitude,
                true
            )
        }

        for processID in Array(records.keys) {
            removeObserver(processID: processID, records: &records, runLoop: currentRunLoop)
        }
        CFRunLoopRemoveSource(currentRunLoop, currentControlSource, .defaultMode)
        CFRunLoopSourceInvalidate(currentControlSource)
        finish()
    }

    /// Test-only observability for proving that an empty observer set blocks
    /// instead of turning the run-loop state machine into a hot polling loop.
    func diagnosticRunLoopIterationCount() -> UInt64 {
        lock.lock()
        let count = runLoopIterationCount
        lock.unlock()
        return count
    }

    private func signal(controlSource: CFRunLoopSource?, runLoop: CFRunLoop?) {
        if let controlSource { CFRunLoopSourceSignal(controlSource) }
        if let runLoop { CFRunLoopWakeUp(runLoop) }
    }

    private func finish() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        runLoop = nil
        controlSource = nil
        thread = nil
        ready = false
        finished = true
        let readinessWaiters = self.readinessWaiters
        self.readinessWaiters.removeAll(keepingCapacity: false)
        let stopWaiters = self.stopWaiters
        self.stopWaiters.removeAll(keepingCapacity: false)
        lock.unlock()

        for waiter in readinessWaiters { waiter.resume(returning: false) }
        for waiter in stopWaiters { waiter.resume() }
    }

    private func reconcile(
        records: inout [Int32: ObserverRecord],
        desired: [Int32: [SourceObjectID: AXObserverElementSpec]],
        runLoop: CFRunLoop
    ) {
        for processID in Array(records.keys) where desired[processID] == nil {
            removeObserver(processID: processID, records: &records, runLoop: runLoop)
        }

        for processID in desired.keys.sorted() {
            guard let desiredElements = desired[processID] else { continue }
            if records[processID] == nil {
                records[processID] = createObserver(processID: processID, runLoop: runLoop)
            }
            guard let record = records[processID] else { continue }
            reconcileElements(record: record, desired: desiredElements)
        }
    }

    private func createObserver(processID: Int32, runLoop: CFRunLoop) -> ObserverRecord? {
        var observer: AXObserver?
        let error = AXObserverCreate(pid_t(processID), axSceneObserverCallback, &observer)
        switch AXNotificationRegistrationDisposition.classify(error) {
        case .registered:
            break
        case .permissionLost:
            mailbox.offer(.permissionStateChanged)
            return nil
        case .alreadyRegistered, .unsupportedBestEffort, .elementUnavailable,
             .transientFailure:
            mailbox.offer(.observerCoverageReduced(processID: processID))
            return nil
        }
        guard let observer else { return nil }
        let context = CallbackContext(processID: processID, mailbox: mailbox)
        let record = ObserverRecord(observer: observer, callbackContext: context)
        CFRunLoopAddSource(
            runLoop,
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )
        return record
    }

    private func reconcileElements(
        record: ObserverRecord,
        desired: [SourceObjectID: AXObserverElementSpec]
    ) {
        for objectID in Array(record.elements.keys) where desired[objectID] == nil {
            removeElement(objectID: objectID, record: record)
        }

        var reducedCoverage = false
        for objectID in desired.keys.sorted(by: {
            $0.rawValue.uuidString < $1.rawValue.uuidString
        }) {
            guard let spec = desired[objectID] else { continue }
            if let existing = record.elements[objectID],
               existing.spec.profile == spec.profile,
               CFEqual(existing.spec.element, spec.element)
            {
                continue
            }
            removeElement(objectID: objectID, record: record)

            var registered: [String] = []
            for notification in notificationNames(for: spec.profile) {
                let error = AXObserverAddNotification(
                    record.observer,
                    spec.element,
                    notification as CFString,
                    Unmanaged.passUnretained(record.callbackContext).toOpaque()
                )
                switch AXNotificationRegistrationDisposition.classify(error) {
                case .registered, .alreadyRegistered:
                    registered.append(notification)
                case .unsupportedBestEffort, .elementUnavailable, .transientFailure:
                    reducedCoverage = true
                case .permissionLost:
                    mailbox.offer(.permissionStateChanged)
                }
            }
            record.elements[objectID] = RegisteredElement(
                spec: spec,
                notifications: registered
            )
        }

        if reducedCoverage {
            mailbox.offer(.observerCoverageReduced(
                processID: record.callbackContext.processID
            ))
        }
    }

    private func removeElement(objectID: SourceObjectID, record: ObserverRecord) {
        guard let existing = record.elements.removeValue(forKey: objectID) else { return }
        for notification in existing.notifications {
            AXObserverRemoveNotification(
                record.observer,
                existing.spec.element,
                notification as CFString
            )
        }
    }

    private func removeObserver(
        processID: Int32,
        records: inout [Int32: ObserverRecord],
        runLoop: CFRunLoop
    ) {
        guard let record = records.removeValue(forKey: processID) else { return }
        for objectID in Array(record.elements.keys) {
            removeElement(objectID: objectID, record: record)
        }
        CFRunLoopRemoveSource(
            runLoop,
            AXObserverGetRunLoopSource(record.observer),
            .defaultMode
        )
    }

    private func notificationNames(for profile: AXObserverElementProfile) -> [String] {
        switch profile {
        case .application:
            [
                kAXMainWindowChangedNotification as String,
                kAXFocusedWindowChangedNotification as String,
                kAXFocusedUIElementChangedNotification as String,
                kAXApplicationActivatedNotification as String,
                kAXApplicationDeactivatedNotification as String,
                kAXApplicationHiddenNotification as String,
                kAXApplicationShownNotification as String,
                kAXWindowCreatedNotification as String,
                kAXValueChangedNotification as String,
                kAXUIElementDestroyedNotification as String,
                kAXWindowMovedNotification as String,
                kAXWindowResizedNotification as String,
                kAXWindowMiniaturizedNotification as String,
                kAXWindowDeminiaturizedNotification as String,
                kAXSelectedChildrenChangedNotification as String,
                kAXSelectedRowsChangedNotification as String,
                kAXSelectedColumnsChangedNotification as String,
                kAXSelectedCellsChangedNotification as String,
                kAXSelectedTextChangedNotification as String,
                kAXTitleChangedNotification as String,
                kAXLayoutChangedNotification as String,
                kAXCreatedNotification as String,
                kAXMovedNotification as String,
                kAXResizedNotification as String,
                kAXMenuOpenedNotification as String,
                kAXMenuClosedNotification as String,
            ]
        case .element:
            // This source keeps observer registration bounded at application roots.
            // macOS does not guarantee that every descendant notification reaches
            // that root, so coverage remains best effort and periodic checkpoints
            // reconcile anything the observer path misses.
            []
        }
    }
}

/// The callback intentionally performs no AX reads, allocation-heavy logging,
/// Task creation, or sink calls. Retaining the affected AX reference and offering
/// one bounded token is the entire hot path.
private func axSceneObserverCallback(
    _: AXObserver,
    element: AXUIElement,
    notification: CFString,
    refcon: UnsafeMutableRawPointer?
) {
    guard let refcon,
          let kind = AXSceneNotificationMapper.kind(for: notification as String)
    else {
        return
    }
    let context = Unmanaged<AXObserverThread.CallbackContext>
        .fromOpaque(refcon)
        .takeUnretainedValue()
    context.mailbox.offer(.notification(
        processID: context.processID,
        kind: kind,
        element: AXRetainedElement(element)
    ))
}

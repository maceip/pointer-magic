@preconcurrency import AppKit
@preconcurrency import ApplicationServices
import Foundation
import PointerCore

public final class AXSemanticResolver: @unchecked Sendable {
    private final class ResolutionWork: @unchecked Sendable {
        let request: SemanticRequest
        let sessionEpoch: UInt64
        let continuation: CheckedContinuation<SemanticSnapshot, Never>

        init(
            request: SemanticRequest,
            sessionEpoch: UInt64,
            continuation: CheckedContinuation<SemanticSnapshot, Never>
        ) {
            self.request = request
            self.sessionEpoch = sessionEpoch
            self.continuation = continuation
        }
    }

    private struct RegistryEntry {
        var id: SemanticTargetID
        var element: AXUIElement
        var generation: UInt64
        var lastSeenNs: UInt64
        var sensitivity: SemanticSensitivity
    }

    private struct CacheEntry {
        var snapshot: SemanticSnapshot
        var cachedAtNs: UInt64
        var detail: SemanticDetail
    }

    private struct CircuitState {
        var failuresNs: [UInt64] = []
        var openUntilNs: UInt64 = 0
    }

    private let stateLock = NSLock()
    private var resolutionRunning = false
    private var pendingResolution: ResolutionWork?
    private var queuedActions = 0
    private var sessionEpoch: UInt64 = 1
    private var currentPointerGeneration: UInt64 = 0
    private var currentPointerPoint: GlobalPoint?

    private let queue: OperationQueue
    private let cacheLifetimeNs: UInt64

    // Everything below is touched only by `queue`.
    private var registry: [SemanticTargetID: RegistryEntry] = [:]
    private var cache: CacheEntry?
    private var circuits: [pid_t: CircuitState] = [:]

    public init(cacheLifetimeNs: UInt64 = 80_000_000) {
        self.cacheLifetimeNs = cacheLifetimeNs
        let queue = OperationQueue()
        queue.name = "MagicPointer.Accessibility"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        self.queue = queue
    }

    deinit {
        queue.cancelAllOperations()
    }

    /// Resolves one request at a time. If requests arrive faster than AX can answer, only
    /// the newest pending request survives; the replaced caller receives `.superseded`.
    public func resolve(_ request: SemanticRequest) async -> SemanticSnapshot {
        await withCheckedContinuation { continuation in
            stateLock.lock()
            let epoch = sessionEpoch
            stateLock.unlock()
            let work = ResolutionWork(
                request: request,
                sessionEpoch: epoch,
                continuation: continuation
            )
            var replaced: ResolutionWork?
            var shouldLaunch = false

            stateLock.lock()
            if resolutionRunning {
                replaced = pendingResolution
                pendingResolution = work
            } else {
                resolutionRunning = true
                shouldLaunch = true
            }
            stateLock.unlock()

            if let replaced {
                replaced.continuation.resume(returning: superseded(replaced.request))
            }
            if shouldLaunch {
                launch(work)
            }
        }
    }

    public func perform(_ request: SemanticActionRequest) async -> SemanticActionResult {
        await withCheckedContinuation { continuation in
            stateLock.lock()
            guard queuedActions < 32 else {
                stateLock.unlock()
                continuation.resume(
                    returning: SemanticActionResult(outcome: .rejected, failure: .queueFull)
                )
                return
            }
            let epoch = sessionEpoch
            queuedActions += 1
            stateLock.unlock()

            queue.addOperation { [self] in
                let result = autoreleasepool {
                    performNow(request, sessionEpoch: epoch)
                }
                stateLock.lock()
                queuedActions -= 1
                stateLock.unlock()
                continuation.resume(returning: result)
            }
        }
    }

    public func clear() {
        invalidateSession()
    }

    public func invalidateCache() {
        queue.addOperation { [self] in
            cache = nil
        }
    }

    public func updateCurrentPointerFrame(generation: UInt64, point: GlobalPoint) {
        stateLock.lock()
        currentPointerGeneration = generation
        currentPointerPoint = point
        stateLock.unlock()
    }

    /// Invalidates queued actions synchronously. Raw AX references are then cleared on the
    /// serial worker after any currently blocked system call returns.
    public func invalidateSession() {
        var pending: ResolutionWork?
        stateLock.lock()
        sessionEpoch &+= 1
        currentPointerGeneration = 0
        currentPointerPoint = nil
        pending = pendingResolution
        pendingResolution = nil
        stateLock.unlock()

        if let pending {
            pending.continuation.resume(returning: superseded(pending.request))
        }
        queue.addOperation { [self] in
            registry.removeAll(keepingCapacity: false)
            cache = nil
            circuits.removeAll(keepingCapacity: false)
        }
    }

    private func launch(_ work: ResolutionWork) {
        queue.addOperation { [self] in
            let snapshot: SemanticSnapshot
            if !isCurrentSession(work.sessionEpoch) {
                snapshot = superseded(work.request)
            } else {
                let resolved = autoreleasepool {
                    resolveNow(work.request)
                }
                if isCurrentSession(work.sessionEpoch) {
                    snapshot = resolved
                } else {
                    registry.removeAll(keepingCapacity: false)
                    cache = nil
                    snapshot = superseded(work.request)
                }
            }
            work.continuation.resume(returning: snapshot)

            stateLock.lock()
            let next = pendingResolution
            pendingResolution = nil
            if next == nil {
                resolutionRunning = false
            }
            stateLock.unlock()

            if let next {
                launch(next)
            }
        }
    }

    private func resolveNow(_ request: SemanticRequest) -> SemanticSnapshot {
        let startedNs = DispatchTime.now().uptimeNanoseconds
        let maximumBudgetNs: UInt64 = request.detail == .enriched
            ? 150_000_000
            : 60_000_000
        let effectiveBudgetNs = min(max(request.deadlineNs, 1_000_000), maximumBudgetNs)
        // Queue wait is reported by requested/captured timestamps, but it must not
        // consume the protected AX call budget. A frozen request can legitimately
        // arrive behind a short background hit-test and still needs its full timeout.
        let deadlineAtNs = startedNs &+ effectiveBudgetNs
        guard request.requestedAtNs <= startedNs else {
            return failureSnapshot(
                request,
                startedNs: startedNs,
                state: .timedOut,
                failure: .cannotComplete
            )
        }
        guard AXPermissionController.hasPermission() else {
            return failureSnapshot(
                request,
                startedNs: startedNs,
                state: .unavailable,
                failure: .accessibilityDenied
            )
        }

        if let cached = cachedSnapshot(for: request, nowNs: startedNs) {
            return cached
        }

        if isCircuitOpen(for: 0, nowNs: startedNs) {
            return failureSnapshot(
                request,
                startedNs: startedNs,
                state: .unavailable,
                failure: .circuitOpen
            )
        }

        let systemWide = AXUIElementCreateSystemWide()
        let systemTimeoutSeconds = timeoutSeconds(until: deadlineAtNs, nowNs: startedNs)
        AXUIElementSetMessagingTimeout(systemWide, Float(systemTimeoutSeconds))
        defer { AXUIElementSetMessagingTimeout(systemWide, 0) }

        var rawElement: AXUIElement?
        let hitError = AXUIElementCopyElementAtPosition(
            systemWide,
            Float(request.point.x),
            Float(request.point.y),
            &rawElement
        )
        guard hitError == .success, let element = rawElement else {
            if hitError == .cannotComplete {
                recordFailure(for: 0, nowNs: DispatchTime.now().uptimeNanoseconds)
            }
            return failureSnapshot(
                request,
                startedNs: startedNs,
                state: hitError == .cannotComplete ? .timedOut : .failed,
                failure: failureCode(for: hitError)
            )
        }
        circuits[0] = nil

        let afterHitNs = DispatchTime.now().uptimeNanoseconds
        guard afterHitNs < deadlineAtNs else {
            return failureSnapshot(
                request,
                startedNs: startedNs,
                state: .timedOut,
                failure: .cannotComplete
            )
        }

        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else {
            return failureSnapshot(
                request,
                startedNs: startedNs,
                state: .partial,
                failure: .invalidElement
            )
        }

        if isCircuitOpen(for: pid, nowNs: startedNs) {
            return failureSnapshot(
                request,
                startedNs: startedNs,
                state: .unavailable,
                failure: .circuitOpen
            )
        }

        AXUIElementSetMessagingTimeout(
            element,
            Float(timeoutSeconds(until: deadlineAtNs, nowNs: afterHitNs))
        )
        defer { AXUIElementSetMessagingTimeout(element, 0) }
        let result = readTarget(
            element,
            pid: pid,
            request: request,
            startedNs: startedNs,
            deadlineAtNs: deadlineAtNs
        )

        if result.failure == .cannotComplete {
            recordFailure(for: pid, nowNs: DispatchTime.now().uptimeNanoseconds)
        } else if result.target != nil {
            circuits[pid] = nil
        }

        if result.target != nil, request.detail != .enriched {
            cache = CacheEntry(
                snapshot: result,
                cachedAtNs: result.capturedAtNs,
                detail: request.detail
            )
        }
        return result
    }

    private func readTarget(
        _ element: AXUIElement,
        pid: pid_t,
        request: SemanticRequest,
        startedNs: UInt64,
        deadlineAtNs: UInt64
    ) -> SemanticSnapshot {
        let attributes = AXLiveStructuralAttributePolicy.attributeNames.map {
            $0 as CFString
        }
        var rawValues: CFArray?
        let copyError = AXUIElementCopyMultipleAttributeValues(
            element,
            attributes as CFArray,
            AXCopyMultipleAttributeOptions(rawValue: 0),
            &rawValues
        )
        guard copyError == .success, let values = rawValues as? [Any] else {
            return failureSnapshot(
                request,
                startedNs: startedNs,
                state: copyError == .cannotComplete ? .timedOut : .failed,
                failure: failureCode(for: copyError)
            )
        }

        let afterAttributesNs = DispatchTime.now().uptimeNanoseconds
        guard afterAttributesNs < deadlineAtNs else {
            return failureSnapshot(
                request,
                startedNs: startedNs,
                state: .timedOut,
                failure: .cannotComplete
            )
        }

        let role = string(at: 0, in: values) ?? "AXUnknown"
        let subrole = string(at: 1, in: values)
        let point = point(at: 2, in: values)
        let size = size(at: 3, in: values)
        let enabled = bool(at: 4, in: values)
        let parent = axElement(at: 5, in: values)

        let sensitivity = SemanticSafety.classify(subrole: subrole)
        let frame = point.flatMap { point in
            size.map {
                GlobalRect(
                    x: Double(point.x),
                    y: Double(point.y),
                    width: Double($0.width),
                    height: Double($0.height)
                )
            }
        }
        // Stage two is structural only. Public action names and ancestor roles do
        // not expose element content; secure-text targets still fail closed here
        // and again immediately before action execution.
        let permitsStructuralActions = SemanticSafety.permitsStructuralActions(
            for: sensitivity
        )
        let semanticActions = permitsStructuralActions &&
            DispatchTime.now().uptimeNanoseconds < deadlineAtNs
            ? supportedActions(for: element, deadlineAtNs: deadlineAtNs)
            : []
        let ancestors = sensitivity != .secure && request.detail == .enriched
            ? ancestorChain(startingAt: parent, limit: 6, deadlineAtNs: deadlineAtNs)
            : []
        let safeFields = SemanticSafety.safeFields(
            sensitivity: sensitivity,
            actions: semanticActions,
            ancestors: ancestors
        )
        let nowNs = DispatchTime.now().uptimeNanoseconds
        let targetID = targetID(
            for: element,
            generation: request.generation,
            seenAtNs: nowNs,
            sensitivity: sensitivity
        )
        let bundleIdentifier = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier

        let target = SemanticTarget(
            id: targetID,
            generation: request.generation,
            processID: Int32(pid),
            bundleIdentifier: bundleIdentifier,
            role: role,
            subrole: subrole,
            label: nil,
            identifier: nil,
            frame: frame,
            isEnabled: enabled,
            actions: safeFields.actions,
            ancestors: safeFields.ancestors,
            sensitivity: sensitivity,
            wasTruncated: false,
            directValue: nil,
            textAtPoint: nil,
            textRangeFrame: nil,
            isEditable: nil,
            roleDescription: nil
        )
        return SemanticSnapshot(
            generation: request.generation,
            requestedAtNs: request.requestedAtNs,
            capturedAtNs: nowNs,
            resolutionLatencyNs: nowNs &- startedNs,
            state: copyError == .success ? .fresh : .partial,
            target: target,
            failure: nil
        )
    }

    private func cachedSnapshot(
        for request: SemanticRequest,
        nowNs: UInt64
    ) -> SemanticSnapshot? {
        // Enriched requests make privacy decisions and must re-hit-test the exact
        // pointer point. A cached broad container could otherwise hide a secure child.
        guard request.detail != .enriched,
              var cached = cache,
              nowNs >= cached.cachedAtNs,
              nowNs - cached.cachedAtNs <= cacheLifetimeNs,
              cached.detail == request.detail,
              var target = cached.snapshot.target,
              let frame = target.frame,
              frame.contains(request.point, inset: 1)
        else {
            return nil
        }

        target.generation = request.generation
        if var entry = registry[target.id] {
            entry.generation = request.generation
            entry.lastSeenNs = nowNs
            registry[target.id] = entry
        }
        cached.snapshot.generation = request.generation
        cached.snapshot.requestedAtNs = request.requestedAtNs
        cached.snapshot.resolutionLatencyNs = 0
        cached.snapshot.state = .cached
        cached.snapshot.target = target
        self.cache = cached
        return cached.snapshot
    }

    private func targetID(
        for element: AXUIElement,
        generation: UInt64,
        seenAtNs: UInt64,
        sensitivity: SemanticSensitivity
    ) -> SemanticTargetID {
        if let existing = registry.first(where: { CFEqual($0.value.element, element) }) {
            var entry = existing.value
            entry.generation = generation
            entry.lastSeenNs = seenAtNs
            entry.sensitivity = sensitivity
            registry[entry.id] = entry
            return entry.id
        }

        if registry.count >= 128,
           let oldest = registry.min(by: { $0.value.lastSeenNs < $1.value.lastSeenNs })
        {
            registry[oldest.key] = nil
        }
        let id = SemanticTargetID()
        registry[id] = RegistryEntry(
            id: id,
            element: element,
            generation: generation,
            lastSeenNs: seenAtNs,
            sensitivity: sensitivity
        )
        return id
    }

    private func supportedActions(
        for element: AXUIElement,
        deadlineAtNs: UInt64
    ) -> [SemanticAction] {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        guard nowNs < deadlineAtNs else { return [] }
        AXUIElementSetMessagingTimeout(
            element,
            Float(timeoutSeconds(until: deadlineAtNs, nowNs: nowNs))
        )
        var rawNames: CFArray?
        guard AXUIElementCopyActionNames(element, &rawNames) == .success,
              let names = rawNames as? [String]
        else {
            return []
        }

        return names.prefix(16).compactMap { name in
            switch name {
            case kAXPressAction: .press
            case kAXShowMenuAction: .showMenu
            case kAXIncrementAction: .increment
            case kAXDecrementAction: .decrement
            case kAXConfirmAction: .confirm
            case kAXCancelAction: .cancel
            case kAXRaiseAction: .raise
            default: nil
            }
        }
    }

    private func ancestorChain(
        startingAt initialParent: AXUIElement?,
        limit: Int,
        deadlineAtNs: UInt64
    ) -> [SemanticAncestor] {
        var ancestors: [SemanticAncestor] = []
        ancestors.reserveCapacity(limit)
        var current = initialParent

        while let element = current, ancestors.count < limit {
            let nowNs = DispatchTime.now().uptimeNanoseconds
            guard nowNs < deadlineAtNs else { break }
            AXUIElementSetMessagingTimeout(
                element,
                Float(timeoutSeconds(until: deadlineAtNs, nowNs: nowNs))
            )
            let attributes: [CFString] = [
                kAXRoleAttribute as CFString,
                kAXParentAttribute as CFString,
            ]
            var rawValues: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(
                element,
                attributes as CFArray,
                AXCopyMultipleAttributeOptions(rawValue: 0),
                &rawValues
            ) == .success,
            let values = rawValues as? [Any]
            else {
                break
            }
            let role = string(at: 0, in: values) ?? "AXUnknown"
            ancestors.append(SemanticAncestor(role: role, label: nil))
            current = self.axElement(at: 1, in: values)
        }
        return ancestors
    }

    private func performNow(
        _ request: SemanticActionRequest,
        sessionEpoch expectedEpoch: UInt64
    ) -> SemanticActionResult {
        stateLock.lock()
        let isCurrent = sessionEpoch == expectedEpoch &&
            currentPointerGeneration == request.expectedGeneration
        let actionPoint = currentPointerPoint
        stateLock.unlock()
        guard isCurrent, let actionPoint else {
            return SemanticActionResult(outcome: .rejected, failure: .staleGeneration)
        }
        guard let physicalActionPoint = currentQuartzPointerPoint(),
              physicalActionPoint.distanceSquared(to: actionPoint) <= 0.25
        else {
            return SemanticActionResult(outcome: .rejected, failure: .staleGeneration)
        }
        guard AXPermissionController.hasPermission() else {
            return SemanticActionResult(outcome: .rejected, failure: .accessibilityDenied)
        }
        guard let entry = registry[request.targetID] else {
            return SemanticActionResult(outcome: .rejected, failure: .invalidElement)
        }
        guard entry.sensitivity != .secure else {
            return SemanticActionResult(outcome: .rejected, failure: .unsupported)
        }
        guard entry.generation == request.expectedGeneration else {
            return SemanticActionResult(outcome: .rejected, failure: .staleGeneration)
        }

        // Re-hit-test immediately before a side effect. An opaque ID is not enough: the
        // target may have moved, disappeared, or been covered while an action waited.
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.06)
        defer { AXUIElementSetMessagingTimeout(systemWide, 0) }
        var elementAtPointer: AXUIElement?
        let hitError = AXUIElementCopyElementAtPosition(
            systemWide,
            Float(physicalActionPoint.x),
            Float(physicalActionPoint.y),
            &elementAtPointer
        )
        guard hitError == .success,
              let elementAtPointer,
              CFEqual(elementAtPointer, entry.element)
        else {
            return SemanticActionResult(
                outcome: .rejected,
                failure: hitError == .cannotComplete ? .cannotComplete : .staleGeneration
            )
        }
        AXUIElementSetMessagingTimeout(entry.element, 0.06)
        defer { AXUIElementSetMessagingTimeout(entry.element, 0) }

        guard actionStateIsCurrent(
            sessionEpoch: expectedEpoch,
            generation: request.expectedGeneration,
            point: actionPoint
        ) else {
            return SemanticActionResult(outcome: .rejected, failure: .staleGeneration)
        }

        let error: AXError
        if request.action == .focus {
            guard actionStateIsCurrent(
                sessionEpoch: expectedEpoch,
                generation: request.expectedGeneration,
                point: actionPoint
            ), physicalPointerMatches(actionPoint), actionStateIsCurrent(
                sessionEpoch: expectedEpoch,
                generation: request.expectedGeneration,
                point: actionPoint
            ) else {
                return SemanticActionResult(outcome: .rejected, failure: .staleGeneration)
            }
            if let failure = freshActionSafetyFailure(for: entry.element) {
                return SemanticActionResult(outcome: .rejected, failure: failure)
            }
            guard actionStateIsCurrent(
                sessionEpoch: expectedEpoch,
                generation: request.expectedGeneration,
                point: actionPoint
            ), physicalPointerMatches(actionPoint) else {
                return SemanticActionResult(outcome: .rejected, failure: .staleGeneration)
            }
            error = AXUIElementSetAttributeValue(
                entry.element,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            )
        } else {
            guard let actionName = axActionName(for: request.action) else {
                return SemanticActionResult(outcome: .rejected, failure: .unsupported)
            }
            var names: CFArray?
            guard AXUIElementCopyActionNames(entry.element, &names) == .success,
                  let supported = names as? [String],
                  supported.contains(actionName as String)
            else {
                return SemanticActionResult(outcome: .rejected, failure: .unsupported)
            }
            guard actionStateIsCurrent(
                sessionEpoch: expectedEpoch,
                generation: request.expectedGeneration,
                point: actionPoint
            ), physicalPointerMatches(actionPoint), actionStateIsCurrent(
                sessionEpoch: expectedEpoch,
                generation: request.expectedGeneration,
                point: actionPoint
            ) else {
                return SemanticActionResult(outcome: .rejected, failure: .staleGeneration)
            }
            if let failure = freshActionSafetyFailure(for: entry.element) {
                return SemanticActionResult(outcome: .rejected, failure: failure)
            }
            guard actionStateIsCurrent(
                sessionEpoch: expectedEpoch,
                generation: request.expectedGeneration,
                point: actionPoint
            ), physicalPointerMatches(actionPoint) else {
                return SemanticActionResult(outcome: .rejected, failure: .staleGeneration)
            }
            error = AXUIElementPerformAction(entry.element, actionName)
        }

        if error == .cannotComplete {
            var pid: pid_t = 0
            if AXUIElementGetPid(entry.element, &pid) == .success {
                recordFailure(for: pid, nowNs: DispatchTime.now().uptimeNanoseconds)
            }
        }
        if error == .success {
            return SemanticActionResult(outcome: .succeeded)
        }
        if error == .cannotComplete {
            // Apple explicitly documents that this error does not prove the action failed.
            // Exposing uncertainty prevents a higher layer from automatically retrying a
            // press, confirmation, or increment that may already have happened.
            return SemanticActionResult(outcome: .outcomeUnknown, failure: .cannotComplete)
        }
        return SemanticActionResult(outcome: .failed, failure: failureCode(for: error))
    }

    /// Reclassifies the live element immediately before the side effect. Only
    /// public structural metadata is read; no title, value, or authored content
    /// crosses the adapter boundary.
    private func freshActionSafetyFailure(
        for element: AXUIElement
    ) -> SemanticFailureCode? {
        var rawSubrole: CFTypeRef?
        let readError = AXUIElementCopyAttributeValue(
            element,
            kAXSubroleAttribute as CFString,
            &rawSubrole
        )
        let didCompleteRead: Bool
        let subrole: String?
        switch readError {
        case .success:
            didCompleteRead = true
            subrole = rawSubrole as? String
        case .noValue, .attributeUnsupported:
            // A supported query with no subrole is an ordinary structural
            // absence. Secure text fields report their secure subrole.
            didCompleteRead = true
            subrole = nil
        default:
            didCompleteRead = false
            subrole = nil
        }
        guard SemanticSafety.permitsFreshAction(
            subrole: subrole,
            didCompleteRead: didCompleteRead
        ) else {
            return didCompleteRead ? .unsupported : failureCode(for: readError)
        }
        return nil
    }

    /// Samples the system cursor in the same top-left Quartz space used by AX hit testing.
    /// Explicit actions are rare, so this defensive sample stays off the event-tap hot path.
    private func currentQuartzPointerPoint() -> GlobalPoint? {
        guard let event = CGEvent(source: nil) else { return nil }
        let point = event.location
        return GlobalPoint(x: point.x, y: point.y)
    }

    private func physicalPointerMatches(_ expected: GlobalPoint) -> Bool {
        guard let point = currentQuartzPointerPoint() else { return false }
        return point.distanceSquared(to: expected) <= 0.25
    }

    private func actionStateIsCurrent(
        sessionEpoch expectedEpoch: UInt64,
        generation expectedGeneration: UInt64,
        point expectedPoint: GlobalPoint
    ) -> Bool {
        stateLock.lock()
        let isCurrent = sessionEpoch == expectedEpoch &&
            currentPointerGeneration == expectedGeneration &&
            currentPointerPoint == expectedPoint
        stateLock.unlock()
        return isCurrent
    }

    private func axActionName(for action: SemanticAction) -> CFString? {
        switch action {
        case .press: kAXPressAction as CFString
        case .showMenu: kAXShowMenuAction as CFString
        case .increment: kAXIncrementAction as CFString
        case .decrement: kAXDecrementAction as CFString
        case .confirm: kAXConfirmAction as CFString
        case .cancel: kAXCancelAction as CFString
        case .raise: kAXRaiseAction as CFString
        case .focus: nil
        }
    }

    private func string(at index: Int, in values: [Any]) -> String? {
        guard values.indices.contains(index) else { return nil }
        return values[index] as? String
    }

    private func bool(at index: Int, in values: [Any]) -> Bool? {
        guard values.indices.contains(index) else { return nil }
        return values[index] as? Bool
    }

    private func point(at index: Int, in values: [Any]) -> CGPoint? {
        guard values.indices.contains(index) else { return nil }
        let rawValue = values[index] as CFTypeRef
        guard CFGetTypeID(rawValue) == AXValueGetTypeID() else { return nil }
        let value = unsafeDowncast(rawValue, to: AXValue.self)
        guard
              AXValueGetType(value) == .cgPoint
        else {
            return nil
        }
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    private func size(at index: Int, in values: [Any]) -> CGSize? {
        guard values.indices.contains(index) else { return nil }
        let rawValue = values[index] as CFTypeRef
        guard CFGetTypeID(rawValue) == AXValueGetTypeID() else { return nil }
        let value = unsafeDowncast(rawValue, to: AXValue.self)
        guard
              AXValueGetType(value) == .cgSize
        else {
            return nil
        }
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }

    private func axElement(at index: Int, in values: [Any]) -> AXUIElement? {
        guard values.indices.contains(index) else { return nil }
        let value = values[index] as CFTypeRef
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func failureSnapshot(
        _ request: SemanticRequest,
        startedNs: UInt64,
        state: SemanticResolutionState,
        failure: SemanticFailureCode
    ) -> SemanticSnapshot {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        return SemanticSnapshot(
            generation: request.generation,
            requestedAtNs: request.requestedAtNs,
            capturedAtNs: nowNs,
            resolutionLatencyNs: nowNs &- startedNs,
            state: state,
            target: nil,
            failure: failure
        )
    }

    private func superseded(_ request: SemanticRequest) -> SemanticSnapshot {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        return SemanticSnapshot(
            generation: request.generation,
            requestedAtNs: request.requestedAtNs,
            capturedAtNs: nowNs,
            resolutionLatencyNs: 0,
            state: .superseded,
            target: nil,
            failure: nil
        )
    }

    private func failureCode(for error: AXError) -> SemanticFailureCode {
        switch error {
        case .apiDisabled: .accessibilityDenied
        case .noValue: .noElement
        case .cannotComplete: .cannotComplete
        case .invalidUIElement, .invalidUIElementObserver: .invalidElement
        case .notImplemented, .attributeUnsupported, .actionUnsupported: .unsupported
        default: .unknown
        }
    }

    private func isCircuitOpen(for pid: pid_t, nowNs: UInt64) -> Bool {
        guard let state = circuits[pid] else { return false }
        return state.openUntilNs > nowNs
    }

    private func recordFailure(for pid: pid_t, nowNs: UInt64) {
        var state = circuits[pid] ?? CircuitState()
        let windowStart = nowNs > 5_000_000_000 ? nowNs - 5_000_000_000 : 0
        state.failuresNs.removeAll(where: { $0 < windowStart })
        state.failuresNs.append(nowNs)
        if state.failuresNs.count >= 3 {
            state.openUntilNs = nowNs + 10_000_000_000
            state.failuresNs.removeAll(keepingCapacity: true)
        }
        circuits[pid] = state
    }

    private func isCurrentSession(_ expectedEpoch: UInt64) -> Bool {
        stateLock.lock()
        let result = sessionEpoch == expectedEpoch
        stateLock.unlock()
        return result
    }

    private func timeoutSeconds(until deadlineAtNs: UInt64, nowNs: UInt64) -> Double {
        guard deadlineAtNs > nowNs else { return 0.001 }
        return max(0.001, Double(deadlineAtNs - nowNs) / 1_000_000_000)
    }
}

/// The live pointer resolver reads only public structural attributes. Generic
/// human-authored AX strings and values require a trusted app adapter or a
/// separately consented classifier before they can leave the owning process.
enum AXLiveStructuralAttributePolicy {
    static let attributeNames: [String] = [
        kAXRoleAttribute as String,
        kAXSubroleAttribute as String,
        kAXPositionAttribute as String,
        kAXSizeAttribute as String,
        kAXEnabledAttribute as String,
        kAXParentAttribute as String,
    ]
}

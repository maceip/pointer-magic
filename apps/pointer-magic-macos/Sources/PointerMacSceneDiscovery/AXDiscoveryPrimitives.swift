@preconcurrency import ApplicationServices
import Foundation
import PointerSceneContracts

/// Public AX notifications are reduced to a closed set before they enter the
/// discovery mailbox. Unknown notifications are ignored instead of carrying an
/// unbounded string through the callback path.
public enum AXSceneNotificationKind: UInt8, CaseIterable, Hashable, Sendable {
    case mainWindowChanged
    case focusedWindowChanged
    case focusedElementChanged
    case applicationActivated
    case applicationDeactivated
    case applicationHidden
    case applicationShown
    case windowCreated
    case windowMoved
    case windowResized
    case windowMiniaturized
    case windowDeminiaturized
    case valueChanged
    case elementDestroyed
    case selectedChildrenChanged
    case selectedRowsChanged
    case selectedColumnsChanged
    case selectedCellsChanged
    case selectedTextChanged
    case titleChanged
    case layoutChanged
    case created
    case moved
    case resized
    case menuOpened
    case menuClosed

    public var invalidationReason: SceneInvalidationReason {
        switch self {
        case .windowMoved, .moved:
            .moved
        case .windowResized, .resized:
            .resized
        case .windowCreated, .created:
            .created
        case .elementDestroyed:
            .destroyed
        case .mainWindowChanged, .focusedWindowChanged, .focusedElementChanged,
             .applicationActivated, .applicationDeactivated, .applicationHidden,
             .applicationShown, .windowMiniaturized, .windowDeminiaturized,
             .menuOpened, .menuClosed:
            .occlusionChanged
        case .layoutChanged:
            .geometryChanged
        case .valueChanged, .selectedChildrenChanged, .selectedRowsChanged,
             .selectedColumnsChanged, .selectedCellsChanged, .selectedTextChanged,
             .titleChanged:
            .valueChanged
        }
    }

    /// Structural changes require a fresh bounded hierarchy scan. Local field
    /// changes can refresh only the affected element.
    public var requiresHierarchyRescan: Bool {
        switch self {
        case .mainWindowChanged, .focusedWindowChanged, .focusedElementChanged,
             .applicationActivated, .applicationDeactivated, .applicationHidden,
             .applicationShown, .windowCreated, .windowMiniaturized,
             .windowDeminiaturized, .layoutChanged, .created, .menuOpened, .menuClosed:
            true
        case .windowMoved, .windowResized, .valueChanged, .elementDestroyed,
             .selectedChildrenChanged, .selectedRowsChanged, .selectedColumnsChanged,
             .selectedCellsChanged, .selectedTextChanged, .titleChanged, .moved, .resized:
            false
        }
    }

    public var invalidatedFields: [SceneFieldKey] {
        switch self {
        case .windowMoved, .windowResized, .moved, .resized, .layoutChanged:
            [AXSceneField.geometryBounds]
        case .valueChanged, .selectedChildrenChanged, .selectedRowsChanged,
             .selectedColumnsChanged, .selectedCellsChanged, .selectedTextChanged,
             .titleChanged:
            [AXSceneField.content]
        default:
            []
        }
    }
}

public enum AXSceneNotificationMapper {
    public static func kind(for notification: String) -> AXSceneNotificationKind? {
        switch notification {
        case kAXMainWindowChangedNotification: .mainWindowChanged
        case kAXFocusedWindowChangedNotification: .focusedWindowChanged
        case kAXFocusedUIElementChangedNotification: .focusedElementChanged
        case kAXApplicationActivatedNotification: .applicationActivated
        case kAXApplicationDeactivatedNotification: .applicationDeactivated
        case kAXApplicationHiddenNotification: .applicationHidden
        case kAXApplicationShownNotification: .applicationShown
        case kAXWindowCreatedNotification: .windowCreated
        case kAXWindowMovedNotification: .windowMoved
        case kAXWindowResizedNotification: .windowResized
        case kAXWindowMiniaturizedNotification: .windowMiniaturized
        case kAXWindowDeminiaturizedNotification: .windowDeminiaturized
        case kAXValueChangedNotification: .valueChanged
        case kAXUIElementDestroyedNotification: .elementDestroyed
        case kAXSelectedChildrenChangedNotification: .selectedChildrenChanged
        case kAXSelectedRowsChangedNotification: .selectedRowsChanged
        case kAXSelectedColumnsChangedNotification: .selectedColumnsChanged
        case kAXSelectedCellsChangedNotification: .selectedCellsChanged
        case kAXSelectedTextChangedNotification: .selectedTextChanged
        case kAXTitleChangedNotification: .titleChanged
        case kAXLayoutChangedNotification: .layoutChanged
        case kAXCreatedNotification: .created
        case kAXMovedNotification: .moved
        case kAXResizedNotification: .resized
        case kAXMenuOpenedNotification: .menuOpened
        case kAXMenuClosedNotification: .menuClosed
        default: nil
        }
    }
}

/// Strongly retains an AX reference received by a callback until the scan lane
/// drains it. AX equality/hash are public CoreFoundation operations and are used
/// only for mailbox coalescing; this is not a persistent object identity.
struct AXRetainedElement: @unchecked Sendable, Hashable {
    let rawValue: AXUIElement

    init(_ rawValue: AXUIElement) {
        self.rawValue = rawValue
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        CFEqual(lhs.rawValue, rhs.rawValue)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(rawValue))
    }
}

enum AXSceneWorkToken: Hashable, Sendable {
    case notification(
        processID: Int32,
        kind: AXSceneNotificationKind,
        element: AXRetainedElement
    )
    case reconcileApplications
    case permissionStateChanged
    case observerCoverageReduced(processID: Int32)
    case systemWillSleep
    case systemDidWake
    case sessionDidResignActive
    case sessionDidBecomeActive
    case explicitRefresh
    case periodicRescan
    case heartbeat
}

public enum AXNotificationRegistrationDisposition: Equatable, Sendable {
    case registered
    case alreadyRegistered
    case unsupportedBestEffort
    case permissionLost
    case elementUnavailable
    case transientFailure

    public static func classify(_ error: AXError) -> Self {
        switch error {
        case .success: .registered
        case .notificationAlreadyRegistered: .alreadyRegistered
        case .notificationUnsupported, .notImplemented: .unsupportedBestEffort
        case .apiDisabled: .permissionLost
        case .invalidUIElement, .cannotComplete: .elementUnavailable
        default: .transientFailure
        }
    }
}

/// Enforces both invariants even when an injected scanner attempts to enqueue
/// deeper or more numerous objects.
public struct AXShallowScanBudget: Equatable, Sendable {
    public let maximumDepth: Int
    public let maximumObjects: Int
    public private(set) var consumedObjects: Int = 0

    public init(maximumDepth: Int = 2, maximumObjects: Int = 128) {
        precondition((0 ... 2).contains(maximumDepth), "AX discovery depth cannot exceed two")
        precondition((1 ... 128).contains(maximumObjects), "AX discovery object cap is 128")
        self.maximumDepth = maximumDepth
        self.maximumObjects = maximumObjects
    }

    public var remainingObjects: Int { maximumObjects - consumedObjects }

    @discardableResult
    public mutating func consume(depth: Int) -> Bool {
        guard depth >= 0, depth <= maximumDepth, consumedObjects < maximumObjects else {
            return false
        }
        consumedObjects += 1
        return true
    }
}

public enum AXVisibleChildOrder {
    /// Visible children always lead, duplicates are removed, and the returned
    /// collection cannot exceed the caller's remaining scan budget.
    public static func prioritized<Element: Hashable>(
        visible: [Element],
        all: [Element],
        limit: Int
    ) -> [Element] {
        guard limit > 0 else { return [] }
        var seen = Set<Element>()
        var result: [Element] = []
        result.reserveCapacity(min(limit, visible.count + all.count))
        for element in visible + all where seen.insert(element).inserted {
            result.append(element)
            if result.count == limit { break }
        }
        return result
    }
}

/// Chooses the bounded set of applications worth proactively scanning from one
/// internally consistent desktop census. The active application is retained
/// first, followed by visible window owners in Quartz front-to-back order, then
/// explicitly tracked background applications. Every PID must still be present
/// in the census' live-application set, so stale tracked PIDs cannot survive an
/// application termination.
public enum AXTargetProcessSelection {
    public static func prioritized(
        census: MacDesktopCensus,
        explicitlyTrackedProcessIDs: Set<Int32> = [],
        ownProcessID: Int32,
        maximumCount: Int = 8
    ) -> [Int32] {
        guard maximumCount > 0 else { return [] }
        let limit = min(8, maximumCount)

        let liveProcessIDs = Set(census.applications.lazy.map(\.processID)).subtracting([
            ownProcessID,
        ])
        var seen = Set<Int32>()
        var result: [Int32] = []
        result.reserveCapacity(min(limit, liveProcessIDs.count))

        func append(_ processID: Int32) {
            guard result.count < limit,
                  processID > 0,
                  liveProcessIDs.contains(processID),
                  seen.insert(processID).inserted
            else {
                return
            }
            result.append(processID)
        }

        let activeApplications = census.applications
            .filter(\.isActive)
            .sorted(by: { $0.processID < $1.processID })
        for application in activeApplications {
            append(application.processID)
        }

        let visibleWindows = census.windows
            .filter { $0.isOnScreen && $0.alpha > 0 }
            .sorted(by: windowPriority)
        for window in visibleWindows {
            append(window.ownerProcessID)
        }

        for processID in explicitlyTrackedProcessIDs.sorted() {
            append(processID)
        }
        return result
    }

    private static func windowPriority(_ lhs: MacWindowSnapshot, _ rhs: MacWindowSnapshot) -> Bool {
        if lhs.frontToBackIndex != rhs.frontToBackIndex {
            return lhs.frontToBackIndex < rhs.frontToBackIndex
        }
        if lhs.windowID != rhs.windowID { return lhs.windowID < rhs.windowID }
        return lhs.ownerProcessID < rhs.ownerProcessID
    }
}

/// A deliberately slow reconciliation cadence. The bounds prevent accidental
/// millisecond polling and unbounded timer intervals while keeping the value
/// injectable for products with different power/performance envelopes.
public struct AXPeriodicRescanCadence: Equatable, Sendable {
    public static let minimumIntervalSeconds = 15
    public static let maximumIntervalSeconds = 15 * 60
    public static let defaultIntervalSeconds = 60

    public let intervalSeconds: Int

    public init(intervalSeconds: Int = defaultIntervalSeconds) {
        self.intervalSeconds = min(
            Self.maximumIntervalSeconds,
            max(Self.minimumIntervalSeconds, intervalSeconds)
        )
    }
}

public enum AXSceneSensitivityPropagation {
    /// Secure classification dominates an unknown ancestor; otherwise a child
    /// cannot weaken an ancestor's privacy boundary.
    public static func combine(
        parent: SceneDataSensitivity?,
        local: SceneDataSensitivity
    ) -> SceneDataSensitivity {
        if parent == .secure || local == .secure { return .secure }
        if parent == .unknown || local == .unknown { return .unknown }
        return .ordinary
    }
}

enum AXSceneField {
    static let objectKind = try! SceneFieldKey("object.kind")
    static let applicationPID = try! SceneFieldKey("application.pid")
    static let role = try! SceneFieldKey("accessibility.role")
    static let subrole = try! SceneFieldKey("accessibility.subrole")
    static let content = try! SceneFieldKey("accessibility.content")
    static let geometryBounds = try! SceneFieldKey("geometry.bounds")
}

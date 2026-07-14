@preconcurrency import AppKit
@preconcurrency import ColorSync
@preconcurrency import CoreGraphics
import Foundation

/// Hard CPU and output bounds for one workspace census. The three output ceilings
/// fit together beneath the checkpoint observation limit. The larger inspection
/// ceilings allow malformed and duplicate public OS records without permitting an
/// unbounded parse or sort.
///
/// `CGWindowListCopyWindowInfo` and `NSWorkspace.runningApplications` return fully
/// materialized arrays and expose no paging API, so their initial OS-owned allocation
/// is unavoidable. Magic Pointer inspects only the bounded prefix (plus an explicitly
/// fetched frontmost application) and treats truncation as honest partial evidence
/// under the source's best-effort coverage contract.
public enum MacDesktopCensusBounds {
    public static let maximumDisplays = 16
    public static let maximumApplications = 96
    public static let maximumWindows = 350

    public static let maximumInspectedDisplays = 64
    public static let maximumInspectedApplications = 384
    public static let maximumInspectedWindows = 1_400
}

public enum MacDisplayCensusParser {
    /// Invalid records are omitted. Within the bounded inspected prefix, duplicate
    /// display IDs are resolved by a canonical value ordering so parsing does not
    /// depend on CoreGraphics enumeration order. Inputs beyond that prefix are
    /// intentionally uninspected partial evidence.
    public static func parse(
        _ rawRecords: [RawMacDisplayRecord],
        maximumCount: Int = MacDesktopCensusBounds.maximumDisplays,
        maximumInspectedCount: Int = MacDesktopCensusBounds.maximumInspectedDisplays
    ) -> [MacDisplaySnapshot] {
        let outputLimit = boundedCount(
            maximumCount,
            hardMaximum: MacDesktopCensusBounds.maximumDisplays
        )
        let inspectionLimit = boundedCount(
            maximumInspectedCount,
            hardMaximum: MacDesktopCensusBounds.maximumInspectedDisplays
        )
        guard outputLimit > 0, inspectionLimit > 0 else { return [] }

        let candidates = rawRecords.prefix(inspectionLimit)
            .compactMap(parseOne)
            .sorted(by: canonicalDisplayOrder)
        var seen = Set<UInt32>()
        var result: [MacDisplaySnapshot] = []
        result.reserveCapacity(min(candidates.count, outputLimit))
        for candidate in candidates where seen.insert(candidate.displayID).inserted {
            result.append(candidate)
            if result.count == outputLimit { break }
        }
        return result.sorted { $0.displayID < $1.displayID }
    }

    private static func parseOne(_ raw: RawMacDisplayRecord) -> MacDisplaySnapshot? {
        guard raw.displayID != 0,
              let bounds = raw.globalBounds,
              raw.pixelWidth > 0,
              raw.pixelHeight > 0,
              raw.rotationDegrees.isFinite,
              let quarterTurns = normalizedQuarterTurns(raw.rotationDegrees)
        else {
            return nil
        }

        let rotated = quarterTurns % 2 == 1
        let logicalPixelWidth = rotated ? raw.pixelHeight : raw.pixelWidth
        let logicalPixelHeight = rotated ? raw.pixelWidth : raw.pixelHeight
        let horizontalScale = Double(logicalPixelWidth) / bounds.width
        let verticalScale = Double(logicalPixelHeight) / bounds.height
        guard horizontalScale.isFinite, verticalScale.isFinite,
              horizontalScale > 0, verticalScale > 0
        else {
            return nil
        }
        // Minor mode rounding can make the ratios differ slightly. Retain a single
        // descriptive scale without altering the logical coordinate bounds.
        let scaleFactor = (horizontalScale + verticalScale) / 2
        return MacDisplaySnapshot(
            displayID: raw.displayID,
            displayUUID: raw.displayUUID,
            globalBounds: bounds,
            pixelWidth: raw.pixelWidth,
            pixelHeight: raw.pixelHeight,
            rotationQuarterTurns: quarterTurns,
            scaleFactor: scaleFactor,
            isMain: raw.isMain
        )
    }

    private static func normalizedQuarterTurns(_ degrees: Double) -> UInt8? {
        var normalized = degrees.truncatingRemainder(dividingBy: 360)
        if normalized < 0 { normalized += 360 }
        let rounded = (normalized / 90).rounded()
        guard abs(normalized - rounded * 90) < 0.01 else { return nil }
        return UInt8(Int(rounded) % 4)
    }

    private static func canonicalDisplayOrder(
        _ lhs: MacDisplaySnapshot,
        _ rhs: MacDisplaySnapshot
    ) -> Bool {
        let lhsKey = displayCanonicalKey(lhs)
        let rhsKey = displayCanonicalKey(rhs)
        return lhsKey.lexicographicallyPrecedes(rhsKey)
    }

    private static func displayCanonicalKey(_ value: MacDisplaySnapshot) -> [String] {
        [
            String(format: "%010u", value.displayID),
            value.displayUUID?.uuidString ?? "",
            value.isMain ? "0" : "1",
            value.globalBounds.x.description,
            value.globalBounds.y.description,
            value.globalBounds.width.description,
            value.globalBounds.height.description,
            String(value.pixelWidth),
            String(value.pixelHeight),
            String(value.rotationQuarterTurns),
        ]
    }
}

public enum CGWindowCensusParser {
    /// Parses public CGWindowList dictionary keys. Input order is meaningful: Quartz
    /// returns the list front-to-back, and that index is retained as z-order evidence.
    /// Invalid and duplicate rows still consume the explicit inspection budget.
    public static func parse(
        _ rawRecords: [[String: Any]],
        maximumCount: Int = MacDesktopCensusBounds.maximumWindows,
        maximumInspectedCount: Int = MacDesktopCensusBounds.maximumInspectedWindows
    ) -> [MacWindowSnapshot] {
        let outputLimit = boundedCount(
            maximumCount,
            hardMaximum: MacDesktopCensusBounds.maximumWindows
        )
        let inspectionLimit = boundedCount(
            maximumInspectedCount,
            hardMaximum: MacDesktopCensusBounds.maximumInspectedWindows
        )
        guard outputLimit > 0, inspectionLimit > 0 else { return [] }
        var seen = Set<UInt32>()
        var result: [MacWindowSnapshot] = []
        result.reserveCapacity(min(rawRecords.count, outputLimit))

        for (index, raw) in rawRecords.prefix(inspectionLimit).enumerated() {
            guard let parsed = parseOne(raw, frontToBackIndex: index),
                  seen.insert(parsed.windowID).inserted
            else {
                continue
            }
            result.append(parsed)
            if result.count == outputLimit { break }
        }
        return result
    }

    public static func parseOne(
        _ raw: [String: Any],
        frontToBackIndex: Int
    ) -> MacWindowSnapshot? {
        guard frontToBackIndex >= 0,
              let windowID = exactUInt32(raw[key(kCGWindowNumber)]),
              windowID != 0,
              let ownerPID = exactInt32(raw[key(kCGWindowOwnerPID)]),
              ownerPID > 0,
              let layer = exactInt(raw[key(kCGWindowLayer)]),
              let bounds = parseBounds(raw[key(kCGWindowBounds)])
        else {
            return nil
        }

        let alpha = finiteDouble(raw[key(kCGWindowAlpha)]) ?? 1
        guard (0 ... 1).contains(alpha) else { return nil }

        return MacWindowSnapshot(
            windowID: windowID,
            ownerProcessID: ownerPID,
            ownerName: boundedString(raw[key(kCGWindowOwnerName)]),
            globalBounds: bounds,
            layer: layer,
            alpha: alpha,
            isOnScreen: bool(raw[key(kCGWindowIsOnscreen)]) ?? true,
            sharingState: exactUInt32(raw[key(kCGWindowSharingState)]),
            frontToBackIndex: frontToBackIndex
        )
    }

    private static func key(_ value: CFString) -> String { value as String }

    private static func parseBounds(_ value: Any?) -> MacGlobalRect? {
        guard let dictionary = value as? [String: Any],
              let x = finiteDouble(dictionary["X"]),
              let y = finiteDouble(dictionary["Y"]),
              let width = finiteDouble(dictionary["Width"]),
              let height = finiteDouble(dictionary["Height"])
        else {
            return nil
        }
        return MacGlobalRect(x: x, y: y, width: width, height: height)
    }

    private static func finiteDouble(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }

    private static func exactUInt32(_ value: Any?) -> UInt32? {
        guard let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded() == double,
              double >= 0, double <= Double(UInt32.max)
        else {
            return nil
        }
        return UInt32(double)
    }

    private static func exactInt32(_ value: Any?) -> Int32? {
        guard let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded() == double,
              double >= Double(Int32.min), double <= Double(Int32.max)
        else {
            return nil
        }
        return Int32(double)
    }

    private static func exactInt(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded() == double,
              double >= Double(Int.min), double <= Double(Int.max)
        else {
            return nil
        }
        return Int(double)
    }

    private static func bool(_ value: Any?) -> Bool? {
        (value as? NSNumber)?.boolValue
    }

    private static func boundedString(_ value: Any?) -> String? {
        boundedUTF8String(value as? String, maximumBytes: 16_384)
    }
}

public enum MacApplicationCensusParser {
    /// Selects deterministically from a bounded prefix. Active/frontmost snapshots
    /// are selected before inactive processes when the output ceiling is smaller
    /// than the inspected set, then the retained result is returned in stable PID
    /// order. Invalid and duplicate records consume the inspection budget.
    public static func parse(
        _ rawRecords: [MacApplicationSnapshot],
        maximumCount: Int = MacDesktopCensusBounds.maximumApplications,
        maximumInspectedCount: Int = MacDesktopCensusBounds.maximumInspectedApplications,
        frontmostProcessID: Int32? = nil
    ) -> [MacApplicationSnapshot] {
        let outputLimit = boundedCount(
            maximumCount,
            hardMaximum: MacDesktopCensusBounds.maximumApplications
        )
        let inspectionLimit = boundedCount(
            maximumInspectedCount,
            hardMaximum: MacDesktopCensusBounds.maximumInspectedApplications
        )
        guard outputLimit > 0, inspectionLimit > 0 else { return [] }

        let candidates = rawRecords.prefix(inspectionLimit)
            .compactMap(normalize)
            .sorted {
                selectionOrder(
                    $0,
                    $1,
                    frontmostProcessID: frontmostProcessID
                )
            }
        var seen = Set<Int32>()
        var selected: [MacApplicationSnapshot] = []
        selected.reserveCapacity(min(candidates.count, outputLimit))
        for candidate in candidates where seen.insert(candidate.processID).inserted {
            selected.append(candidate)
            if selected.count == outputLimit { break }
        }
        return selected.sorted(by: canonicalApplicationOrder)
    }

    private static func normalize(
        _ raw: MacApplicationSnapshot
    ) -> MacApplicationSnapshot? {
        guard raw.processID > 0 else { return nil }
        return MacApplicationSnapshot(
            processID: raw.processID,
            bundleIdentifier: boundedUTF8String(
                raw.bundleIdentifier,
                maximumBytes: 16_384
            ),
            localizedName: boundedUTF8String(
                raw.localizedName,
                maximumBytes: 16_384
            ),
            isActive: raw.isActive,
            isHidden: raw.isHidden,
            launchDate: raw.launchDate
        )
    }

    private static func selectionOrder(
        _ lhs: MacApplicationSnapshot,
        _ rhs: MacApplicationSnapshot,
        frontmostProcessID: Int32?
    ) -> Bool {
        let lhsIsFrontmost = lhs.processID == frontmostProcessID
        let rhsIsFrontmost = rhs.processID == frontmostProcessID
        if lhsIsFrontmost != rhsIsFrontmost { return lhsIsFrontmost }
        if lhs.isActive != rhs.isActive { return lhs.isActive }
        return canonicalApplicationOrder(lhs, rhs)
    }

    private static func canonicalApplicationOrder(
        _ lhs: MacApplicationSnapshot,
        _ rhs: MacApplicationSnapshot
    ) -> Bool {
        if lhs.processID != rhs.processID { return lhs.processID < rhs.processID }
        let lhsBundle = lhs.bundleIdentifier ?? ""
        let rhsBundle = rhs.bundleIdentifier ?? ""
        if lhsBundle != rhsBundle { return lhsBundle < rhsBundle }
        let lhsName = lhs.localizedName ?? ""
        let rhsName = rhs.localizedName ?? ""
        if lhsName != rhsName { return lhsName < rhsName }
        if lhs.isHidden != rhs.isHidden { return !lhs.isHidden }
        let lhsLaunch = lhs.launchDate?.timeIntervalSinceReferenceDate ?? -.infinity
        let rhsLaunch = rhs.launchDate?.timeIntervalSinceReferenceDate ?? -.infinity
        return lhsLaunch < rhsLaunch
    }
}

public struct SystemMacDesktopCensusProvider: MacDesktopCensusProviding {
    public let maximumDisplays: Int
    public let maximumApplications: Int
    public let maximumWindows: Int

    public init(
        maximumDisplays: Int = MacDesktopCensusBounds.maximumDisplays,
        maximumApplications: Int = MacDesktopCensusBounds.maximumApplications,
        maximumWindows: Int = MacDesktopCensusBounds.maximumWindows
    ) {
        self.maximumDisplays = min(
            MacDesktopCensusBounds.maximumDisplays,
            max(1, maximumDisplays)
        )
        self.maximumApplications = min(
            MacDesktopCensusBounds.maximumApplications,
            max(1, maximumApplications)
        )
        self.maximumWindows = min(
            MacDesktopCensusBounds.maximumWindows,
            max(1, maximumWindows)
        )
    }

    public func capture() throws -> MacDesktopCensus {
        let displays = try captureDisplays()
        guard !displays.isEmpty else { throw MacDesktopCensusError.noUsableDisplays }

        // Quartz and NSWorkspace expose materialized arrays rather than paged
        // enumeration. Allocation happens inside those APIs; every operation after
        // the handoff is capped by MacDesktopCensusBounds and may yield a deliberately
        // partial best-effort census when an OS snapshot exceeds the inspection limit.
        guard let rawWindows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            throw MacDesktopCensusError.windowEnumerationFailed
        }

        let workspace = NSWorkspace.shared
        let runningApplications = workspace.runningApplications
        let frontmostApplication = workspace.frontmostApplication
        let applicationInputs = boundedApplicationInputs(
            runningApplications,
            frontmost: frontmostApplication
        )
        let applicationSnapshots = applicationInputs.compactMap(applicationSnapshot)

        return MacDesktopCensus(
            displays: displays,
            applications: MacApplicationCensusParser.parse(
                applicationSnapshots,
                maximumCount: maximumApplications,
                frontmostProcessID: frontmostApplication?.processIdentifier
            ),
            windows: CGWindowCensusParser.parse(
                rawWindows,
                maximumCount: maximumWindows
            )
        )
    }

    /// Inspects at most the application ceiling while guaranteeing that the separately
    /// fetched frontmost process occupies one of those slots even if NSWorkspace placed
    /// it beyond the bounded running-app prefix.
    private func boundedApplicationInputs(
        _ applications: [NSRunningApplication],
        frontmost: NSRunningApplication?
    ) -> [NSRunningApplication] {
        let limit = MacDesktopCensusBounds.maximumInspectedApplications
        var selected = Array(applications.prefix(limit))
        guard let frontmost,
              !frontmost.isTerminated,
              frontmost.processIdentifier > 0
        else {
            return selected
        }

        if let index = selected.firstIndex(where: {
            $0.processIdentifier == frontmost.processIdentifier
        }) {
            selected[index] = frontmost
        } else if selected.count < limit {
            selected.append(frontmost)
        } else if !selected.isEmpty {
            selected[selected.index(before: selected.endIndex)] = frontmost
        }
        return selected
    }

    private func applicationSnapshot(
        _ application: NSRunningApplication
    ) -> MacApplicationSnapshot? {
        guard !application.isTerminated, application.processIdentifier > 0 else {
            return nil
        }
        return MacApplicationSnapshot(
            processID: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier,
            localizedName: application.localizedName,
            isActive: application.isActive,
            isHidden: application.isHidden,
            launchDate: application.launchDate
        )
    }

    private func captureDisplays() throws -> [MacDisplaySnapshot] {
        var count: UInt32 = 0
        var error = CGGetActiveDisplayList(0, nil, &count)
        guard error == .success else {
            throw MacDesktopCensusError.displayEnumerationFailed(error)
        }
        guard count > 0 else { return [] }

        let inspectionCount = min(
            Int(count),
            MacDesktopCensusBounds.maximumInspectedDisplays
        )
        let requestedCount = UInt32(inspectionCount)
        var returnedCount: UInt32 = 0
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: inspectionCount)
        error = displayIDs.withUnsafeMutableBufferPointer { buffer in
            CGGetActiveDisplayList(requestedCount, buffer.baseAddress, &returnedCount)
        }
        guard error == .success else {
            throw MacDesktopCensusError.displayEnumerationFailed(error)
        }

        let main = CGMainDisplayID()
        let raw = displayIDs.prefix(Int(returnedCount)).map { displayID in
            RawMacDisplayRecord(
                displayID: displayID,
                displayUUID: stableDisplayUUID(displayID),
                globalBounds: MacGlobalRect(CGDisplayBounds(displayID)),
                pixelWidth: CGDisplayPixelsWide(displayID),
                pixelHeight: CGDisplayPixelsHigh(displayID),
                rotationDegrees: CGDisplayRotation(displayID),
                isMain: displayID == main
            )
        }
        return MacDisplayCensusParser.parse(
            raw,
            maximumCount: maximumDisplays
        )
    }

    private func stableDisplayUUID(_ displayID: CGDirectDisplayID) -> UUID? {
        guard let unmanaged = CGDisplayCreateUUIDFromDisplayID(displayID) else { return nil }
        let value = unmanaged.takeRetainedValue()
        let bytes = CFUUIDGetUUIDBytes(value)
        return UUID(uuid: (
            bytes.byte0, bytes.byte1, bytes.byte2, bytes.byte3,
            bytes.byte4, bytes.byte5, bytes.byte6, bytes.byte7,
            bytes.byte8, bytes.byte9, bytes.byte10, bytes.byte11,
            bytes.byte12, bytes.byte13, bytes.byte14, bytes.byte15
        ))
    }
}

private func boundedUTF8String(_ string: String?, maximumBytes: Int) -> String? {
    guard let string, !string.isEmpty, maximumBytes > 0 else { return nil }
    var scalars = String.UnicodeScalarView()
    var byteCount = 0
    var truncated = false
    for scalar in string.unicodeScalars {
        let scalarBytes = scalar.utf8.count
        guard byteCount + scalarBytes <= maximumBytes else {
            truncated = true
            break
        }
        scalars.append(scalar)
        byteCount += scalarBytes
    }
    if !truncated { return string }
    let result = String(scalars)
    return result.isEmpty ? nil : result
}

private func boundedCount(_ requested: Int, hardMaximum: Int) -> Int {
    guard requested > 0 else { return 0 }
    return min(requested, hardMaximum)
}

import CoreGraphics
import Foundation
import PointerMacSceneDiscovery
import Testing

@Suite("macOS census parsing")
struct MacDesktopCensusParserTests {
    @Test("display parsing is bounded, normalized and input-order independent")
    func displayParsing() throws {
        let bounds = try #require(MacGlobalRect(x: 0, y: 0, width: 1_000, height: 500))
        let preferredDuplicate = RawMacDisplayRecord(
            displayID: 9,
            displayUUID: UUID(uuidString: "00000000-0000-0000-0000-000000000009"),
            globalBounds: bounds,
            pixelWidth: 2_000,
            pixelHeight: 1_000,
            rotationDegrees: 360,
            isMain: true
        )
        let otherDuplicate = RawMacDisplayRecord(
            displayID: 9,
            displayUUID: UUID(uuidString: "00000000-0000-0000-0000-000000000099"),
            globalBounds: bounds,
            pixelWidth: 1_000,
            pixelHeight: 500,
            rotationDegrees: 0,
            isMain: false
        )
        let rotated = RawMacDisplayRecord(
            displayID: 3,
            displayUUID: UUID(uuidString: "00000000-0000-0000-0000-000000000003"),
            globalBounds: MacGlobalRect(x: -600, y: 0, width: 600, height: 800)!,
            pixelWidth: 1_600,
            pixelHeight: 1_200,
            rotationDegrees: -270,
            isMain: false
        )
        let invalid = RawMacDisplayRecord(
            displayID: 4,
            displayUUID: nil,
            globalBounds: nil,
            pixelWidth: 100,
            pixelHeight: 100,
            rotationDegrees: 0,
            isMain: false
        )

        let forward = MacDisplayCensusParser.parse([
            otherDuplicate, invalid, preferredDuplicate, rotated,
        ])
        let reversed = MacDisplayCensusParser.parse([
            rotated, preferredDuplicate, invalid, otherDuplicate,
        ])

        #expect(forward == reversed)
        #expect(forward.map(\.displayID) == [3, 9])
        #expect(forward[0].rotationQuarterTurns == 1)
        #expect(forward[0].scaleFactor == 2)
        #expect(forward[1].isMain)
        #expect(forward[1].scaleFactor == 2)
        #expect(MacDisplayCensusParser.parse([rotated, preferredDuplicate], maximumCount: 1)
            .map(\.displayID) == [3])
    }

    @Test("window parser retains front-to-back order and rejects malformed records")
    func windowParsing() {
        let front = windowDictionary(id: 22, pid: 100, x: -20, title: "Front")
        let duplicate = windowDictionary(id: 22, pid: 100, x: 99, title: "Duplicate")
        let back = windowDictionary(id: 7, pid: 200, x: 50, title: nil)
        var malformed = windowDictionary(id: 8, pid: 300, x: 0, title: "Bad")
        malformed[kCGWindowBounds as String] = [
            "X": 0, "Y": 0, "Width": -1, "Height": 20,
        ]

        let parsed = CGWindowCensusParser.parse([front, malformed, duplicate, back])

        #expect(parsed.map(\.windowID) == [22, 7])
        #expect(parsed.map(\.frontToBackIndex) == [0, 3])
        #expect(parsed[0].globalBounds.x == -20)
        #expect(CGWindowCensusParser.parse([front, back], maximumCount: 1).map(\.windowID) == [22])
    }

    @Test("window names are discarded at the census boundary")
    func windowNamePrivacyBoundary() throws {
        let secret = "PRIVATE-WINDOW-NAME-42"
        let parsed = try #require(CGWindowCensusParser.parse([
            windowDictionary(id: 1, pid: 10, x: 0, title: secret),
        ]).first)

        #expect(!Mirror(reflecting: parsed).children.contains { $0.label == "title" })
        #expect(!String(reflecting: parsed).contains(secret))
    }

    @Test("retained owner strings are bounded by UTF-8 bytes without invalid text")
    func stringByteBounds() throws {
        let ownerName = String(repeating: "🦄", count: 5_000)
        let parsed = try #require(CGWindowCensusParser.parse([
            windowDictionary(
                id: 1,
                pid: 10,
                x: 0,
                title: "discard me",
                ownerName: ownerName
            ),
        ]).first)

        #expect(try #require(parsed.ownerName).utf8.count <= 16_384)
        #expect(try #require(parsed.ownerName).hasPrefix("🦄"))

        let application = try #require(MacApplicationCensusParser.parse([
            MacApplicationSnapshot(
                processID: 99,
                bundleIdentifier: ownerName,
                localizedName: ownerName,
                isActive: true,
                isHidden: false
            ),
        ]).first)
        #expect(try #require(application.bundleIdentifier).utf8.count <= 16_384)
        #expect(try #require(application.localizedName).utf8.count <= 16_384)
    }

    @Test("caller output limits are clamped to checkpoint-safe maxima")
    func outputLimitsAreHardCaps() {
        let provider = SystemMacDesktopCensusProvider(
            maximumDisplays: .max,
            maximumApplications: .max,
            maximumWindows: .max
        )
        #expect(provider.maximumDisplays == MacDesktopCensusBounds.maximumDisplays)
        #expect(provider.maximumApplications == MacDesktopCensusBounds.maximumApplications)
        #expect(provider.maximumWindows == MacDesktopCensusBounds.maximumWindows)

        let displays = (1 ... 17).map { displayRecord(id: UInt32($0)) }
        let parsedDisplays = MacDisplayCensusParser.parse(
            displays.reversed(),
            maximumCount: .max,
            maximumInspectedCount: .max
        )
        #expect(parsedDisplays.count == MacDesktopCensusBounds.maximumDisplays)
        #expect(parsedDisplays.map(\.displayID) == Array(UInt32(1) ... UInt32(16)))

        let windows = (1 ... 351).map {
            windowDictionary(id: UInt32($0), pid: 10, x: Double($0), title: nil)
        }
        let parsedWindows = CGWindowCensusParser.parse(
            windows,
            maximumCount: .max,
            maximumInspectedCount: .max
        )
        #expect(parsedWindows.count == MacDesktopCensusBounds.maximumWindows)
        #expect(parsedWindows.first?.windowID == 1)
        #expect(parsedWindows.last?.windowID == 350)
        #expect(parsedWindows.last?.frontToBackIndex == 349)

        let applications = (1 ... 100).map {
            applicationSnapshot(processID: Int32($0), isActive: false)
        } + [
            applicationSnapshot(processID: 998, isActive: true),
            applicationSnapshot(processID: 999, isActive: false),
        ]
        let parsedApplications = MacApplicationCensusParser.parse(
            applications,
            maximumCount: .max,
            maximumInspectedCount: .max,
            frontmostProcessID: 999
        )
        let reversedApplications = MacApplicationCensusParser.parse(
            applications.reversed(),
            maximumCount: .max,
            maximumInspectedCount: .max,
            frontmostProcessID: 999
        )
        #expect(parsedApplications == reversedApplications)
        #expect(parsedApplications.count == MacDesktopCensusBounds.maximumApplications)
        #expect(parsedApplications.contains { $0.processID == 998 && $0.isActive })
        #expect(parsedApplications.contains { $0.processID == 999 && !$0.isActive })
        #expect(!parsedApplications.contains { $0.processID == 95 })
    }

    @Test("oversized malformed prefixes cannot force unbounded inspection")
    func malformedInputConsumesInspectionBudget() {
        let invalidDisplay = RawMacDisplayRecord(
            displayID: 0,
            displayUUID: nil,
            globalBounds: nil,
            pixelWidth: 0,
            pixelHeight: 0,
            rotationDegrees: .nan,
            isMain: false
        )
        let displayInput = Array(
            repeating: invalidDisplay,
            count: MacDesktopCensusBounds.maximumInspectedDisplays
        ) + [displayRecord(id: 44)]
        #expect(MacDisplayCensusParser.parse(
            displayInput,
            maximumCount: .max,
            maximumInspectedCount: .max
        ).isEmpty)

        let windowInput = Array(
            repeating: [String: Any](),
            count: MacDesktopCensusBounds.maximumInspectedWindows
        ) + [windowDictionary(id: 55, pid: 10, x: 0, title: nil)]
        #expect(CGWindowCensusParser.parse(
            windowInput,
            maximumCount: .max,
            maximumInspectedCount: .max
        ).isEmpty)

        let invalidApplication = applicationSnapshot(processID: 0, isActive: false)
        let applicationInput = Array(
            repeating: invalidApplication,
            count: MacDesktopCensusBounds.maximumInspectedApplications
        ) + [applicationSnapshot(processID: 66, isActive: true)]
        #expect(MacApplicationCensusParser.parse(
            applicationInput,
            maximumCount: .max,
            maximumInspectedCount: .max
        ).isEmpty)
    }

    private func displayRecord(id: UInt32) -> RawMacDisplayRecord {
        RawMacDisplayRecord(
            displayID: id,
            displayUUID: nil,
            globalBounds: MacGlobalRect(
                x: Double(id) * 100,
                y: 0,
                width: 100,
                height: 100
            ),
            pixelWidth: 200,
            pixelHeight: 200,
            rotationDegrees: 0,
            isMain: id == 1
        )
    }

    private func applicationSnapshot(
        processID: Int32,
        isActive: Bool
    ) -> MacApplicationSnapshot {
        MacApplicationSnapshot(
            processID: processID,
            bundleIdentifier: "example.\(processID)",
            localizedName: "Example \(processID)",
            isActive: isActive,
            isHidden: false
        )
    }

    private func windowDictionary(
        id: UInt32,
        pid: Int32,
        x: Double,
        title: String?,
        ownerName: String = "Example"
    ) -> [String: Any] {
        var result: [String: Any] = [
            kCGWindowNumber as String: NSNumber(value: id),
            kCGWindowOwnerPID as String: NSNumber(value: pid),
            kCGWindowOwnerName as String: ownerName,
            kCGWindowBounds as String: [
                "X": x, "Y": 10, "Width": 400, "Height": 300,
            ],
            kCGWindowLayer as String: NSNumber(value: 0),
            kCGWindowAlpha as String: NSNumber(value: 1),
            kCGWindowIsOnscreen as String: NSNumber(value: true),
            kCGWindowSharingState as String: NSNumber(value: 1),
        ]
        if let title { result[kCGWindowName as String] = title }
        return result
    }
}

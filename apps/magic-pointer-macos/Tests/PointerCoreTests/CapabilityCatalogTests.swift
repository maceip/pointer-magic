import Testing
@testable import PointerCore

private func target(
    actions: [SemanticAction],
    sensitivity: SemanticSensitivity = .ordinary,
    isEnabled: Bool? = true
) -> SemanticTarget {
    SemanticTarget(
        id: SemanticTargetID(),
        generation: 1,
        processID: 1,
        bundleIdentifier: "com.example.app",
        role: "AXButton",
        subrole: nil,
        label: "Save",
        identifier: nil,
        frame: nil,
        isEnabled: isEnabled,
        actions: actions,
        ancestors: [],
        sensitivity: sensitivity,
        wasTruncated: false
    )
}

@Suite("Capability catalog")
struct CapabilityCatalogTests {
    @Test("Available actions become labeled items")
    func labeledItems() {
        let items = CapabilityCatalog.items(for: target(actions: [.press, .focus]))
        #expect(items.count == 2)
        #expect(items.allSatisfy { !$0.label.isEmpty })
        #expect(items.contains { $0.label == "Press" })
        #expect(items.contains { $0.label == "Focus" })
    }

    @Test("Secure content contributes no items")
    func secureIsSilent() {
        #expect(CapabilityCatalog.items(for: target(actions: [.press], sensitivity: .secure)).isEmpty)
        #expect(CapabilityCatalog.items(for: target(actions: [.press], sensitivity: .unknown)).isEmpty)
    }

    @Test("A disabled target offers nothing")
    func disabledIsSilent() {
        #expect(CapabilityCatalog.items(for: target(actions: [.press], isEnabled: false)).isEmpty)
    }

    @Test("The set is capped and every item is labeled")
    func boundedAndLabeled() {
        let all = SemanticAction.allCases
        let items = CapabilityCatalog.items(for: target(actions: all))
        #expect(items.count <= CapabilityCatalog.maxItems)
        #expect(items.allSatisfy { !$0.label.isEmpty && !$0.symbol.isEmpty })
        // distinct angles so they don't stack in the companion
        #expect(Set(items.map(\.angleRadians)).count == items.count)
    }

    @Test("No actions means no items")
    func emptyActions() {
        #expect(CapabilityCatalog.items(for: target(actions: [])).isEmpty)
    }
}

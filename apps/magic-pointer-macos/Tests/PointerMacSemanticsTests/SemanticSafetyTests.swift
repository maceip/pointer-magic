@preconcurrency import ApplicationServices
import PointerCore
@testable import PointerMacSemantics
import Testing

@Suite("Semantic privacy safety")
struct SemanticSafetyTests {
    @Test("A secure text-field subrole is secure")
    func secureSubroleWins() {
        let sensitivity = SemanticSafety.classify(subrole: "AXSecureTextField")

        #expect(sensitivity == .secure)
    }

    @Test("Generic AX content remains unknown")
    func genericContentIsUnknown() {
        let sensitivity = SemanticSafety.classify(subrole: "AXTextField")

        #expect(sensitivity == .unknown)
    }

    @Test("Secure targets expose no actions or ancestry")
    func secureTargetFailsClosed() {
        let ancestors = [SemanticAncestor(role: "AXGroup", label: "Private account")]
        let fields = SemanticSafety.safeFields(
            sensitivity: .secure,
            actions: [.press, .showMenu],
            ancestors: ancestors
        )

        #expect(fields.actions.isEmpty)
        #expect(fields.ancestors.isEmpty)
        #expect(!SemanticSafety.permitsStructuralActions(for: .secure))
    }

    @Test("Unknown targets may preserve structural action names and role-only ancestry")
    func unknownStructuralMetadataIsPreserved() {
        let ancestors = [SemanticAncestor(role: "AXGroup", label: nil)]
        let fields = SemanticSafety.safeFields(
            sensitivity: .unknown,
            actions: [.press],
            ancestors: ancestors
        )

        #expect(fields.actions == [.press])
        #expect(fields.ancestors == ancestors)
    }

    @Test("Action safety uses a completed fresh subrole read")
    func actionSafetyRequiresFreshNonsecureClassification() {
        #expect(SemanticSafety.permitsFreshAction(
            subrole: "AXButton",
            didCompleteRead: true
        ))
        #expect(!SemanticSafety.permitsFreshAction(
            subrole: "AXSecureTextField",
            didCompleteRead: true
        ))
        #expect(!SemanticSafety.permitsFreshAction(
            subrole: "AXButton",
            didCompleteRead: false
        ))
    }

    @Test("Live resolution reads structural attributes only")
    func liveStructuralPolicy() {
        let attributes = Set(AXLiveStructuralAttributePolicy.attributeNames)
        #expect(attributes == Set([
            kAXRoleAttribute as String,
            kAXSubroleAttribute as String,
            kAXPositionAttribute as String,
            kAXSizeAttribute as String,
            kAXEnabledAttribute as String,
            kAXParentAttribute as String,
        ]))
        #expect(!attributes.contains(kAXTitleAttribute as String))
        #expect(!attributes.contains(kAXDescriptionAttribute as String))
        #expect(!attributes.contains(kAXIdentifierAttribute as String))
        #expect(!attributes.contains(kAXValueAttribute as String))
    }
}

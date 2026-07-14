@preconcurrency import ApplicationServices
import PointerCore

struct SemanticSafeFields {
    let actions: [SemanticAction]
    let ancestors: [SemanticAncestor]
}

/// Pure policy for deciding whether AX metadata is safe to expose outside the adapter.
enum SemanticSafety {
    static func classify(
        subrole: String?
    ) -> SemanticSensitivity {
        subrole == (kAXSecureTextFieldSubrole as String) ? .secure : .unknown
    }

    static func permitsStructuralActions(for sensitivity: SemanticSensitivity) -> Bool {
        sensitivity != .secure
    }

    /// Action execution must use a new structural read, not the sensitivity
    /// cached when the target ID was minted. A failed read cannot prove that the
    /// element has not become secure, so it fails closed.
    static func permitsFreshAction(
        subrole: String?,
        didCompleteRead: Bool
    ) -> Bool {
        didCompleteRead && permitsStructuralActions(for: classify(subrole: subrole))
    }

    static func safeFields(
        sensitivity: SemanticSensitivity,
        actions: [SemanticAction],
        ancestors: [SemanticAncestor]
    ) -> SemanticSafeFields {
        guard permitsStructuralActions(for: sensitivity) else {
            return SemanticSafeFields(actions: [], ancestors: [])
        }
        return SemanticSafeFields(actions: actions, ancestors: ancestors)
    }
}

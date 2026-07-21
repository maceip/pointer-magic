import Foundation

/// Turns a resolved semantic target into labeled companion items — the first
/// feature layer above the bedrock's "Context" status. Pure and bounded:
/// every item carries a real plain-English label (no mystery glyphs), secure
/// or unknown content contributes nothing, and the set is capped so the
/// companion stays legible in peripheral vision.
public enum CapabilityCatalog {
    public static let maxItems = 4

    /// Ordered so the most common capabilities come first (they survive the
    /// cap); destructive ones read amber, the rest violet.
    private static let order: [SemanticAction] = [
        .press, .confirm, .focus, .showMenu, .increment, .decrement, .raise, .cancel,
    ]

    public static func label(for action: SemanticAction) -> String {
        switch action {
        case .press: return "Press"
        case .focus: return "Focus"
        case .showMenu: return "Menu"
        case .increment: return "Increase"
        case .decrement: return "Decrease"
        case .confirm: return "Confirm"
        case .cancel: return "Cancel"
        case .raise: return "Raise"
        }
    }

    private static func glyph(for action: SemanticAction) -> String {
        switch action {
        case .press: return "⏎"
        case .focus: return "◉"
        case .showMenu: return "≡"
        case .increment: return "＋"
        case .decrement: return "－"
        case .confirm: return "✓"
        case .cancel: return "✕"
        case .raise: return "▲"
        }
    }

    private static func accent(for action: SemanticAction) -> OverlayColor {
        action == .cancel ? .amber : .violet
    }

    /// Labeled items for a target, spread across an arc. `startAngle` and
    /// `arc` are radians; items are laid out after any leading item (e.g. the
    /// bedrock's Context marker) the caller places at angle 0.
    public static func items(
        for target: SemanticTarget,
        startAngle: Double = 0.7,
        arc: Double = 2.0,
        maxItems: Int = maxItems
    ) -> [HaloItem] {
        // Never describe capabilities on secure or unresolved content, and
        // never offer actions on a disabled target.
        guard target.sensitivity == .ordinary else { return [] }
        if target.isEnabled == false { return [] }

        let available = order.filter { target.actions.contains($0) }
        let chosen = Array(available.prefix(maxItems))
        guard !chosen.isEmpty else { return [] }

        let step = chosen.count > 1 ? arc / Double(chosen.count - 1) : 0
        return chosen.enumerated().map { index, action in
            HaloItem(
                id: "capability.\(action.rawValue)",
                symbol: glyph(for: action),
                label: label(for: action),
                angleRadians: startAngle + step * Double(index),
                accent: accent(for: action)
            )
        }
    }
}

@preconcurrency import AppKit
import PointerShelfContracts
import QuartzCore

@MainActor
private final class AgentShelfGlassContentView: NSView {
    override var isFlipped: Bool { true }
    override var allowsVibrancy: Bool { true }
}

@MainActor
private final class AgentShelfVibrantLabel: NSTextField {
    override var allowsVibrancy: Bool { true }
}

@MainActor
final class AgentShelfView: NSView {
    private enum Metrics {
        static let compactHeight: CGFloat = 30
        static let iconOnlyWidth: CGFloat = compactHeight
        static let horizontalPadding: CGFloat = 10
        static let providerHeight: CGFloat = 13
        static let markSize: CGFloat = 14
        static let markTextGap: CGFloat = 5
        static let typographySafetyPadding: CGFloat = 4
        static let dismissAreaWidth: CGFloat = 22
        static let dismissGap: CGFloat = 4
        static let compactCornerRadius: CGFloat = compactHeight / 2
        static let expandedCornerRadius: CGFloat = 16
        static let primaryHeight: CGFloat = 72
        static let actionHeight: CGFloat = 34
        static let actionGap: CGFloat = 6
        static let chipHeight: CGFloat = 28
        static let chipMaxWidth: CGFloat = 160
        static let expandedWidth: CGFloat = 280
    }

    private struct MeasuredWidthKey: Hashable {
        let value: String
        let fontName: String
        let fontSize: CGFloat
        let fontWeight: CGFloat
    }

    private let providerMarkView = AgentShelfProviderMarkView(frame: .zero)
    private let contentContainer = AgentShelfGlassContentView(frame: .zero)
    private let directoryLabel = AgentShelfVibrantLabel(frame: .zero)
    private let stateLabel = AgentShelfVibrantLabel(frame: .zero)
    private let dismissLabel = AgentShelfVibrantLabel(frame: .zero)
    private let promptLabel = AgentShelfVibrantLabel(frame: .zero)
    private let chipLabel = AgentShelfVibrantLabel(frame: .zero)
    private var actionButtons: [NSButton] = []
    private var chrome: NSView?
    private var interactionIsLocked = false
    private var disclosureFraction: CGFloat = 1
    private var measuredWidthCache: [MeasuredWidthKey: CGFloat] = [:]
    private var pressedClickPoint: CGPoint?
    private var pressedActionID: String?

    var onClick: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onAction: ((String) -> Void)?
    private(set) var dismissHitFrame = CGRect.zero
    private(set) var chipHitFrame = CGRect.zero

    var isDismissAffordanceVisible: Bool { !dismissLabel.isHidden }
    var renderedProviderMark: AgentShelfProviderMark { providerMarkView.mark }
    var renderedDirectoryName: String { directoryLabel.stringValue }
    var renderedState: String { stateLabel.stringValue }
    var renderedProviderMarkFrame: CGRect { providerMarkView.frame }
    var renderedStateFrame: CGRect { stateLabel.frame }
    var renderedDirectoryFrame: CGRect { directoryLabel.frame }
    var renderedDirectoryIntrinsicWidth: CGFloat { directoryLabel.intrinsicContentSize.width }
    var renderedStateIntrinsicWidth: CGFloat { stateLabel.intrinsicContentSize.width }
    var renderedDirectoryLineBreakMode: NSLineBreakMode { directoryLabel.lineBreakMode }
    var renderedStateLineBreakMode: NSLineBreakMode { stateLabel.lineBreakMode }
    var renderedDirectoryTextColor: NSColor? { directoryLabel.textColor }
    var renderedStateTextColor: NSColor? { stateLabel.textColor }
    var renderedProviderMarkColor: NSColor? { providerMarkView.contentTintColor }
    var renderedDisclosureFraction: CGFloat { disclosureFraction }
    var renderedDirectoryAlpha: CGFloat { directoryLabel.alphaValue }
    var renderedStateAlpha: CGFloat { stateLabel.alphaValue }
    var contentParticipatesInGlass: Bool {
        if #available(macOS 26.0, *), let glass = chrome as? NSGlassEffectView {
            return glass.contentView === contentContainer
        }
        return contentContainer.superview === chrome
    }
    var renderedCornerRadius: CGFloat { layer?.cornerRadius ?? 0 }
    var clipsToRoundedShelf: Bool { layer?.masksToBounds == true }
    var usesTranslucentChrome: Bool {
        if #available(macOS 26.0, *), chrome is NSGlassEffectView {
            return true
        }
        return chrome is NSVisualEffectView
    }

    private(set) var document = ShelfDocument.compact(
        id: "empty",
        providerId: "agent",
        revision: 0,
        provider: "",
        state: ""
    )

    /// Compatibility mirror of the compact fallback fields.
    var presentation: AgentShelfPresentation {
        if let fallback = document.fallback,
           let value = AgentShelfPresentation(compact: fallback)
        {
            return value
        }
        return AgentShelfPresentation(provider: "", state: "")
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = Metrics.compactCornerRadius
        layer?.borderWidth = 0.65
        layer?.borderColor = NSColor.black.withAlphaComponent(0.20).cgColor
        setAccessibilityElement(false)
        configureLabels()
        rebuildChrome()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applySemanticForeground()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard interactionIsLocked else {
            pressedClickPoint = nil
            pressedActionID = nil
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        pressedClickPoint = point
        pressedActionID = actionID(at: point)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            pressedClickPoint = nil
            pressedActionID = nil
        }
        guard interactionIsLocked, pressedClickPoint != nil else {
            super.mouseUp(with: event)
            return
        }
        routePrimaryClick(at: convert(event.locationInWindow, from: nil))
        super.mouseUp(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard interactionIsLocked else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }

    func setInteractionLocked(_ locked: Bool) {
        guard locked != interactionIsLocked else { return }
        interactionIsLocked = locked
        applyDetailVisibility()
        applySemanticForeground()
        window?.invalidateCursorRects(for: self)
    }

    func preferredSize() -> CGSize {
        currentShelfSize(for: document)
    }

    func routePrimaryClick(at point: CGPoint) {
        guard interactionIsLocked else { return }
        if dismissHitFrame.contains(point) {
            onDismiss?()
            return
        }
        if let actionID = actionID(at: point) ?? pressedActionID {
            onAction?(actionID)
            return
        }
        onClick?()
    }

    @discardableResult
    func apply(_ document: ShelfDocument) -> CGSize {
        // Pointer-follow must not pay layout when the painted value is unchanged.
        if document == self.document {
            return bounds.size == .zero ? disclosedSize(for: document) : bounds.size
        }
        let layoutModeChanged = document.usesExpandedLayout != self.document.usesExpandedLayout
        self.document = document
        rebuildActionButtons(for: document)
        if layoutModeChanged {
            rebuildChrome()
        }
        if let fallback = document.fallback {
            providerMarkView.apply(AgentShelfProviderMark(rawValue: fallback.providerMark)
                ?? AgentShelfProviderMark(providerName: fallback.provider))
            directoryLabel.stringValue = fallback.directoryName
            stateLabel.stringValue = fallback.state
        } else {
            providerMarkView.apply(.unknown)
            directoryLabel.stringValue = ""
            stateLabel.stringValue = ""
        }
        chipLabel.stringValue = document.primary?.chips.first?.text ?? ""
        promptLabel.stringValue = document.primary?.prompt?.placeholder ?? ""
        applyDetailVisibility()

        let size = disclosedSize(for: document)
        frame.size = size
        layer?.cornerRadius = document.usesExpandedLayout
            ? Metrics.expandedCornerRadius
            : Metrics.compactCornerRadius
        needsLayout = true
        layoutSubtreeIfNeeded()
        return size
    }

    @discardableResult
    func apply(_ presentation: AgentShelfPresentation) -> CGSize {
        apply(presentation.asShelfDocument(id: "legacy"))
    }

    @discardableResult
    func setDisclosureFraction(_ requestedFraction: CGFloat) -> CGSize {
        let finiteFraction = requestedFraction.isFinite ? requestedFraction : 0
        disclosureFraction = min(1, max(0, finiteFraction))
        applyDetailVisibility()
        let size = disclosedSize(for: document)
        frame.size = size
        needsLayout = true
        layout()
        return size
    }

    func refreshAccessibilityAppearance() {
        rebuildChrome()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        chrome?.frame = bounds
        contentContainer.frame = bounds

        if document.usesExpandedLayout {
            layoutExpanded()
        } else {
            layoutCompact()
        }
    }

    private func layoutCompact() {
        let horizontalPadding = Metrics.horizontalPadding
        let markSize = Metrics.markSize
        let textX = horizontalPadding + markSize + Metrics.markTextGap

        promptLabel.isHidden = true
        chipLabel.isHidden = true
        for button in actionButtons {
            button.isHidden = true
        }

        dismissHitFrame = CGRect(
            x: bounds.maxX - horizontalPadding - Metrics.dismissAreaWidth,
            y: (bounds.height - Metrics.dismissAreaWidth) / 2,
            width: Metrics.dismissAreaWidth,
            height: Metrics.dismissAreaWidth
        )
        dismissLabel.frame = dismissHitFrame
        chipHitFrame = .zero

        providerMarkView.isHidden = false
        providerMarkView.frame = CGRect(
            x: ((Metrics.iconOnlyWidth - markSize) / 2) +
                ((horizontalPadding - ((Metrics.iconOnlyWidth - markSize) / 2)) *
                    disclosureFraction),
            y: (bounds.height - markSize) / 2,
            width: markSize,
            height: markSize
        )

        let directoryWidth = naturalLabelWidth(directoryLabel, value: presentation.directoryName)
        let stateWidth = naturalLabelWidth(stateLabel, value: presentation.state)
        directoryLabel.frame = CGRect(x: textX, y: 2, width: directoryWidth, height: Metrics.providerHeight)
        stateLabel.frame = CGRect(x: textX, y: 15, width: stateWidth, height: Metrics.providerHeight)
    }

    private func layoutExpanded() {
        providerMarkView.isHidden = true
        directoryLabel.isHidden = true
        stateLabel.isHidden = true

        let padding = Metrics.horizontalPadding
        dismissHitFrame = CGRect(
            x: bounds.maxX - padding - Metrics.dismissAreaWidth,
            y: padding,
            width: Metrics.dismissAreaWidth,
            height: Metrics.dismissAreaWidth
        )
        dismissLabel.frame = dismissHitFrame

        let chipText = document.primary?.chips.first?.text ?? ""
        chipLabel.isHidden = chipText.isEmpty
        let chipWidth = min(
            Metrics.chipMaxWidth,
            max(36, naturalLabelWidth(chipLabel, value: chipText) + 16)
        )
        chipHitFrame = CGRect(x: padding, y: padding, width: chipWidth, height: Metrics.chipHeight)
        chipLabel.frame = chipHitFrame

        let prompt = document.primary?.prompt?.placeholder ?? ""
        promptLabel.isHidden = prompt.isEmpty
        promptLabel.frame = CGRect(
            x: padding,
            y: padding + Metrics.chipHeight + 8,
            width: bounds.width - (padding * 2),
            height: 18
        )

        var y = Metrics.primaryHeight + Metrics.actionGap
        for (index, button) in actionButtons.enumerated() {
            button.isHidden = false
            button.frame = CGRect(
                x: 0,
                y: y,
                width: bounds.width,
                height: Metrics.actionHeight
            )
            if index < document.actions.count {
                button.title = "  " + document.actions[index].title
                button.image = NSImage(
                    systemSymbolName: document.actions[index].icon.systemImageName ?? "sparkle",
                    accessibilityDescription: document.actions[index].title
                )
            }
            y += Metrics.actionHeight + Metrics.actionGap
        }
    }

    private func configureLabels() {
        for label in [directoryLabel, stateLabel, dismissLabel, promptLabel, chipLabel] {
            label.isEditable = false
            label.isSelectable = false
            label.isBordered = false
            label.isBezeled = false
            label.drawsBackground = false
            label.focusRingType = .none
            label.wantsLayer = true
        }

        directoryLabel.font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        directoryLabel.alignment = .left
        directoryLabel.usesSingleLineMode = true
        directoryLabel.lineBreakMode = .byClipping

        stateLabel.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        stateLabel.alignment = .left
        stateLabel.usesSingleLineMode = true
        stateLabel.lineBreakMode = .byClipping

        promptLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        promptLabel.alignment = .left
        promptLabel.usesSingleLineMode = true
        promptLabel.lineBreakMode = .byTruncatingTail

        chipLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        chipLabel.alignment = .center
        chipLabel.usesSingleLineMode = true
        chipLabel.lineBreakMode = .byTruncatingTail
        chipLabel.wantsLayer = true
        chipLabel.layer?.cornerRadius = 8
        chipLabel.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor

        dismissLabel.stringValue = "×"
        dismissLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        dismissLabel.alignment = .center
        dismissLabel.isHidden = true
        applySemanticForeground()
    }

    private func rebuildActionButtons(for document: ShelfDocument) {
        for button in actionButtons {
            button.removeFromSuperview()
        }
        actionButtons = document.actions.map { action in
            let button = NSButton(frame: .zero)
            button.bezelStyle = .inline
            button.isBordered = false
            button.imagePosition = .imageLeading
            button.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            button.contentTintColor = .labelColor
            button.title = "  " + action.title
            button.image = NSImage(
                systemSymbolName: action.icon.systemImageName ?? "sparkle",
                accessibilityDescription: action.title
            )
            button.wantsLayer = true
            button.layer?.cornerRadius = Metrics.actionHeight / 2
            button.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.22).cgColor
            button.setAccessibilityElement(false)
            contentContainer.addSubview(button)
            return button
        }
    }

    private func actionID(at point: CGPoint) -> String? {
        for (index, button) in actionButtons.enumerated() where !button.isHidden {
            if button.frame.contains(point), index < document.actions.count {
                return document.actions[index].id
            }
        }
        return nil
    }

    private func rebuildChrome() {
        if #available(macOS 26.0, *), let glass = chrome as? NSGlassEffectView {
            glass.contentView = nil
        }
        contentContainer.removeFromSuperview()
        chrome?.removeFromSuperview()

        let corner = document.usesExpandedLayout
            ? Metrics.expandedCornerRadius
            : Metrics.compactCornerRadius

        let replacement: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: bounds)
            glass.style = .clear
            glass.cornerRadius = corner
            glass.tintColor = NSColor.white.withAlphaComponent(0.08)
            glass.wantsLayer = true
            configureChromeLayer(glass.layer)
            glass.contentView = contentContainer
            replacement = glass
        } else {
            let material = NSVisualEffectView(frame: bounds)
            material.blendingMode = .behindWindow
            material.material = .popover
            material.state = .active
            material.wantsLayer = true
            material.layer?.cornerRadius = corner
            configureChromeLayer(material.layer)
            material.addSubview(contentContainer)
            replacement = material
        }

        replacement.autoresizingMask = [.width, .height]
        replacement.setAccessibilityElement(false)
        contentContainer.frame = replacement.bounds
        contentContainer.autoresizingMask = [.width, .height]
        contentContainer.setAccessibilityElement(false)
        addSubview(replacement, positioned: .below, relativeTo: nil)
        chrome = replacement

        for label in [directoryLabel, stateLabel, dismissLabel, promptLabel, chipLabel] {
            label.removeFromSuperview()
            label.setAccessibilityElement(false)
            contentContainer.addSubview(label)
        }
        providerMarkView.removeFromSuperview()
        contentContainer.addSubview(providerMarkView)
        for button in actionButtons {
            button.removeFromSuperview()
            contentContainer.addSubview(button)
        }
    }

    private func currentShelfSize(for document: ShelfDocument) -> CGSize {
        if document.usesExpandedLayout {
            let actionCount = CGFloat(document.actions.count)
            let actionsHeight = actionCount == 0
                ? 0
                : (actionCount * Metrics.actionHeight) + ((actionCount - 1) * Metrics.actionGap)
            let height = Metrics.primaryHeight + (actionsHeight > 0 ? Metrics.actionGap + actionsHeight : 0)
            return CGSize(width: Metrics.expandedWidth, height: height)
        }

        let directoryWidth = naturalLabelWidth(directoryLabel, value: presentation.directoryName)
        let stateWidth = naturalLabelWidth(stateLabel, value: presentation.state)
        let textWidth = max(directoryWidth, stateWidth)
        let contentWidth = Metrics.markSize + Metrics.markTextGap + textWidth
        let width = contentWidth + (Metrics.horizontalPadding * 2) +
            Metrics.dismissGap + Metrics.dismissAreaWidth
        return CGSize(width: width.rounded(.up), height: Metrics.compactHeight)
    }

    private func disclosedSize(for document: ShelfDocument) -> CGSize {
        let current = currentShelfSize(for: document)
        if document.usesExpandedLayout {
            return current
        }
        let width = Metrics.iconOnlyWidth +
            ((current.width - Metrics.iconOnlyWidth) * disclosureFraction)
        return CGSize(width: width, height: Metrics.compactHeight)
    }

    private func measuredWidth(_ value: String, font: NSFont?) -> CGFloat {
        guard !value.isEmpty, let font else { return 0 }
        let key = MeasuredWidthKey(
            value: value,
            fontName: font.fontName,
            fontSize: font.pointSize,
            fontWeight: font.weightValue
        )
        if let cached = measuredWidthCache[key] {
            return cached
        }
        let width = (value as NSString).size(withAttributes: [.font: font]).width
        measuredWidthCache[key] = width
        return width
    }

    private func naturalLabelWidth(_ label: NSTextField, value: String) -> CGFloat {
        guard !value.isEmpty else { return 0 }
        return max(
            measuredWidth(value, font: label.font),
            max(0, label.intrinsicContentSize.width)
        ) + Metrics.typographySafetyPadding
    }

    private func configureChromeLayer(_ layer: CALayer?) {
        layer?.borderWidth = 0.9
        layer?.borderColor = NSColor.white.withAlphaComponent(0.30).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.32
        layer?.shadowRadius = 9
        layer?.shadowOffset = CGSize(width: 0, height: -2)
    }

    private func applyDetailVisibility() {
        let expanded = document.usesExpandedLayout
        let showsDetails = disclosureFraction > 0.001
        if expanded {
            directoryLabel.isHidden = true
            stateLabel.isHidden = true
            chipLabel.isHidden = (document.primary?.chips.first?.text ?? "").isEmpty
            promptLabel.isHidden = (document.primary?.prompt?.placeholder ?? "").isEmpty
            chipLabel.alphaValue = 1
            promptLabel.alphaValue = 1
        } else {
            directoryLabel.isHidden = presentation.directoryName.isEmpty || !showsDetails
            stateLabel.isHidden = presentation.state.isEmpty || !showsDetails
            directoryLabel.alphaValue = disclosureFraction
            stateLabel.alphaValue = disclosureFraction
            chipLabel.isHidden = true
            promptLabel.isHidden = true
        }
        dismissLabel.alphaValue = expanded ? 1 : disclosureFraction
        dismissLabel.isHidden = !interactionIsLocked || (!expanded && disclosureFraction < 0.999)
    }

    private func applySemanticForeground() {
        directoryLabel.textColor = .secondaryLabelColor
        stateLabel.textColor = interactionIsLocked ? .controlAccentColor : .labelColor
        dismissLabel.textColor = .secondaryLabelColor
        promptLabel.textColor = .secondaryLabelColor
        chipLabel.textColor = .labelColor
        providerMarkView.contentTintColor = .labelColor
    }
}

private extension NSFont {
    var weightValue: CGFloat {
        if let weight = fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any],
           let numeric = weight[.weight] as? NSNumber
        {
            return CGFloat(truncating: numeric)
        }
        return 0
    }
}

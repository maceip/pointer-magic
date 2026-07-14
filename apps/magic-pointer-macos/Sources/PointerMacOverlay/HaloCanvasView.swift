@preconcurrency import AppKit
import PointerCore
import QuartzCore

final class HaloNodeLayer: CALayer {
    private let disc = CAShapeLayer()
    private let symbolLayer = CATextLayer()
    private let labelLayer = CATextLayer()

    override init() {
        super.init()
        anchorPoint = CGPoint(x: 0.5, y: 0.5)

        disc.fillColor = NSColor(calibratedWhite: 0.07, alpha: 0.94).cgColor
        disc.strokeColor = NSColor.white.withAlphaComponent(0.18).cgColor
        disc.lineWidth = 1
        disc.shadowColor = NSColor.black.cgColor
        disc.shadowOpacity = 0.32
        disc.shadowRadius = 7
        disc.shadowOffset = CGSize(width: 0, height: -2)
        addSublayer(disc)

        symbolLayer.alignmentMode = .center
        symbolLayer.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        symbolLayer.fontSize = 12
        symbolLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        addSublayer(symbolLayer)

        labelLayer.alignmentMode = .left
        labelLayer.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        labelLayer.fontSize = 11
        labelLayer.foregroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
        labelLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        labelLayer.truncationMode = .end
        addSublayer(labelLayer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(item: HaloItem, scale: CGFloat) {
        let width: CGFloat = 112
        bounds = CGRect(x: 0, y: 0, width: width, height: 28)
        cornerRadius = 14

        disc.frame = bounds
        disc.path = CGPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            cornerWidth: 14,
            cornerHeight: 14,
            transform: nil
        )
        disc.strokeColor = color(item.accent, alphaMultiplier: 0.72)

        symbolLayer.string = item.symbol
        symbolLayer.foregroundColor = color(item.accent, alphaMultiplier: 1)
        symbolLayer.frame = CGRect(x: 7, y: 6, width: 28, height: 16)
        symbolLayer.contentsScale = scale

        labelLayer.isHidden = false
        labelLayer.string = item.label
        labelLayer.frame = CGRect(x: 34, y: 6, width: width - 40, height: 15)
        labelLayer.contentsScale = scale
    }

    private func color(_ value: OverlayColor, alphaMultiplier: Double) -> CGColor {
        NSColor(
            calibratedRed: value.red,
            green: value.green,
            blue: value.blue,
            alpha: value.alpha * alphaMultiplier
        ).cgColor
    }
}

@MainActor
final class HaloCanvasView: NSView {
    private let haloRoot = CALayer()
    private let titleBackdrop = CAShapeLayer()
    private let titleLayer = CATextLayer()
    private let targetOutline = CAShapeLayer()
    private var nodeLayers: [HaloNodeLayer] = []
    private var sidecar: NSView!
    private var sidecarLabel: NSTextField!
    private var cachedCompactTitle: String?
    private var cachedCompactSize = CGSize(width: 200, height: 38)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = true

        setAccessibilityElement(false)

        (sidecar, sidecarLabel) = makeSidecar()
        sidecar.isHidden = true
        addSubview(sidecar)

        targetOutline.fillColor = NSColor.clear.cgColor
        targetOutline.strokeColor = NSColor.systemCyan.withAlphaComponent(0.58).cgColor
        targetOutline.lineWidth = 1.5
        targetOutline.lineDashPattern = [5, 4]
        targetOutline.shadowColor = NSColor.systemCyan.cgColor
        targetOutline.shadowOpacity = 0.25
        targetOutline.shadowRadius = 6
        layer?.addSublayer(targetOutline)

        haloRoot.bounds = CGRect(x: -120, y: -120, width: 240, height: 240)
        layer?.addSublayer(haloRoot)

        titleBackdrop.fillColor = NSColor(calibratedWhite: 0.055, alpha: 0.94).cgColor
        titleBackdrop.strokeColor = NSColor.white.withAlphaComponent(0.14).cgColor
        titleBackdrop.lineWidth = 1
        titleBackdrop.shadowColor = NSColor.black.cgColor
        titleBackdrop.shadowOpacity = 0.28
        titleBackdrop.shadowRadius = 8
        titleBackdrop.isHidden = true
        haloRoot.addSublayer(titleBackdrop)

        titleLayer.alignmentMode = .center
        titleLayer.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        titleLayer.fontSize = 11
        titleLayer.foregroundColor = NSColor.white.withAlphaComponent(0.94).cgColor
        titleLayer.truncationMode = .end
        titleLayer.isHidden = true
        haloRoot.addSublayer(titleLayer)

        for _ in 0..<8 {
            let node = HaloNodeLayer()
            node.isHidden = true
            haloRoot.addSublayer(node)
            nodeLayers.append(node)
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    override var isFlipped: Bool { false }

    func render(
        pointerLocal: CGPoint,
        targetLocal: CGRect?,
        scene: OverlayScene?,
        timestamp: CFTimeInterval,
        reduceMotion: Bool,
        backingScale: CGFloat
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        guard let scene else {
            sidecar.isHidden = true
            targetOutline.isHidden = true
            titleBackdrop.isHidden = true
            titleLayer.isHidden = true
            for node in nodeLayers {
                node.isHidden = true
            }
            CATransaction.commit()
            return
        }

        let items = scene.items
        let expanded = !items.isEmpty
        let compactTitle = expanded ? nil : scene.title
        let sidecarSize = compactTitle.map(cachedSidecarSize) ?? CGSize(width: 44, height: 31)
        let clusterSize = expanded
            ? CompanionPlacement.clusterSize(expanded: true)
            : sidecarSize
        let companionCenter = CompanionPlacement.center(
            for: pointerLocal,
            inside: bounds,
            size: clusterSize,
            gap: expanded ? 12 : 5
        )
        haloRoot.position = companionCenter
        sidecar.isHidden = false
        sidecar.frame = CGRect(
            x: companionCenter.x - sidecarSize.width / 2,
            y: companionCenter.y - sidecarSize.height / 2,
            width: sidecarSize.width,
            height: sidecarSize.height
        )
        sidecarLabel.isHidden = compactTitle == nil
        sidecarLabel.frame = sidecar.bounds.insetBy(dx: 16, dy: 8)

        let revealProgress: Double
        if reduceMotion {
            revealProgress = 1
        } else {
            let age = max(0, timestamp - Double(scene.createdAtNs) / 1_000_000_000)
            let linear = min(1, age / 0.32)
            revealProgress = 1 - pow(1 - linear, 3)
        }
        // Capabilities sweep briefly into place, then stop. Nothing spins in peripheral
        // vision merely because pointer mode is enabled.
        let phase = (revealProgress - 1) * 0.72
        let radius: CGFloat = items.isEmpty ? 0 : 58

        for (index, layer) in nodeLayers.enumerated() {
            guard items.indices.contains(index) else {
                layer.isHidden = true
                continue
            }
            let item = items[index]
            let angle = CGFloat(item.angleRadians + phase)
            layer.isHidden = false
            layer.update(item: item, scale: backingScale)
            layer.position = CGPoint(
                x: cos(angle) * radius,
                y: sin(angle) * radius
            )
        }

        if expanded, let title = scene.title, !title.isEmpty {
            let titleFrame = CGRect(x: -90, y: 68, width: 180, height: 27)
            titleBackdrop.isHidden = false
            titleBackdrop.frame = titleFrame
            titleBackdrop.path = CGPath(
                roundedRect: titleFrame,
                cornerWidth: 13.5,
                cornerHeight: 13.5,
                transform: nil
            )
            titleLayer.isHidden = false
            titleLayer.string = title
            titleLayer.frame = titleFrame.insetBy(dx: 10, dy: 6)
            titleLayer.contentsScale = backingScale
        } else {
            titleBackdrop.isHidden = true
            titleLayer.isHidden = true
        }

        if let targetLocal, targetLocal.width > 0, targetLocal.height > 0 {
            targetOutline.isHidden = false
            targetOutline.path = CGPath(
                roundedRect: targetLocal.insetBy(dx: -3, dy: -3),
                cornerWidth: 7,
                cornerHeight: 7,
                transform: nil
            )
        } else {
            targetOutline.isHidden = true
        }

        CATransaction.commit()
    }

    private func cachedSidecarSize(for title: String) -> CGSize {
        guard title != cachedCompactTitle else { return cachedCompactSize }
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let measured = (title as NSString).size(withAttributes: [.font: font]).width
        let size = CGSize(width: min(250, max(200, measured + 34)), height: 38)
        cachedCompactTitle = title
        cachedCompactSize = size
        sidecarLabel.stringValue = title
        return size
    }

    private func makeSidecar() -> (NSView, NSTextField) {
        let label = NSTextField(labelWithString: "")
        label.alignment = .center
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.setAccessibilityElement(false)

        let workspace = NSWorkspace.shared
        let container: NSView
        if workspace.accessibilityDisplayShouldReduceTransparency ||
            workspace.accessibilityDisplayShouldIncreaseContrast
        {
            let solid = NSView(frame: .zero)
            solid.wantsLayer = true
            solid.layer?.cornerRadius = 19
            solid.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            solid.layer?.borderColor = NSColor.separatorColor.cgColor
            solid.layer?.borderWidth = workspace.accessibilityDisplayShouldIncreaseContrast
                ? 2
                : 1
            solid.addSubview(label)
            container = solid
        } else if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: .zero)
            glass.style = .clear
            glass.cornerRadius = 19
            glass.tintColor = NSColor.white.withAlphaComponent(0.08)
            let content = NSView(frame: .zero)
            content.autoresizingMask = [.width, .height]
            content.addSubview(label)
            glass.contentView = content
            container = glass
        } else {
            let material = NSVisualEffectView(frame: .zero)
            material.blendingMode = .behindWindow
            material.material = .popover
            material.state = .active
            material.wantsLayer = true
            material.layer?.cornerRadius = 19
            material.layer?.borderWidth = 0.75
            material.layer?.borderColor = NSColor.white.withAlphaComponent(0.34).cgColor
            material.layer?.shadowColor = NSColor.black.cgColor
            material.layer?.shadowOpacity = 0.18
            material.layer?.shadowRadius = 8
            material.layer?.shadowOffset = CGSize(width: 0, height: -2)
            material.addSubview(label)
            container = material
        }

        container.setAccessibilityElement(false)
        return (container, label)
    }

    @objc
    private func accessibilityDisplayOptionsChanged() {
        let wasHidden = sidecar?.isHidden ?? true
        sidecar?.removeFromSuperview()
        (sidecar, sidecarLabel) = makeSidecar()
        sidecar.isHidden = wasHidden
        cachedCompactTitle = nil
        addSubview(sidecar)
    }
}

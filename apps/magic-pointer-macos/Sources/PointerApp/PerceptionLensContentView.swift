@preconcurrency import AppKit
import PointerCore

@MainActor
final class PerceptionLensContentView: NSView {
    var onCandidateChanged: ((Int) -> Void)?
    var onFeedback: ((PerceptionFeedbackKind) -> Void)?
    var onTryAnother: (() -> Void)?
    var onClose: (() -> Void)?

    let rightObjectButton = NSButton(title: "Correct", target: nil, action: nil)

    private let kindLabel = NSTextField(labelWithString: "UNKNOWN")
    private let titleLabel = NSTextField(labelWithString: "")
    private let previousButton = NSButton(title: "‹", target: nil, action: nil)
    private let positionLabel = NSTextField(labelWithString: "1 of 1")
    private let nextButton = NSButton(title: "›", target: nil, action: nil)
    private let scoreLabel = NSTextField(labelWithString: "—")
    private let cropView = NSImageView()
    private let boundsLabel = NSTextField(labelWithString: "Bounds unknown")
    private let directTextRow = PerceptionFieldRow(title: "Direct text")
    private let ocrTextRow = PerceptionFieldRow(title: "OCR text")
    private let meaningRow = PerceptionFieldRow(title: "Meaning")
    private let sourceRow = PerceptionFieldRow(title: "Source")
    private let statusLabel = NSTextField(labelWithString: "")
    private let problemButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let feedbackStatus = NSTextField(labelWithString: "")
    private let tryAnotherButton = NSButton(title: "Keep scanning", target: nil, action: nil)
    private let closeButton = NSButton(title: "Close", target: nil, action: nil)

    private var model = PerceptionLensViewModel.acquiring(sampleID: UUID())
    private var lastRenderedSampleID: UUID?
    private var lastRenderedCandidateID: PerceptionObjectID?
    private var lastRenderedPhase: PerceptionLensViewModel.Phase?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
        update(model)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Perception Lens")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(_ model: PerceptionLensViewModel) {
        let incomingCandidateID = model.candidates.indices.contains(model.selectedIndex)
            ? model.candidates[model.selectedIndex].id
            : nil
        if model.sampleID != lastRenderedSampleID ||
            incomingCandidateID != lastRenderedCandidateID ||
            model.phase != lastRenderedPhase
        {
            feedbackStatus.stringValue = ""
        }
        self.model = model
        self.model.selectedIndex = min(
            max(model.selectedIndex, 0),
            max(model.candidates.count - 1, 0)
        )
        render()
    }

    func setFeedbackStatus(recorded: Bool) {
        feedbackStatus.stringValue = recorded ? "Recorded" : "Not saved"
        feedbackStatus.textColor = recorded ? .systemGreen : .systemRed
    }

    func selectPrevious() {
        guard model.selectedIndex > 0 else { return }
        model.selectedIndex -= 1
        feedbackStatus.stringValue = ""
        render()
        onCandidateChanged?(model.selectedIndex)
    }

    func selectNext() {
        guard model.selectedIndex + 1 < model.candidates.count else { return }
        model.selectedIndex += 1
        feedbackStatus.stringValue = ""
        render()
        onCandidateChanged?(model.selectedIndex)
    }

    private func configure() {
        kindLabel.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        kindLabel.alignment = .center
        kindLabel.wantsLayer = true
        kindLabel.layer?.cornerRadius = 6
        kindLabel.layer?.backgroundColor = NSColor.systemPurple.withAlphaComponent(0.14).cgColor
        kindLabel.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for button in [previousButton, nextButton] {
            button.bezelStyle = .texturedRounded
            button.controlSize = .small
        }
        previousButton.target = self
        previousButton.action = #selector(previousPressed)
        nextButton.target = self
        nextButton.action = #selector(nextPressed)
        positionLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        positionLabel.textColor = .secondaryLabelColor
        scoreLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        scoreLabel.textColor = .secondaryLabelColor

        let header = NSStackView(views: [
            kindLabel, titleLabel, previousButton, positionLabel, nextButton, scoreLabel,
        ])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 7

        cropView.imageScaling = .scaleProportionallyUpOrDown
        cropView.imageAlignment = .alignCenter
        cropView.wantsLayer = true
        cropView.layer?.cornerRadius = 8
        cropView.layer?.masksToBounds = true
        cropView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.08).cgColor
        boundsLabel.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        boundsLabel.textColor = .tertiaryLabelColor
        boundsLabel.alignment = .center
        boundsLabel.lineBreakMode = .byTruncatingMiddle

        let cropColumn = NSStackView(views: [cropView, boundsLabel])
        cropColumn.orientation = .vertical
        cropColumn.spacing = 4
        cropColumn.alignment = .centerX

        let fields = NSStackView(views: [directTextRow, ocrTextRow, meaningRow, sourceRow])
        fields.orientation = .vertical
        fields.spacing = 5
        fields.distribution = .fillEqually

        let body = NSStackView(views: [cropColumn, fields])
        body.orientation = .horizontal
        body.alignment = .top
        body.spacing = 14

        statusLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        rightObjectButton.bezelStyle = .rounded
        rightObjectButton.controlSize = .regular
        rightObjectButton.keyEquivalent = "\r"
        rightObjectButton.target = self
        rightObjectButton.action = #selector(rightObjectPressed)

        problemButton.addItem(withTitle: "Problem…")
        for feedback in PerceptionFeedbackKind.allCases where feedback != .rightObject {
            problemButton.addItem(withTitle: feedback.rawValue)
        }
        problemButton.target = self
        problemButton.action = #selector(problemSelected)
        feedbackStatus.font = .systemFont(ofSize: 11, weight: .medium)
        feedbackStatus.textColor = .systemGreen

        let feedback = NSStackView(views: [rightObjectButton, problemButton, feedbackStatus])
        feedback.orientation = .horizontal
        feedback.alignment = .centerY
        feedback.spacing = 10

        for button in [tryAnotherButton, closeButton] {
            button.bezelStyle = .rounded
            button.controlSize = .regular
        }
        tryAnotherButton.target = self
        tryAnotherButton.action = #selector(tryAnotherPressed)
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        let footer = NSStackView(views: [tryAnotherButton, closeButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.distribution = .fillEqually
        footer.spacing = 10

        previousButton.nextKeyView = nextButton
        nextButton.nextKeyView = rightObjectButton
        rightObjectButton.nextKeyView = problemButton
        problemButton.nextKeyView = tryAnotherButton
        tryAnotherButton.nextKeyView = closeButton
        closeButton.nextKeyView = previousButton

        let stack = NSStackView(views: [header, body, statusLabel, feedback, footer])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            header.heightAnchor.constraint(equalToConstant: 28),
            body.widthAnchor.constraint(equalTo: stack.widthAnchor),
            body.heightAnchor.constraint(equalToConstant: 144),
            cropView.widthAnchor.constraint(equalToConstant: 120),
            cropView.heightAnchor.constraint(equalToConstant: 120),
            cropColumn.widthAnchor.constraint(equalToConstant: 120),
            fields.heightAnchor.constraint(equalTo: body.heightAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.heightAnchor.constraint(equalToConstant: 20),
            feedback.widthAnchor.constraint(equalTo: stack.widthAnchor),
            feedback.heightAnchor.constraint(equalToConstant: 32),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.heightAnchor.constraint(equalToConstant: 34),
            kindLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 72),
            feedbackStatus.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),
        ])
    }

    private func render() {
        let candidates = model.candidates
        guard candidates.indices.contains(model.selectedIndex) else { return }
        let candidate = candidates[model.selectedIndex]
        kindLabel.stringValue = candidate.kind.rawValue.uppercased()
        titleLabel.stringValue = candidate.title
        positionLabel.stringValue = "\(model.selectedIndex + 1) of \(candidates.count)"
        scoreLabel.stringValue = candidate.score.map {
            String(format: "raw %.2f", $0)
        } ?? "unscored"
        previousButton.isEnabled = model.selectedIndex > 0
        nextButton.isEnabled = model.selectedIndex + 1 < candidates.count
        cropView.image = candidate.crop
        if let bounds = candidate.bounds {
            boundsLabel.stringValue = "Context crop · object \(Int(bounds.size.width))×\(Int(bounds.size.height))"
        } else {
            boundsLabel.stringValue = "Context crop · object bounds unknown"
        }
        directTextRow.update(candidate.directText)
        ocrTextRow.update(candidate.ocrText)
        meaningRow.update(candidate.meaning)
        sourceRow.update(candidate.source)
        statusLabel.stringValue = "\(model.phase.rawValue) · \(model.status)"
        let canAssess = model.phase != .acquiring
        rightObjectButton.isEnabled = canAssess
        problemButton.isEnabled = canAssess
        lastRenderedSampleID = model.sampleID
        lastRenderedCandidateID = candidate.id
        lastRenderedPhase = model.phase
    }

    private func record(_ feedback: PerceptionFeedbackKind) {
        guard model.phase != .acquiring else { return }
        feedbackStatus.stringValue = "Recording…"
        feedbackStatus.textColor = .secondaryLabelColor
        onFeedback?(feedback)
    }

    @objc private func previousPressed() { selectPrevious() }
    @objc private func nextPressed() { selectNext() }
    @objc private func rightObjectPressed() { record(.rightObject) }

    @objc private func problemSelected() {
        defer { problemButton.selectItem(at: 0) }
        guard problemButton.indexOfSelectedItem > 0,
              let title = problemButton.titleOfSelectedItem,
              let feedback = PerceptionFeedbackKind.allCases.first(where: { $0.rawValue == title })
        else { return }
        record(feedback)
    }

    @objc private func tryAnotherPressed() { onTryAnother?() }
    @objc private func closePressed() { onClose?() }
}

@MainActor
private final class PerceptionFieldRow: NSView {
    private let titleLabel: NSTextField
    private let valueLabel = NSTextField(labelWithString: "Unknown")
    private let evidenceLabel = NSTextField(labelWithString: "unknown")

    init(title: String) {
        titleLabel = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        valueLabel.font = .systemFont(ofSize: 11, weight: .regular)
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        evidenceLabel.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        evidenceLabel.textColor = .tertiaryLabelColor
        evidenceLabel.alignment = .right

        let row = NSStackView(views: [titleLabel, valueLabel, evidenceLabel])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            titleLabel.widthAnchor.constraint(equalToConstant: 66),
            evidenceLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 74),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(_ field: PerceptionLensFieldViewModel) {
        valueLabel.stringValue = field.renderedValue
        evidenceLabel.stringValue = field.renderedEvidence
        evidenceLabel.textColor = switch field.knowledge {
        case .observed: .systemGreen
        case .inferred: .systemOrange
        case .ambiguous: .systemYellow
        case .unknown: .tertiaryLabelColor
        }
    }
}

import AppKit
import SwiftUI

// Native (pure AppKit) supervisor-request card — the interactive "the agent needs
// your input" row. Hosted, this card re-ran its whole SwiftUI subtree (and, for
// interview requests, re-decoded JSON) on every keystroke AND every scroll vend,
// which is the dominant hang in supervised sessions. Native, it builds its
// controls once and only re-lays-out on real height changes.
//
// Two shapes, decided up front when the payload is built (no per-render decode):
//   • freeform  → message text + a single multiline NSTextView response box
//   • interview → optional intro + one labelled NSTextField per structured
//                 question (or a read-only "info" line)
// Both end in a Cancel / Send Response button row wired to the callbacks. The
// card is full-width (mirrors the SwiftUI AppRowCard, maxWidth: .infinity).

// MARK: - Payload

struct NativeSupervisorPayload {
    /// One field in an interview request, or the single freeform response box.
    struct Field {
        /// Stable key sent back in the structured response (freeform uses "").
        var id: String
        /// Bold label above the control (freeform has none).
        var label: String?
        /// Placeholder / info text.
        var placeholder: String?
        /// Read-only "info" rows show `placeholder` as muted text, no input.
        var isInfo: Bool
        /// Required fields gate the Send button (info rows never required).
        var isRequired: Bool
    }

    var title: String
    /// Intro / message text shown above the fields (freeform: the request message;
    /// interview: the decoded prompt/message). May be empty.
    var message: String
    var fields: [Field]
    /// True when this is a structured interview (responses serialize to JSON).
    var isInterview: Bool

    var onRespond: (String) -> Void
    var onCancel: () -> Void
}

extension NativeSupervisorPayload {
    private static let jsonDecoder = JSONDecoder()

    @MainActor
    static func make(
        request: PiSubagentSupervisorRequest,
        onRespond: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) -> NativeSupervisorPayload {
        if request.kind == .interviewRequest, let interview = decodeInterview(request.message) {
            let intro = (interview.prompt ?? interview.message)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let fields = interview.questions.map { question -> Field in
                let isInfo = (question.type == "info")
                return Field(
                    id: question.id,
                    label: question.labelText,
                    placeholder: question.placeholder ?? (isInfo ? "No response required." : "Response"),
                    isInfo: isInfo,
                    isRequired: !isInfo && question.required != false
                )
            }
            return NativeSupervisorPayload(
                title: request.title,
                message: intro,
                fields: fields,
                isInterview: true,
                onRespond: onRespond,
                onCancel: onCancel
            )
        }

        // Freeform: message + one multiline response box.
        return NativeSupervisorPayload(
            title: request.title,
            message: request.message,
            fields: [Field(id: "", label: nil, placeholder: "Response", isInfo: false, isRequired: true)],
            isInterview: false,
            onRespond: onRespond,
            onCancel: onCancel
        )
    }

    private static func decodeInterview(_ message: String) -> InterviewPayload? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonText: String
        if trimmed.hasPrefix("```") {
            jsonText = trimmed
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            jsonText = trimmed
        }
        guard let data = jsonText.data(using: .utf8),
              let payload = try? jsonDecoder.decode(InterviewPayload.self, from: data),
              !payload.questions.isEmpty else { return nil }
        return payload
    }

    private struct InterviewPayload: Codable {
        var prompt: String?
        var message: String?
        var questions: [InterviewQuestion]
    }

    private struct InterviewQuestion: Codable {
        var id: String
        var label: String?
        var question: String?
        var type: String?
        var required: Bool?
        var placeholder: String?

        var labelText: String { label ?? question ?? id }
    }
}

// MARK: - One field control (label + input, or info line)

/// A single labelled response field. Wraps a multiline NSTextView (so it grows
/// like the SwiftUI vertical AppTextField / TextEditor) inside a rounded fill,
/// or — for "info" rows — just a muted text line. Reports edits and height
/// changes upward so the card re-measures and the table re-tiles.
private final class PiAgentNativeSupervisorField: NSView {
    private let labelField = NSTextField(labelWithString: "")
    private let infoField = NSTextField(wrappingLabelWithString: "")
    private let inputSurface = NativeCardSurface()
    private let textView = NSTextView()
    private let scroll = NSScrollView()

    private(set) var fieldID: String = ""
    private(set) var isInfo = false
    private(set) var isRequired = false

    /// Text typed by the user (trimmed when read for the response).
    var text: String { textView.string }

    var onEdited: (() -> Void)?
    var onHeightChange: (() -> Void)?

    private let labelToInput: CGFloat = 5
    private let inputInset: CGFloat = 6
    private let minInputHeight: CGFloat = 76
    private var inputHeightC: NSLayoutConstraint!
    // Bottom pins linking the visible control to the field's own bottom so the
    // field height is deterministic (= its content). Without one the field is
    // vertically ambiguous and the input box overflows under the button row.
    private var inputBottomC: NSLayoutConstraint!
    private var infoBottomC: NSLayoutConstraint!
    // Top pins, toggled by label presence. With a label the control hangs off the
    // label's bottom; without one it pins to the field's top — matching
    // `measuredHeight`, which only counts the label + gap when a label is shown.
    // (A hidden NSTextField still claims its line height, so pinning to it always
    // would add a phantom gap the measurement doesn't account for.)
    private var inputTopWithLabelC: NSLayoutConstraint!
    private var inputTopNoLabelC: NSLayoutConstraint!
    private var infoTopWithLabelC: NSLayoutConstraint!
    private var infoTopNoLabelC: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        labelField.translatesAutoresizingMaskIntoConstraints = false
        labelField.font = NativeTranscriptFont.caption(.semibold)
        labelField.textColor = .labelColor
        labelField.lineBreakMode = .byWordWrapping
        labelField.maximumNumberOfLines = 0
        addSubview(labelField)

        infoField.translatesAutoresizingMaskIntoConstraints = false
        infoField.font = NativeTranscriptFont.caption()
        infoField.textColor = AppTheme.ns(AppTheme.mutedText)
        infoField.maximumNumberOfLines = 0
        addSubview(infoField)

        inputSurface.translatesAutoresizingMaskIntoConstraints = false
        inputSurface.cardCornerRadius = AppTheme.Chat.codeCornerRadius
        inputSurface.fillColor = AppTheme.ns(AppTheme.contentSubtleFill.opacity(0.5))
        inputSurface.strokeColor = AppTheme.ns(AppTheme.contentStroke)
        addSubview(inputSurface)

        textView.delegate = self
        textView.isRichText = false
        textView.font = NativeTranscriptFont.callout()
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 2, height: 2)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.documentView = textView
        inputSurface.addSubview(scroll)

        inputHeightC = inputSurface.heightAnchor.constraint(equalToConstant: minInputHeight)
        inputBottomC = inputSurface.bottomAnchor.constraint(equalTo: bottomAnchor)
        infoBottomC = infoField.bottomAnchor.constraint(equalTo: bottomAnchor)
        inputTopWithLabelC = inputSurface.topAnchor.constraint(equalTo: labelField.bottomAnchor, constant: labelToInput)
        inputTopNoLabelC = inputSurface.topAnchor.constraint(equalTo: topAnchor)
        infoTopWithLabelC = infoField.topAnchor.constraint(equalTo: labelField.bottomAnchor, constant: labelToInput)
        infoTopNoLabelC = infoField.topAnchor.constraint(equalTo: topAnchor)
        // Freeform default: an unlabelled input box owning the full field height.
        // `configure` swaps these for labelled / info-row shapes.
        inputTopNoLabelC.isActive = true
        inputBottomC.isActive = true

        NSLayoutConstraint.activate([
            labelField.topAnchor.constraint(equalTo: topAnchor),
            labelField.leadingAnchor.constraint(equalTo: leadingAnchor),
            labelField.trailingAnchor.constraint(equalTo: trailingAnchor),

            infoField.leadingAnchor.constraint(equalTo: leadingAnchor),
            infoField.trailingAnchor.constraint(equalTo: trailingAnchor),

            inputSurface.leadingAnchor.constraint(equalTo: leadingAnchor),
            inputSurface.trailingAnchor.constraint(equalTo: trailingAnchor),
            inputHeightC,

            scroll.topAnchor.constraint(equalTo: inputSurface.topAnchor, constant: inputInset),
            scroll.leadingAnchor.constraint(equalTo: inputSurface.leadingAnchor, constant: inputInset),
            scroll.trailingAnchor.constraint(equalTo: inputSurface.trailingAnchor, constant: -inputInset),
            scroll.bottomAnchor.constraint(equalTo: inputSurface.bottomAnchor, constant: -inputInset)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    func configure(_ field: NativeSupervisorPayload.Field) {
        fieldID = field.id
        isInfo = field.isInfo
        isRequired = field.isRequired

        let hasLabel = (field.label?.isEmpty == false)
        if hasLabel {
            labelField.stringValue = field.label ?? ""
            labelField.isHidden = false
        } else {
            labelField.isHidden = true
        }

        // Pin the visible control's top (to the label when present, else the
        // field top) and its bottom to the field bottom, so the field height is
        // deterministic and matches `measuredHeight` in every shape.
        inputTopWithLabelC.isActive = false
        inputTopNoLabelC.isActive = false
        infoTopWithLabelC.isActive = false
        infoTopNoLabelC.isActive = false
        inputBottomC.isActive = false
        infoBottomC.isActive = false
        if field.isInfo {
            infoField.stringValue = field.placeholder ?? "No response required."
            infoField.isHidden = false
            inputSurface.isHidden = true
            scroll.isHidden = true
            (hasLabel ? infoTopWithLabelC : infoTopNoLabelC).isActive = true
            infoBottomC.isActive = true
        } else {
            infoField.isHidden = true
            inputSurface.isHidden = false
            scroll.isHidden = false
            textView.string = ""
            (textView.textStorage)?.font = NativeTranscriptFont.callout()
            (hasLabel ? inputTopWithLabelC : inputTopNoLabelC).isActive = true
            inputBottomC.isActive = true
        }
    }

    /// Height of this field at the given content width.
    func measuredHeight(forWidth width: CGFloat) -> CGFloat {
        var h: CGFloat = 0
        if !labelField.isHidden {
            labelField.preferredMaxLayoutWidth = width
            h += ceil(labelField.intrinsicContentSize.height)
        }
        if isInfo {
            if !labelField.isHidden { h += labelToInput }
            infoField.preferredMaxLayoutWidth = width
            h += ceil(infoField.intrinsicContentSize.height)
            return ceil(h)
        }
        if !labelField.isHidden { h += labelToInput }
        // Grow the box to fit the typed text (single box, like the freeform
        // TextEditor / vertical AppTextField) but never below the min height.
        let textWidth = max(1, width - inputInset * 2 - 4)
        let typedH = measuredTextHeight(forWidth: textWidth)
        let boxH = max(minInputHeight, ceil(typedH + inputInset * 2 + 4))
        inputHeightC.constant = boxH
        h += boxH
        return ceil(h)
    }

    private func measuredTextHeight(forWidth width: CGFloat) -> CGFloat {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return 0 }
        tc.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        return ceil(lm.usedRect(for: tc).height)
    }
}

extension PiAgentNativeSupervisorField: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        onEdited?()
        onHeightChange?()
    }
}

// MARK: - Supervisor card

final class PiAgentNativeSupervisorCardView: NSView, PiAgentNativeRowContent {
    private let surface = NativeCardSurface()
    private let titleIcon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let message = PiAgentNativeExpandableMarkdown()
    private let fieldStack = NSStackView()
    private let cancelButton = NSButton()
    private let sendButton = NSButton()

    private var fields: [PiAgentNativeSupervisorField] = []
    private var payload: NativeSupervisorPayload?

    var onIntrinsicHeightChange: (() -> Void)?

    private let pad: CGFloat = 14
    private let titleToMessage: CGFloat = 10
    private let messageToFields: CGFloat = 10
    private let fieldSpacing: CGFloat = 10
    private let fieldsToButtons: CGFloat = 10
    private var surfaceWidthC: NSLayoutConstraint!
    private var hasMessage = false

    required init() {
        super.init(frame: .zero)
        wantsLayer = true

        surface.translatesAutoresizingMaskIntoConstraints = false
        surface.cardCornerRadius = 14
        addSubview(surface)

        titleIcon.translatesAutoresizingMaskIntoConstraints = false
        titleIcon.image = NSImage(systemSymbolName: "questionmark.bubble", accessibilityDescription: nil)
        // Blocked/attention tint follows the theme (same hue the run cards use
        // for the blocked status), not a fixed system orange.
        titleIcon.contentTintColor = AppTheme.ns(AppTheme.roleTool)
        titleIcon.imageScaling = .scaleProportionallyUpOrDown
        titleIcon.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.preferredFont(forTextStyle: .headline)
        titleLabel.textColor = AppTheme.ns(AppTheme.roleTool)
        titleLabel.lineBreakMode = .byTruncatingTail

        message.onToggle = { [weak self] in self?.onIntrinsicHeightChange?() }

        fieldStack.translatesAutoresizingMaskIntoConstraints = false
        fieldStack.orientation = .vertical
        fieldStack.alignment = .leading
        fieldStack.spacing = fieldSpacing

        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)

        sendButton.title = "Send Response"
        sendButton.bezelStyle = .rounded
        sendButton.keyEquivalent = "\r"
        sendButton.target = self
        sendButton.action = #selector(sendTapped)

        let buttonRow = NSStackView(views: [NSView(), cancelButton, sendButton])
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.alignment = .centerY

        surface.addSubview(titleIcon)
        surface.addSubview(titleLabel)
        surface.addSubview(message)
        surface.addSubview(fieldStack)
        surface.addSubview(buttonRow)

        let buttonBottom = buttonRow.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -pad)
        buttonBottom.priority = NSLayoutConstraint.Priority(999)

        surfaceWidthC = surface.widthAnchor.constraint(equalToConstant: 100)
        messageTopToFieldsC = fieldStack.topAnchor.constraint(equalTo: message.bottomAnchor, constant: messageToFields)
        titleTopToFieldsC = fieldStack.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: titleToMessage)

        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surfaceWidthC,

            titleIcon.topAnchor.constraint(equalTo: surface.topAnchor, constant: pad),
            titleIcon.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: pad),
            titleIcon.widthAnchor.constraint(equalToConstant: 16),
            titleIcon.heightAnchor.constraint(equalToConstant: 16),
            titleLabel.centerYAnchor.constraint(equalTo: titleIcon.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: titleIcon.trailingAnchor, constant: 6),
            titleLabel.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -pad),

            message.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: titleToMessage),
            message.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: pad),
            message.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -pad),

            fieldStack.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: pad),
            fieldStack.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -pad),

            buttonRow.topAnchor.constraint(equalTo: fieldStack.bottomAnchor, constant: fieldsToButtons),
            buttonRow.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: pad),
            buttonRow.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -pad),
            buttonBottom
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    private var messageTopToFieldsC: NSLayoutConstraint!
    private var titleTopToFieldsC: NSLayoutConstraint!

    func configure(payload: NativeSupervisorPayload, width rowWidth: CGFloat) {
        self.payload = payload
        surface.fillColor = AppTheme.ns(AppTheme.Chat.cardFill)
        surface.strokeColor = AppTheme.ns(AppTheme.Chat.cardStroke)
        surfaceWidthC.constant = max(1, rowWidth)

        titleLabel.stringValue = payload.title

        let trimmedMessage = payload.message.trimmingCharacters(in: .whitespacesAndNewlines)
        hasMessage = !trimmedMessage.isEmpty
        message.isHidden = !hasMessage
        if hasMessage { message.configure(source: payload.message) }

        // The field stack pins under the message when present, else under the title.
        messageTopToFieldsC.isActive = hasMessage
        titleTopToFieldsC.isActive = !hasMessage

        rebuildFields(payload.fields)
        updateSendEnabled()
        needsLayout = true
    }

    private func rebuildFields(_ specs: [NativeSupervisorPayload.Field]) {
        if fields.count != specs.count {
            fieldStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            fields.removeAll()
            for _ in specs {
                let field = PiAgentNativeSupervisorField()
                field.onEdited = { [weak self] in self?.updateSendEnabled() }
                field.onHeightChange = { [weak self] in self?.onIntrinsicHeightChange?() }
                fieldStack.addArrangedSubview(field)
                field.widthAnchor.constraint(equalTo: fieldStack.widthAnchor).isActive = true
                fields.append(field)
            }
        }
        for (i, spec) in specs.enumerated() { fields[i].configure(spec) }
    }

    // MARK: Send gating (mirror SwiftUI `canRespond`)

    private func updateSendEnabled() {
        sendButton.isEnabled = canRespond()
    }

    private func canRespond() -> Bool {
        let requiredInputs = fields.filter { !$0.isInfo && $0.isRequired }
        if requiredInputs.isEmpty {
            // No required fields: at least one non-info field must be non-empty.
            return fields.contains { !$0.isInfo && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        return requiredInputs.allSatisfy { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    // MARK: Response payload (mirror SwiftUI `responsePayload`)

    private func responsePayload() -> String {
        guard let payload, payload.isInterview else {
            return fields.first?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        let responses: [[String: String]] = fields
            .filter { !$0.isInfo }
            .map { ["id": $0.fieldID, "value": $0.text.trimmingCharacters(in: .whitespacesAndNewlines)] }
        let object: [String: Any] = ["responses": responses]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{\"responses\":[]}" }
        return text
    }

    @objc private func cancelTapped() { payload?.onCancel() }
    @objc private func sendTapped() {
        guard canRespond() else { return }
        payload?.onRespond(responsePayload())
    }

    // MARK: Measure

    func measuredHeight(forWidth rowWidth: CGFloat) -> CGFloat {
        let inner = max(1, max(1, rowWidth) - pad * 2)
        var h = pad
        h += max(16, ceil(titleLabel.intrinsicContentSize.height))
        if hasMessage {
            h += titleToMessage + message.measuredHeight(forWidth: inner)
            h += messageToFields
        } else {
            h += titleToMessage
        }
        for (i, field) in fields.enumerated() {
            if i > 0 { h += fieldSpacing }
            h += field.measuredHeight(forWidth: inner)
        }
        h += fieldsToButtons
        h += max(20, ceil(sendButton.intrinsicContentSize.height))
        h += pad
        return ceil(h)
    }

    func prepareForReuseIfNeeded() { message.cancel() }
}

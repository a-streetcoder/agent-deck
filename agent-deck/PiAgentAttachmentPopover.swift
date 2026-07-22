import AppKit

// Native (pure AppKit) preview popover for a question card's attachment chips.
// Presented from `PiAgentNativeChipView` via `NSPopover`; replaces the old
// SwiftUI `.popover` so the transcript row stays fully native.
//
// Each attachment kind builds its own content view (image, file text, folder
// path, paste / issue / skill / command body). Long text scrolls; everything
// else sizes to content. The popover itself sizes to this controller's view
// fitting size.

final class PiAgentAttachmentPopoverController: NSViewController {
    private let attachment: NativeQuestionChip.Attachment

    /// Fixed popover width; the body lays out within `contentWidth`.
    private static let popoverWidth: CGFloat = 420
    private static let pad: CGFloat = 12
    private static var contentWidth: CGFloat { popoverWidth - pad * 2 }
    private static let maxBodyHeight: CGFloat = 320

    init(attachment: NativeQuestionChip.Attachment) {
        self.attachment = attachment
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.addArrangedSubview(makeHeader())
        let body = makeBody()
        stack.addArrangedSubview(body)
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.popoverWidth),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.pad),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Self.pad),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.pad),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.pad),
            body.widthAnchor.constraint(equalToConstant: Self.contentWidth)
        ])
        view = root
    }

    // MARK: Header

    private func makeHeader() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: iconSymbol, accessibilityDescription: nil)
        icon.contentTintColor = AppTheme.ns(AppTheme.brandAccent)
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let title = NSTextField(labelWithString: titleText)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingMiddle
        title.maximumNumberOfLines = 1

        row.addArrangedSubview(icon)
        row.addArrangedSubview(title)
        row.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        return row
    }

    // MARK: Body

    private func makeBody() -> NSView {
        switch attachment {
        case .image(let image):
            return imageBody(image)
        case .file(_, let path):
            return fileBody(path: path)
        case .folder(let path):
            return folderBody(path: path)
        case .paste(let paste):
            return codeScroll(paste.text)
        case .issue(let issue):
            return infoScroll(issueText(issue))
        case .skill(let name, let record):
            return skillBody(name: name, record: record)
        case .command(let name):
            return commandBody(name: name)
        case .missing:
            return emptyLabel("Preview is not available for older attachment metadata.")
        }
    }

    private func imageBody(_ image: PiAgentImageAttachment) -> NSView {
        guard let nsImage = PiAgentComposerImageLoader.previewImage(for: image) else {
            return emptyLabel("Preview is not available for this image.")
        }
        let container = roundedContainer()
        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.image = nsImage
        imageView.imageScaling = .scaleProportionallyUpOrDown
        container.addSubview(imageView)

        let size = nsImage.size
        let aspect = size.width > 0 ? size.height / size.width : 1
        let displayH = min(240, max(60, Self.contentWidth * aspect))

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            imageView.heightAnchor.constraint(equalToConstant: displayH)
        ])
        return container
    }

    private func fileBody(path: String?) -> NSView {
        guard let path else {
            return emptyLabel("Preview is not available for this attachment.")
        }
        if let text = Self.textPreview(atPath: path) {
            return codeScroll(text)
        }
        // Unreadable / binary: show a hint plus the path.
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.addArrangedSubview(captionLabel("Preview is not available for this file type."))
        stack.addArrangedSubview(pathLabel(path))
        return stack
    }

    private func folderBody(path: String) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.addArrangedSubview(pathLabel(path))

        let reveal = NSButton(title: "Reveal in Finder", target: self, action: #selector(revealFolder))
        reveal.bezelStyle = .rounded
        reveal.controlSize = .small
        revealPath = path
        stack.addArrangedSubview(reveal)
        return stack
    }

    private func skillBody(name: String, record: SkillRecord?) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        if let description = record?.description, !description.isEmpty {
            let label = NSTextField(wrappingLabelWithString: description)
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
            stack.addArrangedSubview(label)
        }
        let body = record?.body.isEmpty == false
            ? record!.body
            : (record?.filePath ?? "Skill details are not available in the current scan snapshot.")
        stack.addArrangedSubview(codeScroll(body))
        return stack
    }

    private func commandBody(name: String) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.addArrangedSubview(captionLabel("Command invocation sent to Pi."))
        let container = roundedContainer()
        let code = NSTextField(labelWithString: "/\(name)")
        code.translatesAutoresizingMaskIntoConstraints = false
        code.font = .monospacedSystemFont(ofSize: AppTheme.Font.codeSize, weight: .regular)
        code.textColor = .labelColor
        code.isSelectable = true
        container.addSubview(code)
        NSLayoutConstraint.activate([
            code.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            code.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            code.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            code.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -8)
        ])
        stack.addArrangedSubview(container)
        return stack
    }

    // MARK: Reveal in Finder

    private var revealPath: String?
    @objc private func revealFolder() {
        guard let revealPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: revealPath, isDirectory: true)])
    }

    // MARK: Reusable pieces

    /// Read-only, selectable, scrolling monospaced text — sized to content up to
    /// the body height cap.
    private func codeScroll(_ text: String) -> NSView {
        textScroll(text, font: .monospacedSystemFont(ofSize: AppTheme.Font.codeSize, weight: .regular))
    }

    private func infoScroll(_ text: String) -> NSView {
        textScroll(text, font: .systemFont(ofSize: AppTheme.Font.supportingSize))
    }

    private func textScroll(_ text: String, font: NSFont) -> NSView {
        let inset: CGFloat = 8
        let textWidth = Self.contentWidth - inset * 2

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = font
        textView.textColor = .labelColor
        textView.string = String(text.prefix(12_000))
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: textWidth, height: 0)
        textView.maxSize = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
        textView.frame = NSRect(x: 0, y: 0, width: textWidth, height: 10)

        if let layoutManager = textView.layoutManager, let container = textView.textContainer {
            layoutManager.ensureLayout(for: container)
        }
        let used = textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 60
        let bodyHeight = min(Self.maxBodyHeight, max(40, ceil(used)))

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = textView
        textView.autoresizingMask = [.width]

        let container = roundedContainer()
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: inset),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -inset),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
            scroll.heightAnchor.constraint(equalToConstant: bodyHeight)
        ])
        return container
    }

    private func roundedContainer() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.cornerRadius = 8
        container.layer?.cornerCurve = .continuous
        container.layer?.backgroundColor = AppTheme.ns(AppTheme.contentSubtleFill).cgColor
        return container
    }

    private func captionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        return label
    }

    private func pathLabel(_ path: String) -> NSTextField {
        let label = NSTextField(labelWithString: path)
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = AppTheme.ns(AppTheme.mutedText)
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 3
        label.isSelectable = true
        label.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        return label
    }

    private func emptyLabel(_ text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = AppTheme.ns(AppTheme.mutedText)
        label.alignment = .center
        label.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        label.heightAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
        return label
    }

    // MARK: Content text

    private func issueText(_ issue: PiAgentIssueAttachment) -> String {
        var lines: [String] = []
        lines.append(issue.repository)
        lines.append("\(issue.kindTitle) #\(issue.number) \(issue.title)")
        if let author = issue.author, !author.isEmpty { lines.append("Author: \(author)") }
        lines.append("State: \(issue.state)")
        if !issue.labels.isEmpty { lines.append("Labels: \(issue.labels.joined(separator: ", "))") }
        lines.append("Comments: \(issue.comments.count)")
        let body = issue.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { lines.append("\n\(body)") }
        if !issue.comments.isEmpty {
            let comments = issue.comments.map { comment in
                "\(comment.author) · \(comment.createdAt.formatted(date: .abbreviated, time: .shortened))\n\(comment.body)"
            }.joined(separator: "\n\n")
            lines.append("\n\(comments)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Title / icon

    private var titleText: String {
        switch attachment {
        case .image(let image): return image.name
        case .file(let name, _): return name
        case .folder(let path): return URL(fileURLWithPath: path, isDirectory: true).lastPathComponent
        case .paste(let paste): return paste.marker
        case .issue(let issue): return "\(issue.kindShortTitle) #\(issue.number) \(issue.title)"
        case .skill(let name, let record): return record?.name ?? name
        case .command(let name): return "/\(name)"
        case .missing(let name): return name
        }
    }

    private var iconSymbol: String {
        switch attachment {
        case .image, .missing: return "photo"
        case .file: return "doc.text"
        case .folder: return "folder"
        case .paste: return "doc.plaintext"
        case .issue: return "exclamationmark.circle"
        case .skill: return "sparkles"
        case .command: return "terminal"
        }
    }

    // MARK: File reading

    /// Reads up to 64KB of a text file, trying a few encodings. Returns nil for
    /// unreadable or binary content.
    private static func textPreview(atPath path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024), !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? String(data: data, encoding: .macOSRoman)
    }
}

import AppKit
import SwiftUI

// Native (pure AppKit) rendering for the user-question (and steering) transcript
// row that carries attachment / skill / command chips. This replaces the hosted
// SwiftUI question card so scrolling never re-runs SwiftUI layout or re-parses
// markdown on the layout pass.
//
// Layout mirrors the SwiftUI question row: a hugged-width, right-aligned card
// (role-tinted rounded chrome) holding a "You" header, an optional wrapping row
// of chip pills (icon + label; image chips show a small thumbnail), then the
// message body via the shared expandable-markdown container. The hover-revealed
// copy (+ fork) glass buttons float in the gutter to the LEFT of the card,
// never overlapping it and never affecting its height.
//
// The card width, right-alignment, and the leading glass copy/fork gutter follow
// the same approach as the plain-text question bubble, reimplemented here so the
// hard-won text bubble stays untouched.

// MARK: - Payload

/// A single chip rendered in the question card's chip row. Plain display values
/// only — the configure path never re-parses.
struct NativeQuestionChip {
    enum Kind { case image, file, folder, issue, skill, command, paste, missing }
    var kind: Kind
    /// SF Symbol for the leading glyph (ignored when `thumbnail` is set).
    var systemImage: String
    var label: String
    /// Image chips: a small thumbnail (already decoded). When set, the chip
    /// renders the image instead of the glyph.
    var thumbnail: NSImage?
}

/// Typed payload for a native user-question card. Built once in the items pass;
/// the cell configures a `PiAgentNativeQuestionView` from it.
struct NativeQuestionPayload {
    var markdownSource: String
    var chips: [NativeQuestionChip]
    var copyText: String
    /// Hover-revealed fork affordance (reuses the bubble's `ForkModel`).
    var fork: ForkModel?
    /// Header label + icon — "You"/person for questions, "Steering"/forward-arrow
    /// for steering messages.
    var headerTitle: String = "You"
    var headerIcon: String = "person.fill"

    /// Pre-measured natural chip-row width (from `displayChipsNaturalWidth`) so
    /// the card can grow to fit wide pills within the cap, matching the bubble.
    var chipsNaturalWidth: CGFloat
}

extension NativeQuestionPayload {
    /// Build a payload from an entry, single-sourcing the message text and the
    /// chip-row width through `PiAgentUserMessageContent`'s public helpers. The
    /// chip MODELS are derived from the same attachment data the SwiftUI view
    /// uses (the per-chip parsing helpers there are private, so the minimal
    /// subset is reproduced here from `entry.text` / `entry.rawJSON`).
    @MainActor
    static func make(
        entry: PiAgentTranscriptEntry,
        skills: [SkillRecord],
        commandSlashNames: Set<String>,
        fork: ForkModel?
    ) -> NativeQuestionPayload {
        let text = PiAgentUserMessageContent.displayMessageText(
            for: entry, skills: skills, commandSlashNames: commandSlashNames
        )
        let chips = QuestionChipExtractor.chips(
            for: entry, skills: skills, commandSlashNames: commandSlashNames
        )
        let chipsWidth = PiAgentUserMessageContent.displayChipsNaturalWidth(
            for: entry, skills: skills, commandSlashNames: commandSlashNames
        )
        return NativeQuestionPayload(
            markdownSource: text,
            chips: chips,
            copyText: entry.text,
            fork: fork,
            chipsNaturalWidth: chipsWidth
        )
    }
}

// MARK: - Chip extraction (mirrors PiAgentUserMessageContent's private parsing)

/// Reproduces the minimal subset of `PiAgentUserMessageContent`'s attachment
/// parsing needed to build chip models. Its private helpers can't be called
/// from here, so this single-purpose extractor mirrors the same regexes and
/// payload decode. Text + width still flow through that view's public helpers.
@MainActor
private enum QuestionChipExtractor {
    private static let jsonDecoder = JSONDecoder()
    private static let imageExtensions = ["png", "jpg", "jpeg", "gif", "webp", "tiff", "heic"]

    private struct AttachmentPayload: Decodable {
        let images: [PiAgentImageAttachment]?
        let pastes: [PiAgentPasteAttachment]?
        let issue: PiAgentIssueAttachment?
        let files: [FilePayload]?
    }
    private struct FilePayload: Decodable { let name: String; let path: String }

    static func chips(
        for entry: PiAgentTranscriptEntry,
        skills: [SkillRecord],
        commandSlashNames: Set<String>
    ) -> [NativeQuestionChip] {
        let payload = attachmentPayload(for: entry)
        let (skillInvocation, bareSlash, messageBody) = slashInvocation(for: entry)

        var chips: [NativeQuestionChip] = []

        // Skill chip — `/skill:name` prefix, or an inactive-skill body match.
        if let name = skillInvocation {
            chips.append(.init(kind: .skill, systemImage: "sparkles", label: name))
        } else if let match = inactiveSkillMatch(messageBody: messageBody, skillInvocation: skillInvocation, bareSlash: bareSlash, skills: skills) {
            chips.append(.init(kind: .skill, systemImage: "sparkles", label: match.name))
        }
        // Command chip — only when the bare slash matches an active command.
        if let name = bareSlash, commandSlashNames.contains(name) {
            chips.append(.init(kind: .command, systemImage: "terminal", label: name))
        }
        // Issue chip.
        if let issue = payload?.issue {
            chips.append(.init(kind: .issue, systemImage: "exclamationmark.circle", label: "#\(issue.number) \(issue.title)"))
        }

        // Image chips (payload first, then legacy basename-only listings).
        let imageAttachments = payload?.images ?? []
        for image in imageAttachments.prefix(6) {
            chips.append(.init(
                kind: .image, systemImage: "photo", label: image.name,
                thumbnail: thumbnail(for: image)
            ))
        }
        let legacyNames = legacyImageNames(in: entry.text).filter { name in
            !imageAttachments.contains { $0.name == name }
        }
        for name in legacyNames.prefix(max(0, 6 - imageAttachments.count)) {
            chips.append(.init(kind: .missing, systemImage: "photo", label: name))
        }

        // File chips (payload + inline <file> tags + listed basenames; images excluded).
        for file in fileAttachments(for: entry, payload: payload).prefix(6) {
            chips.append(.init(kind: .file, systemImage: "doc.text", label: file))
        }
        // Folder chips.
        for folder in folderAttachments(in: entry.text).prefix(6) {
            chips.append(.init(kind: .folder, systemImage: "folder", label: folder))
        }
        // Paste chips.
        for paste in (payload?.pastes ?? []).prefix(6) {
            chips.append(.init(kind: .paste, systemImage: "doc.plaintext", label: paste.marker))
        }
        return chips
    }

    // MARK: Payload decode

    private static func attachmentPayload(for entry: PiAgentTranscriptEntry) -> AttachmentPayload? {
        guard let rawJSON = entry.rawJSON, let data = rawJSON.data(using: .utf8) else { return nil }
        return try? jsonDecoder.decode(AttachmentPayload.self, from: data)
    }

    private static func thumbnail(for image: PiAgentImageAttachment) -> NSImage? {
        guard let data = Data(base64Encoded: image.data) else { return nil }
        return NSImage(data: data)
    }

    // MARK: Slash invocation (mirrors extractSlashInvocation, applied to the
    // tag/folder/paste-stripped base text).

    private static func slashInvocation(for entry: PiAgentTranscriptEntry) -> (skill: String?, bareSlash: String?, body: String) {
        let markers = ["Attached files:", "Attached images:"]
        let firstRange = markers.compactMap { entry.text.range(of: $0) }.min { $0.lowerBound < $1.lowerBound }
        let base = firstRange.map { String(entry.text[..<$0.lowerBound]) } ?? entry.text
        let pastes = (attachmentPayload(for: entry)?.pastes ?? []).map(\.marker)
        var stripped = base
        for marker in pastes { stripped = stripped.replacingOccurrences(of: marker, with: "") }
        stripped = removingFileTags(from: stripped)
        stripped = removingFolderReferences(from: stripped)
        stripped = stripped.trimmingCharacters(in: .whitespacesAndNewlines)

        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), trimmed.count > 1 else { return (nil, nil, trimmed) }
        if trimmed.hasPrefix("/skill:") {
            let afterPrefix = trimmed.dropFirst("/skill:".count)
            let nameEnd = afterPrefix.firstIndex(where: { $0.isWhitespace || $0.isNewline }) ?? afterPrefix.endIndex
            let name = String(afterPrefix[..<nameEnd])
            guard !name.isEmpty else { return (nil, nil, trimmed) }
            let remaining = String(afterPrefix[nameEnd...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return (name, nil, remaining)
        }
        let afterSlash = trimmed.dropFirst()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-:"))
        let nameEnd = afterSlash.firstIndex(where: { ch in
            guard let scalar = ch.unicodeScalars.first else { return true }
            return !allowed.contains(scalar)
        }) ?? afterSlash.endIndex
        let name = String(afterSlash[..<nameEnd])
        guard !name.isEmpty else { return (nil, nil, trimmed) }
        let remaining = String(afterSlash[nameEnd...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (nil, name, remaining)
    }

    private static func inactiveSkillMatch(
        messageBody: String, skillInvocation: String?, bareSlash: String?, skills: [SkillRecord]
    ) -> (name: String, remaining: String)? {
        guard skillInvocation == nil, bareSlash == nil else { return nil }
        let trimmed = messageBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for skill in skills {
            let body = skill.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty, trimmed.count >= body.count else { continue }
            if trimmed == body { return (skill.name, "") }
            if trimmed.hasPrefix(body + "\n\n") {
                let remaining = String(trimmed.dropFirst(body.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                return (skill.name, remaining)
            }
        }
        return nil
    }

    // MARK: File / folder / image listing

    private static func fileAttachments(for entry: PiAgentTranscriptEntry, payload: AttachmentPayload?) -> [String] {
        let payloadFiles = (payload?.files ?? []).map(\.name).filter { !isImageName($0) }
        let payloadNames = Set(payloadFiles)
        let tagged = inlineFileTags(in: entry.text)
            .filter { !isImageName($0) && !payloadNames.contains($0) }
        let listed = attachmentLines(after: "Attached files:", in: entry.text).compactMap { line -> String? in
            guard !line.contains("<image ") else { return nil }
            guard !payloadNames.contains(line) else { return nil }
            return line
        }
        var seen = Set<String>()
        return (payloadFiles + tagged + listed).filter { seen.insert($0).inserted }
    }

    private static func legacyImageNames(in text: String) -> [String] {
        let imageLines = attachmentLines(after: "Attached images:", in: text)
            + attachmentLines(after: "Attached files:", in: text).filter { $0.contains("<image ") }
        let fromLines = imageLines.compactMap(imageName(from:))
        let fromTags = inlineFileTags(in: text).filter { isImageName($0) }
        var seen = Set<String>()
        return (fromLines + fromTags).filter { seen.insert($0).inserted }
    }

    private static func folderAttachments(in text: String) -> [String] {
        var seen = Set<String>()
        return folderReferences(in: text)
            .map { URL(fileURLWithPath: $0, isDirectory: true).lastPathComponent }
            .filter { seen.insert($0).inserted }
    }

    // MARK: Regex helpers (mirror PiAgentUserMessageContent)

    private static func attachmentLines(after marker: String, in text: String) -> [String] {
        guard let range = text.range(of: marker) else { return [] }
        let tail = text[range.upperBound...]
        let stop = marker == "Attached files:" ? tail.range(of: "Attached images:")?.lowerBound : nil
        let slice = stop.map { tail[..<$0] } ?? tail[...]
        return slice.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("- ") else { return nil }
            return String(trimmed.dropFirst(2))
        }
    }

    private static func inlineFileTags(in text: String) -> [String] {
        let pattern = #"<file name=\"([^\"]+)\">[\s\S]*?</file>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let r = Range(match.range(at: 1), in: text) else { return nil }
            return URL(fileURLWithPath: String(text[r])).lastPathComponent
        }
    }

    private static func imageName(from raw: String) -> String? {
        guard let range = raw.range(of: #"name=\"([^\"]+)\""#, options: .regularExpression) else { return nil }
        let match = raw[range]
        return match.replacingOccurrences(of: "name=\"", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    private static func removingFileTags(from text: String) -> String {
        text.replacingOccurrences(of: #"<file name=\"[^\"]+\">[\s\S]*?</file>"#, with: "", options: .regularExpression)
    }

    private static func removingFolderReferences(from text: String) -> String {
        guard !folderReferences(in: text).isEmpty else { return text }
        var output = text
        for pattern in folderReferencePatterns {
            output = output.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return output
            .replacingOccurrences(of: #"^\s*-\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
    }

    private static func folderReferences(in text: String) -> [String] {
        let explicit = matches(pattern: #"\bfolder:\s*`([^`]+)`"#, in: text)
            + matches(pattern: #"\bfolder:\s*(/[^\n`]+?)(?=\s+-\s+|\n|$)"#, in: text)
        let bare = matches(pattern: #"^\s*`(/[^`]+)`(?=\s+-\s+|\s*$)"#, in: text)
            + matches(pattern: #"^\s*(/[^\n`]+?)(?=\s+-\s+|\n|$)"#, in: text)
        return uniquePaths(explicit) + uniqueExistingDirectories(bare)
    }

    private static var folderReferencePatterns: [String] {
        [
            #"\bfolder:\s*`[^`]+`\s*(?:-\s*)?"#,
            #"\bfolder:\s*/[^\n`]+?(?=\s+-\s+|\n|$)\s*(?:-\s*)?"#,
            #"^\s*`/[^`]+`(?=\s+-\s+|\s*$)\s*(?:-\s*)?"#,
            #"^\s*/[^\n`]+?(?=\s+-\s+|\n|$)\s*(?:-\s*)?"#
        ]
    }

    private static func matches(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func uniquePaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.compactMap { path in
            let normalized = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
            guard seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }

    private static func uniqueExistingDirectories(_ paths: [String]) -> [String] {
        uniquePaths(paths).filter { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    private static func isImageName(_ name: String) -> Bool {
        imageExtensions.contains(URL(fileURLWithPath: name).pathExtension.lowercased())
    }
}

// MARK: - Chip pill view

/// A single capsule chip: a rounded surface with a leading icon (or thumbnail)
/// and a single-line, middle-truncated label. Mirrors the SwiftUI
/// `appSmallSecondaryButton` chip (caption2 label, photo thumbnail for images).
private final class PiAgentNativeChipView: NSView {
    private let surface = NativeCardSurface()
    private let iconView = NSImageView()
    private let thumbView = NSImageView()
    private let labelField = NSTextField(labelWithString: "")

    static let height: CGFloat = 24
    private static let thumbSize: CGFloat = 16
    private static let iconLabelGap: CGFloat = 6
    private static let hInset: CGFloat = 8

    private var iconLeadingC: NSLayoutConstraint!
    private var labelLeadingC: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        surface.translatesAutoresizingMaskIntoConstraints = false
        surface.cardCornerRadius = Self.height / 2
        surface.fillColor = AppTheme.ns(AppTheme.contentSubtleFill.opacity(0.7))
        surface.strokeColor = AppTheme.ns(AppTheme.contentStroke)
        addSubview(surface)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = AppTheme.ns(AppTheme.mutedText)
        surface.addSubview(iconView)

        thumbView.translatesAutoresizingMaskIntoConstraints = false
        thumbView.imageScaling = .scaleProportionallyUpOrDown
        thumbView.wantsLayer = true
        thumbView.layer?.cornerRadius = 4
        thumbView.layer?.cornerCurve = .continuous
        thumbView.layer?.masksToBounds = true
        thumbView.isHidden = true
        surface.addSubview(thumbView)

        labelField.translatesAutoresizingMaskIntoConstraints = false
        labelField.font = NativeTranscriptFont.caption2()
        labelField.textColor = .labelColor
        labelField.lineBreakMode = .byTruncatingMiddle
        labelField.maximumNumberOfLines = 1
        labelField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        surface.addSubview(labelField)

        iconLeadingC = iconView.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: Self.hInset)
        labelLeadingC = labelField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: Self.iconLabelGap)

        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),

            iconLeadingC,
            iconView.centerYAnchor.constraint(equalTo: surface.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 12),
            iconView.heightAnchor.constraint(equalToConstant: 12),

            thumbView.leadingAnchor.constraint(equalTo: iconView.leadingAnchor),
            thumbView.centerYAnchor.constraint(equalTo: surface.centerYAnchor),
            thumbView.widthAnchor.constraint(equalToConstant: Self.thumbSize),
            thumbView.heightAnchor.constraint(equalToConstant: Self.thumbSize),

            labelLeadingC,
            labelField.centerYAnchor.constraint(equalTo: surface.centerYAnchor),
            labelField.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -Self.hInset)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    func configure(_ chip: NativeQuestionChip) {
        labelField.stringValue = chip.label
        toolTip = "Preview \(chip.label)"
        if let thumbnail = chip.thumbnail {
            thumbView.image = thumbnail
            thumbView.isHidden = false
            iconView.isHidden = true
            iconLeadingC.constant = Self.hInset
            labelLeadingC.constant = Self.iconLabelGap + (Self.thumbSize - 12)
        } else {
            iconView.image = NSImage(systemSymbolName: chip.systemImage, accessibilityDescription: nil)
            iconView.isHidden = false
            thumbView.isHidden = true
            iconLeadingC.constant = Self.hInset
            labelLeadingC.constant = Self.iconLabelGap
        }
    }

    /// Capped natural width (label width + chrome) for chip-row wrapping. Matches
    /// `ChipLabelWidth.chipWidth(for:)` so the wrap math agrees with the bubble's
    /// `displayChipsNaturalWidth`-driven card sizing.
    func intrinsicChipWidth() -> CGFloat {
        ChipLabelWidth.chipWidth(for: labelField.stringValue)
    }
}

// MARK: - Question card

/// A full-width transcript row: a hugged-width, right-aligned question card plus
/// hover-revealed glass copy/fork buttons in the LEFT gutter. Self-measures
/// (including the wrapped chip row); the owning cell adds the row insets.
final class PiAgentNativeQuestionView: NSView, PiAgentNativeRowContent {
    private let cardView = NSView()
    private let iconView = NSImageView()
    private let headerLabel = NSTextField(labelWithString: "You")
    private let chipRow = NSView()
    private var chipViews: [PiAgentNativeChipView] = []
    private let markdown = PiAgentNativeExpandableMarkdown()

    // Hover-revealed copy (+ fork) glass buttons in the LEFT gutter.
    private let buttonStack = NSStackView()
    private let copyGlass = NSGlassEffectView()
    private let copyIcon = NSImageView()
    private let forkGlass = NSGlassEffectView()
    private let forkIcon = NSImageView()
    private var copiedResetWork: DispatchWorkItem?
    private var trackingArea: NSTrackingArea?

    private var payload: NativeQuestionPayload?
    var onIntrinsicHeightChange: (() -> Void)?

    private let hPad = AppTheme.Chat.bubbleHPadding
    private let vPad = AppTheme.Chat.bubbleVPadding
    private let headerSpacing: CGFloat = 8
    private let chipSpacing: CGFloat = 8
    private let chipToBody: CGFloat = 8
    private let gutterGap: CGFloat = 10

    private var cardWidthC: NSLayoutConstraint!
    private var cardLeadingC: NSLayoutConstraint!
    private var chipRowHeightC: NSLayoutConstraint!
    private var bodyTopToHeaderC: NSLayoutConstraint!
    private var bodyTopToChipsC: NSLayoutConstraint!
    private var buttonStackSideC: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.wantsLayer = true
        cardView.layer?.cornerRadius = AppTheme.Chat.bubbleCornerRadius
        cardView.layer?.cornerCurve = .continuous
        cardView.layer?.borderWidth = 1
        cardView.layer?.actions = [
            "bounds": NSNull(), "frame": NSNull(),
            "position": NSNull(), "transform": NSNull(),
            "backgroundColor": NSNull(), "borderColor": NSNull()
        ]
        addSubview(cardView)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: "person.fill", accessibilityDescription: nil)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = .labelColor

        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        headerLabel.font = PiAgentNativeQuestionView.headerFont
        headerLabel.textColor = .labelColor
        headerLabel.maximumNumberOfLines = 1

        chipRow.translatesAutoresizingMaskIntoConstraints = false
        markdown.translatesAutoresizingMaskIntoConstraints = false
        markdown.onToggle = { [weak self] in self?.onIntrinsicHeightChange?() }

        cardView.addSubview(iconView)
        cardView.addSubview(headerLabel)
        cardView.addSubview(chipRow)
        cardView.addSubview(markdown)

        buildConstraints()
        setupButtons()
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    /// The shared transcript header font — same definition as the bubbles + cards.
    static let headerFont = NativeTranscriptFont.header

    // MARK: Constraints

    private func buildConstraints() {
        cardWidthC = cardView.widthAnchor.constraint(equalToConstant: 100)
        cardLeadingC = cardView.leadingAnchor.constraint(equalTo: leadingAnchor)
        chipRowHeightC = chipRow.heightAnchor.constraint(equalToConstant: 0)
        bodyTopToHeaderC = markdown.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: headerSpacing)
        bodyTopToChipsC = markdown.topAnchor.constraint(equalTo: chipRow.bottomAnchor, constant: chipToBody)

        let bodyBottom = markdown.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -vPad)
        bodyBottom.priority = NSLayoutConstraint.Priority(999)

        NSLayoutConstraint.activate([
            cardView.topAnchor.constraint(equalTo: topAnchor),
            cardView.bottomAnchor.constraint(equalTo: bottomAnchor),
            cardWidthC, cardLeadingC,

            iconView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: hPad),
            iconView.topAnchor.constraint(equalTo: cardView.topAnchor, constant: vPad),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            headerLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 7),
            headerLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: cardView.trailingAnchor, constant: -hPad),

            chipRow.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: headerSpacing),
            chipRow.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: hPad),
            chipRow.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -hPad),
            chipRowHeightC,

            markdown.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: hPad),
            markdown.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -hPad),
            bodyBottom
        ])
    }

    // MARK: Configure

    func configure(payload: NativeQuestionPayload, width rowWidth: CGFloat) {
        self.payload = payload
        cardView.layer?.removeAllAnimations()

        headerLabel.stringValue = payload.headerTitle
        iconView.image = NativeTranscriptFont.headerIcon(payload.headerIcon)

        let cardW = cardWidth(forRowWidth: rowWidth)
        cardWidthC.constant = cardW
        cardLeadingC.constant = max(0, rowWidth - cardW)

        rebuildChips(payload.chips)

        let hasBody = !payload.markdownSource.isEmpty
        markdown.isHidden = !hasBody
        if hasBody { markdown.configure(source: payload.markdownSource) }

        // Body sits below the chip row when present, else below the header.
        let hasChips = !payload.chips.isEmpty
        bodyTopToHeaderC.isActive = false
        bodyTopToChipsC.isActive = false
        if hasBody {
            if hasChips { bodyTopToChipsC.isActive = true }
            else { bodyTopToHeaderC.isActive = true }
        }

        forkGlass.isHidden = payload.fork == nil
        configureButtonStack(hasFork: payload.fork != nil)
        applyChromeColors()
        needsLayout = true
    }

    private func rebuildChips(_ chips: [NativeQuestionChip]) {
        chipViews.forEach { $0.removeFromSuperview() }
        chipViews = chips.map { chip in
            let view = PiAgentNativeChipView()
            view.configure(chip)
            chipRow.addSubview(view)
            return view
        }
    }

    private func cardWidth(forRowWidth rowWidth: CGFloat) -> CGFloat {
        guard let payload else { return rowWidth }
        let w = PiAgentBubbleWidth.huggedUser(
            text: payload.markdownSource,
            pillsWidth: payload.chipsNaturalWidth,
            paneWidth: rowWidth
        )
        return max(1, min(rowWidth, w))
    }

    // MARK: Chip row layout (manual flow wrap)

    /// Lays out the chip pills as a wrapping flow within `innerWidth`, returning
    /// the total chip-row height. Each row is `PiAgentNativeChipView.height`.
    @discardableResult
    private func layoutChipRow(innerWidth: CGFloat, apply: Bool) -> CGFloat {
        guard !chipViews.isEmpty else { return 0 }
        let rowH = PiAgentNativeChipView.height
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowCount = 1
        for chip in chipViews {
            let w = min(chip.intrinsicChipWidth(), max(40, innerWidth))
            if x > 0, x + w > innerWidth + 0.5 {
                x = 0
                y += rowH + chipSpacing
                rowCount += 1
            }
            if apply {
                chip.frame = NSRect(x: x, y: y, width: w, height: rowH)
            }
            x += w + chipSpacing
        }
        return rowH * CGFloat(rowCount) + chipSpacing * CGFloat(rowCount - 1)
    }

    override func layout() {
        super.layout()
        let inner = max(1, chipRow.bounds.width)
        if !chipViews.isEmpty { layoutChipRow(innerWidth: inner, apply: true) }
    }

    override func viewWillDraw() {
        settleLayoutImmediately()
        super.viewWillDraw()
    }

    func settleLayoutImmediately() {
        cardView.layer?.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutSubtreeIfNeeded()
        cardView.layoutSubtreeIfNeeded()
        buttonStack.layoutSubtreeIfNeeded()
        CATransaction.commit()
        cardView.layer?.removeAllAnimations()
    }

    // MARK: Measure

    func measuredHeight(forWidth rowWidth: CGFloat) -> CGFloat {
        let cardW = cardWidth(forRowWidth: rowWidth)
        let inner = max(1, cardW - hPad * 2)
        var h = vPad + headerRowHeight()
        let chipsH = chipViews.isEmpty ? 0 : layoutChipRow(innerWidth: inner, apply: false)
        if chipsH > 0 {
            // Set the live constraint so the chip row gets the height it needs.
            chipRowHeightC.constant = chipsH
            h += headerSpacing + chipsH
        } else {
            chipRowHeightC.constant = 0
        }
        if let source = payload?.markdownSource, !source.isEmpty {
            let gap = chipsH > 0 ? chipToBody : headerSpacing
            h += gap + markdown.measuredHeight(forWidth: inner)
        }
        h += vPad
        return ceil(h)
    }

    private func headerRowHeight() -> CGFloat {
        max(14, ceil(headerLabel.intrinsicContentSize.height))
    }

    // MARK: Chrome colors

    private func applyChromeColors() {
        let base = AppTheme.ns(AppTheme.roleUser)
        let fill = base.withAlphaComponent(AppTheme.roleFillStrongOpacity)
        let stroke = base.withAlphaComponent(AppTheme.roleStrokeOpacity)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            cardView.layer?.backgroundColor = fill.cgColor
            cardView.layer?.borderColor = stroke.cgColor
        }
        // The glyph takes the bubble's own color (the same `base` driving the
        // fill/stroke); the title text keeps its label color.
        iconView.contentTintColor = base
        headerLabel.textColor = .labelColor
        copyIcon.contentTintColor = .labelColor
        forkIcon.contentTintColor = .labelColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyChromeColors()
    }

    // MARK: Copy / fork glass buttons (LEFT gutter)

    private static func symbolImage(_ name: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    private func glassIcon(_ glass: NSGlassEffectView, _ icon: NSImageView, symbol: String, help: String, action: Selector) {
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.cornerRadius = 14
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = Self.symbolImage(symbol)
        icon.contentTintColor = .labelColor
        icon.imageScaling = .scaleNone
        icon.toolTip = help
        glass.contentView = icon
        glass.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: action))
        NSLayoutConstraint.activate([
            glass.widthAnchor.constraint(equalToConstant: 28),
            glass.heightAnchor.constraint(equalToConstant: 28),
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    private func setupButtons() {
        glassIcon(copyGlass, copyIcon, symbol: "doc.on.doc", help: "Copy message", action: #selector(copyTapped))
        glassIcon(forkGlass, forkIcon, symbol: "arrow.trianglehead.branch", help: "Fork session…", action: #selector(forkTapped))
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 4
        buttonStack.alphaValue = 0
        addSubview(buttonStack)
        // Float to the LEFT of the right-aligned card, vertically centered on it.
        buttonStackSideC = buttonStack.trailingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: -gutterGap)
        NSLayoutConstraint.activate([
            buttonStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            buttonStackSideC
        ])
    }

    /// Order: [fork][copy] to the LEFT of the card (fork outboard).
    private func configureButtonStack(hasFork: Bool) {
        buttonStack.arrangedSubviews.forEach { buttonStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        if hasFork { buttonStack.addArrangedSubview(forkGlass) }
        buttonStack.addArrangedSubview(copyGlass)
    }

    @objc private func copyTapped() {
        guard let text = payload?.copyText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedResetWork?.cancel()
        if let checkmark = Self.symbolImage("checkmark") {
            copyIcon.setSymbolImage(checkmark, contentTransition: .replace)
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, let doc = Self.symbolImage("doc.on.doc") else { return }
            self.copyIcon.setSymbolImage(doc, contentTransition: .replace)
        }
        copiedResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)
    }

    @objc private func forkTapped() {
        guard let fork = payload?.fork else { return }
        if fork.agentOptions.isEmpty { fork.onForkSession(); return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let piItem = NSMenuItem(title: "Fork as Pi session", action: #selector(forkPiSessionSelected), keyEquivalent: "")
        piItem.target = self
        menu.addItem(piItem)
        let parent = NSMenuItem(title: "Fork as 1:1 agent chat…", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for (index, option) in fork.agentOptions.enumerated() {
            let item = NSMenuItem(title: option.title, action: #selector(forkAgentSelected(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.isEnabled = !option.isDisabled
            submenu.addItem(item)
        }
        parent.submenu = submenu
        menu.addItem(parent)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: forkGlass.bounds.height + 2), in: forkGlass)
    }

    @objc private func forkPiSessionSelected() { payload?.fork?.onForkSession() }

    @objc private func forkAgentSelected(_ item: NSMenuItem) {
        guard let options = payload?.fork?.agentOptions, item.tag >= 0, item.tag < options.count else { return }
        options[item.tag].action()
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { setButtonsVisible(true) }
    override func mouseExited(with event: NSEvent) { setButtonsVisible(false) }

    private func setButtonsVisible(_ visible: Bool) {
        settleLayoutImmediately()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = false
            buttonStack.animator().alphaValue = visible ? 1 : 0
        }
    }

    /// Force the hover buttons visible (used by an offscreen preview harness).
    func previewRevealButtons() { buttonStack.alphaValue = 1 }

    // MARK: Teardown

    func prepareForReuseIfNeeded() {
        markdown.cancel()
        copiedResetWork?.cancel()
        buttonStack.alphaValue = 0
    }
}

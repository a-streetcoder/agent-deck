import AppKit
import ImageIO
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
    enum Kind { case image, file, folder, issue, skill, command, paste, missing, overflow }

    /// The underlying attachment a chip previews when clicked. `nil` for the
    /// `+N more` overflow pill, which is display-only.
    enum Attachment {
        case image(PiAgentImageAttachment)
        case file(name: String, path: String?)
        case folder(path: String)
        case paste(PiAgentPasteAttachment)
        case issue(PiAgentIssueAttachment)
        case skill(name: String, record: SkillRecord?)
        case command(name: String)
        case missing(name: String)
    }

    var kind: Kind
    /// SF Symbol for the leading glyph (ignored when the chip renders a thumbnail).
    var systemImage: String
    var label: String
    /// Click-to-preview payload; `nil` for the overflow pill. Image chips derive
    /// their thumbnail lazily from this (decoded only when the cell is visible).
    var attachment: Attachment?
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

    /// Stable hash of everything the card renders. The items pass rebuilds this
    /// payload on every streaming pulse (a question's revision folds in unrelated
    /// context like subagent run ticks), so the view compares `identity` and
    /// skips the full reconfigure when nothing it draws has changed — honoring
    /// the cell contract that `configure` is a no-op when content is unchanged.
    var identity: Int

    /// Visible attachment chips before the row collapses into a `+N more` pill.
    static let maxVisibleChips = 3
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
        var chips = QuestionChipExtractor.chips(
            for: entry, skills: skills, commandSlashNames: commandSlashNames
        )
        // Cap the visible chips; fold the remainder into a trailing `+N more` pill.
        if chips.count > maxVisibleChips {
            let hidden = chips.count - maxVisibleChips
            chips = Array(chips.prefix(maxVisibleChips))
            chips.append(.init(kind: .overflow, systemImage: "", label: "+\(hidden) more"))
        }
        // Hug width is derived from the chips actually shown (post-cap), not the
        // full set, so the card never reserves room for collapsed attachments.
        let chipsWidth = ChipLabelWidth.rowWidth(forLabels: chips.map(\.label))

        // Identity over only what the card draws (entry + text + visible chips +
        // fork presence). Stable across unrelated streaming pulses.
        var hasher = Hasher()
        hasher.combine(entry.id)
        hasher.combine(text)
        for chip in chips {
            hasher.combine(chip.kind)
            hasher.combine(chip.label)
        }
        hasher.combine(fork != nil)

        return NativeQuestionPayload(
            markdownSource: text,
            chips: chips,
            copyText: entry.text,
            fork: fork,
            chipsNaturalWidth: chipsWidth,
            identity: hasher.finalize()
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
            chips.append(.init(kind: .skill, systemImage: "sparkles", label: name,
                               attachment: .skill(name: name, record: skillRecord(named: name, in: skills))))
        } else if let match = inactiveSkillMatch(messageBody: messageBody, skillInvocation: skillInvocation, bareSlash: bareSlash, skills: skills) {
            chips.append(.init(kind: .skill, systemImage: "sparkles", label: match.name,
                               attachment: .skill(name: match.name, record: skillRecord(named: match.name, in: skills))))
        }
        // Command chip — only when the bare slash matches an active command.
        if let name = bareSlash, commandSlashNames.contains(name) {
            chips.append(.init(kind: .command, systemImage: "terminal", label: name,
                               attachment: .command(name: name)))
        }
        // Issue chip.
        if let issue = payload?.issue {
            chips.append(.init(kind: .issue, systemImage: "exclamationmark.circle", label: "\(issue.kindShortTitle) #\(issue.number) \(issue.title)",
                               attachment: .issue(issue)))
        }

        // Image chips (payload first, then legacy basename-only listings).
        let imageAttachments = payload?.images ?? []
        for image in imageAttachments.prefix(6) {
            chips.append(.init(
                kind: .image, systemImage: "photo", label: image.name,
                attachment: .image(image)
            ))
        }
        let legacyNames = legacyImageNames(in: entry.text).filter { name in
            !imageAttachments.contains { $0.name == name }
        }
        for name in legacyNames.prefix(max(0, 6 - imageAttachments.count)) {
            chips.append(.init(kind: .missing, systemImage: "photo", label: name,
                               attachment: .missing(name: name)))
        }

        // File chips (payload + inline <file> tags + listed basenames; images excluded).
        for file in fileAttachments(for: entry, payload: payload).prefix(6) {
            chips.append(.init(kind: .file, systemImage: "doc.text", label: file.name,
                               attachment: .file(name: file.name, path: file.path)))
        }
        // Folder chips.
        for folder in folderAttachments(in: entry.text).prefix(6) {
            chips.append(.init(kind: .folder, systemImage: "folder", label: folder.name,
                               attachment: .folder(path: folder.path)))
        }
        // Paste chips.
        for paste in (payload?.pastes ?? []).prefix(6) {
            chips.append(.init(kind: .paste, systemImage: "doc.plaintext", label: paste.marker,
                               attachment: .paste(paste)))
        }
        return chips
    }

    private static func skillRecord(named name: String, in skills: [SkillRecord]) -> SkillRecord? {
        skills.first { $0.name == name }
    }

    // MARK: Payload decode

    private static func attachmentPayload(for entry: PiAgentTranscriptEntry) -> AttachmentPayload? {
        guard let rawJSON = entry.rawJSON, let data = rawJSON.data(using: .utf8) else { return nil }
        return try? jsonDecoder.decode(AttachmentPayload.self, from: data)
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

    /// File chips with their full path when known. Payload files carry a real
    /// path (so they preview); inline-tag / listed basenames don't (path == nil →
    /// the popover shows "preview unavailable"), matching the SwiftUI bubble.
    private static func fileAttachments(for entry: PiAgentTranscriptEntry, payload: AttachmentPayload?) -> [(name: String, path: String?)] {
        let payloadFiles = (payload?.files ?? []).filter { !isImageName($0.name) }
        let payloadNames = Set(payloadFiles.map(\.name))
        let tagged = inlineFileTags(in: entry.text)
            .filter { !isImageName($0) && !payloadNames.contains($0) }
        let listed = attachmentLines(after: "Attached files:", in: entry.text).compactMap { line -> String? in
            guard !line.contains("<image ") else { return nil }
            guard !payloadNames.contains(line) else { return nil }
            return line
        }
        var seen = Set<String>()
        var result: [(name: String, path: String?)] = []
        for file in payloadFiles where seen.insert(file.name).inserted {
            result.append((name: file.name, path: file.path))
        }
        for name in (tagged + listed) where seen.insert(name).inserted {
            result.append((name: name, path: nil))
        }
        return result
    }

    private static func legacyImageNames(in text: String) -> [String] {
        let imageLines = attachmentLines(after: "Attached images:", in: text)
            + attachmentLines(after: "Attached files:", in: text).filter { $0.contains("<image ") }
        let fromLines = imageLines.compactMap(imageName(from:))
        let fromTags = inlineFileTags(in: text).filter { isImageName($0) }
        var seen = Set<String>()
        return (fromLines + fromTags).filter { seen.insert($0).inserted }
    }

    private static func folderAttachments(in text: String) -> [(name: String, path: String)] {
        var seen = Set<String>()
        return folderReferences(in: text).compactMap { path in
            guard seen.insert(path).inserted else { return nil }
            return (name: URL(fileURLWithPath: path, isDirectory: true).lastPathComponent, path: path)
        }
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

// MARK: - Chip thumbnail cache

/// Decodes an image attachment once into a small (chip-sized) thumbnail and
/// caches it, keyed by content. Used only when a chip is actually displayed, so
/// the items pass never pays for image decoding.
private enum PiAgentChipThumbnailCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 128
        return cache
    }()
    private static let queue = DispatchQueue(label: "agent-deck.question-chip-thumbnails", qos: .userInitiated)
    private static var pending: [String: [(NSImage?) -> Void]] = [:]

    @MainActor
    static func cachedThumbnail(for image: PiAgentImageAttachment) -> (key: String, image: NSImage?) {
        let key = cacheKey(forBase64: image.data)
        return (key, cache.object(forKey: key as NSString))
    }

    @MainActor
    static func requestThumbnail(for image: PiAgentImageAttachment, completion: @escaping (String, NSImage?) -> Void) {
        let base64 = image.data
        let key = cacheKey(forBase64: base64)
        if let cached = cache.object(forKey: key as NSString) {
            completion(key, cached)
            return
        }

        if pending[key] != nil {
            pending[key]?.append { completion(key, $0) }
            return
        }
        pending[key] = [{ completion(key, $0) }]

        queue.async {
            let thumb = makeThumbnail(fromBase64: base64)
            DispatchQueue.main.async {
                if let thumb {
                    cache.setObject(thumb, forKey: key as NSString)
                }
                let completions = pending.removeValue(forKey: key) ?? []
                for completion in completions { completion(thumb) }
            }
        }
    }

    private static func cacheKey(forBase64 data: String) -> String {
        // Cheap content key — length + head + tail, never hashing megabytes.
        "\(data.count):\(data.prefix(64))\(data.suffix(64))"
    }

    private nonisolated static func makeThumbnail(fromBase64 base64: String) -> NSImage? {
        autoreleasepool {
            let maxPixelSize = 32
            guard let data = Data(base64Encoded: base64) as CFData?,
                  let source = CGImageSourceCreateWithData(data, nil)
            else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return NSImage(cgImage: cgImage, size: NSSize(width: maxPixelSize, height: maxPixelSize))
        }
    }
}

// MARK: - Chip pill view

/// A single capsule chip: a rounded surface with a leading icon (or thumbnail)
/// and a single-line, middle-truncated label. Mirrors the SwiftUI
/// `appSmallSecondaryButton` chip (caption2 label, photo thumbnail for images).
private final class PiAgentNativeChipView: NativeAccessiblePressableView {
    // Real Liquid Glass material, matching the SwiftUI chip's `.glass` capsule.
    private let glass = NSGlassEffectView()
    private let content = NSView()
    private let iconView = NSImageView()
    private let thumbView = NSImageView()
    private let labelField = NSTextField(labelWithString: "")

    static let height: CGFloat = 24
    private static let thumbSize: CGFloat = 16
    private static let iconLabelGap: CGFloat = 6
    private static let hInset: CGFloat = 8

    /// The attachment this chip previews on click; `nil` for the overflow pill.
    private(set) var attachment: NativeQuestionChip.Attachment?
    /// Invoked on click when the chip has a previewable attachment.
    var onActivate: (() -> Void)?

    private var iconLeadingC: NSLayoutConstraint!
    /// Label hangs off the icon's trailing edge for normal chips, or off the
    /// content's leading edge for the icon-less `+N more` overflow pill.
    private var labelLeadingToIconC: NSLayoutConstraint!
    private var labelLeadingToContentC: NSLayoutConstraint!
    /// The chip's width is set by the row layout. `NSGlassEffectView` hugs its
    /// content view, so without this the low-compression label collapses and the
    /// pill shrinks to just the icon — this is what drives the pill open.
    private var widthC: NSLayoutConstraint!
    private var representedThumbnailKey: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.cornerRadius = Self.height / 2

        content.translatesAutoresizingMaskIntoConstraints = false

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = AppTheme.ns(AppTheme.mutedText)
        content.addSubview(iconView)

        thumbView.translatesAutoresizingMaskIntoConstraints = false
        thumbView.imageScaling = .scaleProportionallyUpOrDown
        thumbView.wantsLayer = true
        thumbView.layer?.cornerRadius = 4
        thumbView.layer?.cornerCurve = .continuous
        thumbView.layer?.masksToBounds = true
        thumbView.isHidden = true
        content.addSubview(thumbView)

        labelField.translatesAutoresizingMaskIntoConstraints = false
        labelField.font = NativeTranscriptFont.caption()
        labelField.textColor = .labelColor
        labelField.lineBreakMode = .byTruncatingMiddle
        labelField.maximumNumberOfLines = 1
        labelField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        content.addSubview(labelField)

        glass.contentView = content
        addSubview(glass)

        pressAction = { [weak self] in self?.clicked() }

        iconLeadingC = iconView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.hInset)
        labelLeadingToIconC = labelField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: Self.iconLabelGap)
        labelLeadingToContentC = labelField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.hInset)
        widthC = widthAnchor.constraint(equalToConstant: 80)

        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
            widthC,

            // Pin the content to fill the glass so the label gets the chip's full
            // width instead of letting the glass hug it down to the icon.
            content.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            content.topAnchor.constraint(equalTo: glass.topAnchor),
            content.bottomAnchor.constraint(equalTo: glass.bottomAnchor),

            iconLeadingC,
            iconView.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 12),
            iconView.heightAnchor.constraint(equalToConstant: 12),

            thumbView.leadingAnchor.constraint(equalTo: iconView.leadingAnchor),
            thumbView.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            thumbView.widthAnchor.constraint(equalToConstant: Self.thumbSize),
            thumbView.heightAnchor.constraint(equalToConstant: Self.thumbSize),

            labelLeadingToIconC,
            labelField.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            labelField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.hInset)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    func configure(_ chip: NativeQuestionChip) {
        labelField.stringValue = chip.label
        attachment = chip.attachment
        representedThumbnailKey = nil

        // The `+N more` overflow pill: bold, muted, icon-less, non-previewable.
        if chip.kind == .overflow {
            pressAction = nil
            pressRole = .staticText
            setAccessibilityLabel(chip.label)
            toolTip = nil
            iconView.isHidden = true
            thumbView.isHidden = true
            thumbView.image = nil
            labelField.font = NativeTranscriptFont.caption2(.bold)
            labelField.textColor = AppTheme.ns(AppTheme.mutedText)
            labelLeadingToIconC.isActive = false
            labelLeadingToContentC.isActive = true
            return
        }

        pressAction = { [weak self] in self?.clicked() }
        pressRole = .button
        labelLeadingToContentC.isActive = false
        labelLeadingToIconC.isActive = true
        labelField.font = NativeTranscriptFont.caption()
        labelField.textColor = .labelColor
        toolTip = "Preview \(chip.label)"
        setAccessibilityLabel("Preview \(chip.label)")
        setAccessibilityHelp("Press Return or Space to open the attachment preview.")

        // Image chips first paint with their normal photo glyph unless a cached
        // thumbnail is already available. Decode/draw happens off the configure
        // path and updates the still-matching chip on the main thread.
        if case .image(let image) = chip.attachment {
            let cached = PiAgentChipThumbnailCache.cachedThumbnail(for: image)
            representedThumbnailKey = cached.key
            if let thumb = cached.image {
                showThumbnail(thumb)
            } else {
                showIcon(chip.systemImage)
                PiAgentChipThumbnailCache.requestThumbnail(for: image) { [weak self] key, thumb in
                    guard let self, self.representedThumbnailKey == key, let thumb else { return }
                    self.showThumbnail(thumb)
                }
            }
        } else {
            showIcon(chip.systemImage)
        }
    }

    private func showThumbnail(_ thumb: NSImage) {
        thumbView.image = thumb
        thumbView.isHidden = false
        iconView.isHidden = true
        iconLeadingC.constant = Self.hInset
        labelLeadingToIconC.constant = Self.iconLabelGap + (Self.thumbSize - 12)
    }

    private func showIcon(_ systemImage: String) {
        thumbView.image = nil
        iconView.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        iconView.isHidden = false
        thumbView.isHidden = true
        iconLeadingC.constant = Self.hInset
        labelLeadingToIconC.constant = Self.iconLabelGap
    }

    /// Capped natural width (label width + chrome) for chip-row wrapping. Matches
    /// `ChipLabelWidth.chipWidth(for:)` so the wrap math agrees with the bubble's
    /// `displayChipsNaturalWidth`-driven card sizing.
    func intrinsicChipWidth() -> CGFloat {
        ChipLabelWidth.chipWidth(for: labelField.stringValue)
    }

    /// The row layout sets the pill's final (possibly capped) width here.
    func applyWidth(_ w: CGFloat) {
        widthC.constant = w
    }

    private func clicked() {
        guard attachment != nil else { return }
        onActivate?()
    }

    override func resetCursorRects() {
        if attachment != nil { addCursorRect(bounds, cursor: .pointingHand) }
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
    // Flipped so the manual flow-wrap fills top-down: row 0 at the top, overflow
    // rows below. A plain NSView is bottom-origin, which inverts the rows.
    private let chipRow = FlippedContainerView()
    private var chipViews: [PiAgentNativeChipView] = []
    private let attachmentPopover = NSPopover()
    private weak var popoverChip: PiAgentNativeChipView?
    private let markdown = PiAgentNativeExpandableMarkdown()
    /// Hairline separating the message from its attachment chips.
    private let divider = NSView()

    // Hover-revealed copy (+ fork) glass buttons in the LEFT gutter.
    private let buttonStack = NSStackView()
    private let copyGlass = NSGlassEffectView()
    private let copyIcon = NSImageView()
    private let forkGlass = NSGlassEffectView()
    private let forkIcon = NSImageView()
    private let rerunGlass = NSGlassEffectView()
    private let rerunIcon = NSImageView()
    private var configuredButtonStackHasFork: Bool?
    private var copiedResetWork: DispatchWorkItem?
    private var trackingArea: NSTrackingArea?

    private var payload: NativeQuestionPayload?
    var onIntrinsicHeightChange: (() -> Void)?

    private let hPad = AppTheme.Chat.bubbleHPadding
    private let vPad = AppTheme.Chat.bubbleVPadding
    private let headerSpacing: CGFloat = 8
    private let chipSpacing: CGFloat = 8
    private let chipToBody: CGFloat = 8
    private let dividerSpacing: CGFloat = 8
    private let gutterGap: CGFloat = 10

    /// Last-applied content identity + width; `configure` early-returns when both
    /// match so streaming pulses that don't change the card cost nothing.
    private var configuredIdentity: Int?
    private var configuredWidth: CGFloat = -1

    private var cardWidthC: NSLayoutConstraint!
    private var cardLeadingC: NSLayoutConstraint!
    private var chipRowHeightC: NSLayoutConstraint!
    // Vertical stack toggles — body under the header, an optional hairline divider
    // under the body, chips under the divider; the last present element pins to
    // the card bottom.
    private var bodyTopToHeaderC: NSLayoutConstraint!
    private var dividerTopToHeaderC: NSLayoutConstraint!
    private var dividerTopToBodyC: NSLayoutConstraint!
    private var chipsTopToDividerC: NSLayoutConstraint!
    private var bodyBottomC: NSLayoutConstraint!
    private var chipsBottomC: NSLayoutConstraint!
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
        NativeTranscriptFont.configureHeaderLabel(headerLabel)
        headerLabel.textColor = .labelColor

        chipRow.translatesAutoresizingMaskIntoConstraints = false
        markdown.translatesAutoresizingMaskIntoConstraints = false
        markdown.onToggle = { [weak self] in self?.onIntrinsicHeightChange?() }

        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.wantsLayer = true
        divider.layer?.actions = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull()]
        divider.isHidden = true

        cardView.addSubview(iconView)
        cardView.addSubview(headerLabel)
        cardView.addSubview(divider)
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

        // Stack toggles — `configure` activates exactly the ones the present
        // elements need. Bottom pins are 999 so they yield to the externally
        // fixed card height; low-priority fallbacks keep a hidden/empty row from
        // becoming vertically ambiguous.
        bodyTopToHeaderC = markdown.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: headerSpacing)
        dividerTopToHeaderC = divider.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: dividerSpacing)
        dividerTopToBodyC = divider.topAnchor.constraint(equalTo: markdown.bottomAnchor, constant: dividerSpacing)
        chipsTopToDividerC = chipRow.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: dividerSpacing)
        bodyBottomC = markdown.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -vPad)
        bodyBottomC.priority = NSLayoutConstraint.Priority(999)
        chipsBottomC = chipRow.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -vPad)
        chipsBottomC.priority = NSLayoutConstraint.Priority(999)

        let bodyFallbackTop = markdown.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: headerSpacing)
        bodyFallbackTop.priority = NSLayoutConstraint.Priority(1)
        let bodyFallbackHeight = markdown.heightAnchor.constraint(equalToConstant: 0)
        bodyFallbackHeight.priority = NSLayoutConstraint.Priority(1)
        let dividerFallbackTop = divider.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: dividerSpacing)
        dividerFallbackTop.priority = NSLayoutConstraint.Priority(1)
        let chipsFallbackTop = chipRow.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: headerSpacing)
        chipsFallbackTop.priority = NSLayoutConstraint.Priority(1)

        NSLayoutConstraint.activate([
            cardView.topAnchor.constraint(equalTo: topAnchor),
            cardView.bottomAnchor.constraint(equalTo: bottomAnchor),
            cardWidthC, cardLeadingC,

            iconView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: hPad),
            iconView.topAnchor.constraint(equalTo: cardView.topAnchor, constant: vPad),
            iconView.widthAnchor.constraint(equalToConstant: NativeTranscriptFont.headerIconSize),
            iconView.heightAnchor.constraint(equalToConstant: NativeTranscriptFont.headerIconSize),

            headerLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 7),
            headerLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: cardView.trailingAnchor, constant: -hPad),

            divider.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: hPad),
            divider.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -hPad),
            divider.heightAnchor.constraint(equalToConstant: 1),

            chipRow.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: hPad),
            chipRow.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -hPad),
            chipRowHeightC,

            markdown.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: hPad),
            markdown.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -hPad),

            bodyFallbackTop, bodyFallbackHeight, dividerFallbackTop, chipsFallbackTop
        ])
    }

    // MARK: Configure

    func configure(payload: NativeQuestionPayload, width rowWidth: CGFloat) {
        // Streaming pulses re-run configure with content-identical payloads (the
        // question's revision folds in unrelated context). Skip the whole rebuild
        // when neither the drawn content nor the width changed.
        if configuredIdentity == payload.identity, abs(configuredWidth - rowWidth) <= 0.5 {
            self.payload = payload   // keep fork/copy closures current; cheap.
            return
        }
        configuredIdentity = payload.identity
        configuredWidth = rowWidth

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

        // Stack order: header → body → divider → chips. The divider + chips drop
        // below the body (or directly under the header when there is no body);
        // whichever element is last pins to the card bottom. Deactivate every
        // toggle before re-activating to avoid a transient over-constrained solve.
        let hasChips = !payload.chips.isEmpty
        divider.isHidden = !hasChips
        bodyTopToHeaderC.isActive = false
        dividerTopToHeaderC.isActive = false
        dividerTopToBodyC.isActive = false
        chipsTopToDividerC.isActive = false
        bodyBottomC.isActive = false
        chipsBottomC.isActive = false
        if hasBody {
            bodyTopToHeaderC.isActive = true
            if hasChips {
                dividerTopToBodyC.isActive = true
                chipsTopToDividerC.isActive = true
                chipsBottomC.isActive = true
            } else {
                bodyBottomC.isActive = true
            }
        } else if hasChips {
            dividerTopToHeaderC.isActive = true
            chipsTopToDividerC.isActive = true
            chipsBottomC.isActive = true
        } else {
            bodyBottomC.isActive = true
        }

        // Size + position the pills now (from the deterministic card width) and
        // commit their row height before first paint. Waiting for `measuredHeight`
        // to mutate this constraint leaves a just-sent attachment card with a 0pt
        // chip row for its first layout, which can pull the header/body into a
        // transient solve until the session is reopened or the row is remeasured.
        if !chipViews.isEmpty {
            chipRowHeightC.constant = layoutChipRow(innerWidth: chipInnerWidth(), apply: true)
        } else {
            chipRowHeightC.constant = 0
        }

        forkGlass.isHidden = payload.fork == nil
        rerunGlass.isHidden = payload.fork == nil
        configureButtonStack(hasFork: payload.fork != nil)
        applyChromeColors()
        needsLayout = true
    }

    private func rebuildChips(_ chips: [NativeQuestionChip]) {
        if attachmentPopover.isShown { attachmentPopover.performClose(nil) }
        // Reuse existing pills; only create/destroy the delta so we don't rebuild
        // NSGlassEffectView instances on every real reconfigure.
        while chipViews.count > chips.count {
            chipViews.removeLast().removeFromSuperview()
        }
        while chipViews.count < chips.count {
            let view = PiAgentNativeChipView()
            view.onActivate = { [weak self, weak view] in
                guard let self, let view else { return }
                self.presentAttachmentPopover(from: view)
            }
            chipRow.addSubview(view)
            chipViews.append(view)
        }
        for (view, chip) in zip(chipViews, chips) {
            view.configure(chip)
        }
    }

    /// Shows the attachment preview anchored below the tapped chip. Reuses a
    /// single popover; a second tap on the same chip toggles it closed.
    private func presentAttachmentPopover(from chip: PiAgentNativeChipView) {
        guard let attachment = chip.attachment else { return }
        if attachmentPopover.isShown {
            let sameChip = popoverChip === chip
            attachmentPopover.performClose(nil)
            if sameChip { return }
        }
        attachmentPopover.behavior = .transient
        attachmentPopover.animates = true
        attachmentPopover.contentViewController = PiAgentAttachmentPopoverController(attachment: attachment)
        popoverChip = chip
        attachmentPopover.show(relativeTo: chip.bounds, of: chip, preferredEdge: .maxY)
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
                chip.applyWidth(w)
                chip.frame = NSRect(x: x, y: y, width: w, height: rowH)
            }
            x += w + chipSpacing
        }
        return rowH * CGFloat(rowCount) + chipSpacing * CGFloat(rowCount - 1)
    }

    /// Deterministic chip-row inner width, derived from the card-width constraint
    /// (a required equality) rather than `chipRow.bounds.width`, which is
    /// transiently 0 before constraints settle on first display — that window is
    /// what left chips collapsed to their 40pt floor (icon only, name truncated)
    /// until a later relayout (e.g. a click) corrected them.
    private func chipInnerWidth() -> CGFloat {
        max(1, cardWidthC.constant - hPad * 2)
    }

    override func layout() {
        super.layout()
        if !chipViews.isEmpty { layoutChipRow(innerWidth: chipInnerWidth(), apply: true) }
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
        let hasBody = !(payload?.markdownSource.isEmpty ?? true)
        if hasBody {
            h += headerSpacing + markdown.measuredHeight(forWidth: inner)
        }
        let chipsH = chipViews.isEmpty ? 0 : layoutChipRow(innerWidth: inner, apply: false)
        if chipsH > 0 {
            // Set the live constraint so the chip row gets the height it needs.
            chipRowHeightC.constant = chipsH
            // Leading gap → 1pt divider → trailing gap → chips.
            h += dividerSpacing + 1 + dividerSpacing + chipsH
        } else {
            chipRowHeightC.constant = 0
        }
        h += vPad
        return ceil(h)
    }

    private func headerRowHeight() -> CGFloat {
        max(NativeTranscriptFont.headerIconSize, ceil(headerLabel.intrinsicContentSize.height))
    }

    // MARK: Chrome colors

    private func applyChromeColors() {
        let base = AppTheme.ns(AppTheme.roleUser)
        let fill = base.withAlphaComponent(AppTheme.roleFillStrongOpacity)
        let stroke = base.withAlphaComponent(AppTheme.roleStrokeOpacity)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            cardView.layer?.backgroundColor = fill.cgColor
            cardView.layer?.borderColor = stroke.cgColor
            divider.layer?.backgroundColor = base.withAlphaComponent(AppTheme.roleStrokeOpacity).cgColor
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
        let press = NSButton(title: "", target: self, action: action)
        press.translatesAutoresizingMaskIntoConstraints = false
        press.isBordered = false
        press.toolTip = help
        press.setAccessibilityLabel(help)
        glass.addSubview(press)
        NSLayoutConstraint.activate([
            press.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            press.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            press.topAnchor.constraint(equalTo: glass.topAnchor),
            press.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
            glass.widthAnchor.constraint(equalToConstant: 28),
            glass.heightAnchor.constraint(equalToConstant: 28),
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    private func setupButtons() {
        glassIcon(copyGlass, copyIcon, symbol: "doc.on.doc", help: "Copy message", action: #selector(copyTapped))
        glassIcon(forkGlass, forkIcon, symbol: "arrow.trianglehead.branch", help: "Fork session…", action: #selector(forkTapped))
        glassIcon(rerunGlass, rerunIcon, symbol: "arrow.clockwise", help: "Re-run from here (rewinds the conversation and resends this message)", action: #selector(rerunTapped))
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

    /// Order: [rerun][fork][copy] to the LEFT of the card (rerun outboard).
    private func configureButtonStack(hasFork: Bool) {
        let desired: [NSView] = hasFork ? [rerunGlass, forkGlass, copyGlass] : [copyGlass]
        let current = buttonStack.arrangedSubviews
        let orderMatches = current.count == desired.count
            && zip(current, desired).allSatisfy { currentView, desiredView in currentView === desiredView }
        guard configuredButtonStackHasFork != hasFork || !orderMatches else { return }
        configuredButtonStackHasFork = hasFork
        current.forEach { buttonStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        desired.forEach { buttonStack.addArrangedSubview($0) }
    }

    @objc private func rerunTapped() { payload?.fork?.onRerun() }

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
        if attachmentPopover.isShown { attachmentPopover.performClose(nil) }
    }
}

/// Top-origin container for manual flow layouts (e.g. the wrapping chip row).
private final class FlippedContainerView: NSView {
    override var isFlipped: Bool { true }
}

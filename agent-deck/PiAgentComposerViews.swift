import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct PiAgentComposerBox: View {
    private let maxImages = 8

    @Binding var text: String
    @Binding var images: [PiAgentImageAttachment]
    @Binding var files: [PiAgentFileAttachment]
    @Binding var attachmentError: String?
    @Binding var inputMode: PiAgentInputMode
    let isRunning: Bool
    let isDisabled: Bool
    let placeholder: String
    let canSend: Bool
    let path: String?
    let onFiles: ([URL]) -> Void
    let onFolders: ([URL]) -> Void
    let viewModel: AppViewModel
    let footerSession: PiAgentSessionRecord?
    let transcript: [PiAgentTranscriptEntry]
    let supportedThinkingLevels: [String]
    let metricsSession: PiAgentSessionRecord?
    let onSend: () -> Void
    let onStop: () -> Void
    let onClear: () -> Void
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !images.isEmpty || !files.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(images) { image in
                            PiAgentImageAttachmentThumbnail(image: image) {
                                images.removeAll { $0.id == image.id }
                            }
                        }
                        ForEach(files) { file in
                            PiAgentFileAttachmentChip(file: file) {
                                files.removeAll { $0.id == file.id }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                }
            }

            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.body)
                        .foregroundStyle(AppTheme.mutedText.opacity(0.72))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
                PiAgentDropSafeTextEditor(
                    text: $text,
                    onDropTargeted: { isDropTargeted = $0 },
                    onImages: addImages,
                    onFiles: onFiles,
                    onFolders: onFolders,
                    onUnsupportedDrop: { attachmentError = "Drop images, files, or folders." },
                    onSend: onSend,
                    onClear: onClear,
                    isDisabled: isDisabled
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(minHeight: 92, maxHeight: 132)
            }

            if let attachmentError {
                Label(attachmentError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            VStack(spacing: 10) {
                if let footerSession {
                    HStack(spacing: 10) {
                        PiAgentComposerFooterBar(
                            session: footerSession,
                            viewModel: viewModel,
                            transcript: transcript,
                            supportedThinkingLevels: supportedThinkingLevels
                        )
                        composerActionControls

                        Spacer(minLength: 18)
                        PiAgentSendButton(isRunning: isRunning, canSend: canSend && !isDisabled, sendAction: onSend, stopAction: onStop)
                            .keyboardShortcut(.return, modifiers: [])
                    }
                }

                HStack(alignment: .center, spacing: 10) {
                    if let path {
                        HStack(spacing: 6) {
                            Image(systemName: "folder")
                            Text(shortPath(path))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                        .help(path)
                    }

                    if let metricsSession {
                        PiAgentRuntimeFooter(session: metricsSession)
                    }

                    Spacer(minLength: 8)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .appContentSurface(cornerRadius: 20)
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(isDropTargeted ? AppTheme.brandAccent.opacity(0.7) : Color.clear, lineWidth: isDropTargeted ? 2 : 1)
        )
        .overlay {
            if isDropTargeted {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(AppTheme.brandAccent.opacity(0.10))
                        .allowsHitTesting(false)
            }
            if isDisabled {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(AppTheme.contentFill.opacity(0.35))
                    .allowsHitTesting(false)
            }
        }
        .shadow(color: .black.opacity(0.05), radius: 14, x: 0, y: 7)
        .onPasteCommand(of: [.png, .jpeg, .tiff, .gif, .webP, .fileURL]) { _ in
            addImages(PiAgentComposerImageLoader.imagesFromPasteboard())
        }
        .onDrop(of: [.fileURL, .png, .jpeg, .tiff, .gif, .webP, .image, .plainText, .utf8PlainText], isTargeted: $isDropTargeted) { providers in
            PiAgentComposerImageLoader.loadDropItems(from: providers) { attachments, files in
                let folderURLs = files.filter(\.hasDirectoryPath)
                let fileURLs = files.filter { !$0.hasDirectoryPath }
                if attachments.isEmpty && fileURLs.isEmpty && folderURLs.isEmpty {
                    attachmentError = "Drop images, files, or folders."
                } else {
                    addImages(attachments)
                    onFiles(fileURLs)
                    onFolders(folderURLs)
                }
            }
            return true
        }
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var composerActionControls: some View {
        AppControlGroup(spacing: 6) {
            Button(action: attachImagesFromOpenPanel) {
                Image(systemName: "paperclip")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.mutedText)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .appControlSurface(cornerRadius: 15)
            .help("Attach files")
            .accessibilityLabel("Attach files")
            .accessibilityHint("Attach images, text files, or local file paths")
        }
    }

    private func attachImagesFromOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.item]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }
        let imageAttachments = panel.urls.compactMap { PiAgentComposerImageLoader.imageAttachment(fromFileURL: $0) }
        let files = panel.urls.filter { PiAgentComposerImageLoader.imageAttachment(fromFileURL: $0) == nil }
        addImages(imageAttachments)
        onFiles(files)
    }

    private func shortPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    private func addImages(_ newImages: [PiAgentImageAttachment]) {
        guard !newImages.isEmpty else { return }
        attachmentError = nil
        var next = images
        for image in newImages {
            if next.count >= maxImages {
                attachmentError = "Pi supports up to \(maxImages) images per message."
                break
            }
            if !next.contains(where: { $0.data == image.data }) {
                next.append(image)
            }
        }
        images = next
    }
}

struct PiAgentDropSafeTextEditor: NSViewRepresentable {
    @Binding var text: String
    var onDropTargeted: (Bool) -> Void
    var onImages: ([PiAgentImageAttachment]) -> Void
    var onFiles: ([URL]) -> Void
    var onFolders: ([URL]) -> Void
    var onUnsupportedDrop: () -> Void
    var onSend: () -> Void
    var onClear: () -> Void
    var isDisabled: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        let textView = DropSafeNSTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = NSFont.preferredFont(forTextStyle: .body)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isEditable = !isDisabled
        textView.allowsUndo = true
        textView.importsGraphics = false
        textView.allowsImageEditing = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.dropHandler = context.coordinator
        textView.keyHandler = context.coordinator

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? DropSafeNSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        textView.isEditable = !isDisabled
        textView.dropHandler = context.coordinator
        textView.keyHandler = context.coordinator
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, DropSafeNSTextViewDropHandler, DropSafeNSTextViewKeyHandler {
        var parent: PiAgentDropSafeTextEditor

        init(parent: PiAgentDropSafeTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func setDropTargeted(_ targeted: Bool) {
            parent.onDropTargeted(targeted)
        }

        func handleDrop(_ pasteboard: NSPasteboard) -> Bool {
            let images = PiAgentComposerImageLoader.imagesFromPasteboard(pasteboard)
            let droppedURLs = PiAgentComposerImageLoader.fileURLs(from: pasteboard).filter { url in
                url.hasDirectoryPath || PiAgentComposerImageLoader.imageAttachment(fromFileURL: url) == nil
            }
            let folders = droppedURLs.filter(\.hasDirectoryPath)
            let files = droppedURLs.filter { !$0.hasDirectoryPath }
            if images.isEmpty && files.isEmpty && folders.isEmpty {
                parent.onUnsupportedDrop()
                return false
            }
            parent.onImages(images)
            parent.onFiles(files)
            parent.onFolders(folders)
            return true
        }

        func send() {
            guard !parent.isDisabled else { return }
            parent.onSend()
        }

        func clear() {
            guard !parent.isDisabled else { return }
            parent.onClear()
        }
    }
}

@MainActor
protocol DropSafeNSTextViewDropHandler: AnyObject {
    func setDropTargeted(_ targeted: Bool)
    func handleDrop(_ pasteboard: NSPasteboard) -> Bool
}

@MainActor
protocol DropSafeNSTextViewKeyHandler: AnyObject {
    func send()
    func clear()
}

final class DropSafeNSTextView: NSTextView {
    weak var dropHandler: DropSafeNSTextViewDropHandler?
    weak var keyHandler: DropSafeNSTextViewKeyHandler?
    private var lastEscapeAt: TimeInterval?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard acceptsDrop(sender.draggingPasteboard) else {
            return super.draggingEntered(sender)
        }
        dropHandler?.setDropTargeted(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard acceptsDrop(sender.draggingPasteboard) else {
            return super.draggingUpdated(sender)
        }
        dropHandler?.setDropTargeted(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropHandler?.setDropTargeted(false)
        super.draggingExited(sender)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dropHandler?.setDropTargeted(false)
        super.draggingEnded(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard acceptsDrop(sender.draggingPasteboard) else {
            return super.performDragOperation(sender)
        }
        dropHandler?.setDropTargeted(false)
        return dropHandler?.handleDrop(sender.draggingPasteboard) ?? false
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.charactersIgnoringModifiers == "\r" || event.charactersIgnoringModifiers == "\n"
        let modifiers = event.modifierFlags.intersection([.shift, .command, .option, .control])
        if isReturn && modifiers.isEmpty {
            keyHandler?.send()
            return
        }
        if isReturn && (modifiers.contains(.shift) || modifiers.contains(.command) || modifiers.contains(.option)) {
            insertNewlineIgnoringFieldEditor(self)
            return
        }
        if event.keyCode == 53 {
            let now = event.timestamp
            if let lastEscapeAt, now - lastEscapeAt < 0.6 {
                keyHandler?.clear()
                self.lastEscapeAt = nil
                return
            }
            self.lastEscapeAt = now
            super.keyDown(with: event)
            return
        }
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        if acceptsDrop(pasteboard), dropHandler?.handleDrop(pasteboard) == true {
            return
        }
        super.paste(sender)
    }

    private func acceptsDrop(_ pasteboard: NSPasteboard) -> Bool {
        !PiAgentComposerImageLoader.imagesFromPasteboard(pasteboard).isEmpty || !PiAgentComposerImageLoader.fileURLs(from: pasteboard).isEmpty
    }
}

struct PiAgentSubagentPopover: View {
    @Binding var isEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Label("Subagents", systemImage: "rectangle.connected.to.line.below")
                    .font(.body.weight(.medium))
                Spacer(minLength: 24)
                Toggle("Subagents", isOn: $isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            Text(isEnabled ? "Parent Pi can delegate to native subagents when useful." : "Native subagent tools are not exposed to this session.")
                .font(.caption)
                .foregroundStyle(AppTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }
}

struct PiAgentFileAttachmentChip: View {
    let file: PiAgentFileAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .foregroundStyle(AppTheme.brandAccent)
            Text(file.url.lastPathComponent.isEmpty ? file.url.path : file.url.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.head)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(AppTheme.mutedText)
            }
            .buttonStyle(.plain)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Capsule(style: .continuous).fill(AppTheme.contentSubtleFill))
        .help(file.url.path)
    }
}

struct PiAgentImageAttachmentThumbnail: View {
    let image: PiAgentImageAttachment
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let nsImage = PiAgentComposerImageLoader.previewImage(for: image) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(AppTheme.mutedText)
                }
            }
            .frame(width: 68, height: 68)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AppTheme.contentStroke, lineWidth: 1)
            )

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(.black.opacity(0.7)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove image attachment")
            .offset(x: 6, y: -6)
        }
        .help("\(image.name) · \(ByteCountFormatter.string(fromByteCount: Int64(image.sizeBytes), countStyle: .file))")
    }
}

enum PiAgentComposerImageLoader {
    nonisolated private static let maxDimension: CGFloat = 2_000
    nonisolated private static let maxEncodedBytes = Int(4.5 * 1024 * 1024)

    nonisolated static func imagesFromPasteboard(_ pasteboard: NSPasteboard = .general) -> [PiAgentImageAttachment] {
        var attachments: [PiAgentImageAttachment] = []
        let urls = fileURLs(from: pasteboard)
        attachments.append(contentsOf: urls.compactMap(imageAttachment(fromFileURL:)))
        if let data = pasteboard.data(forType: .png), let attachment = imageAttachment(data: data, name: "pasted-image.png", mimeType: "image/png", fileReference: "pasted-image.png") {
            attachments.append(attachment)
        } else if let data = pasteboard.data(forType: .tiff), let pngData = pngData(fromImageData: data), let attachment = imageAttachment(data: pngData, name: "pasted-image.png", mimeType: "image/png", fileReference: "pasted-image.png") {
            attachments.append(attachment)
        }
        return attachments
    }

    nonisolated static func loadImages(from providers: [NSItemProvider], completion: @escaping ([PiAgentImageAttachment]) -> Void) {
        loadDropItems(from: providers) { attachments, _ in completion(attachments) }
    }

    nonisolated static func loadDropItems(from providers: [NSItemProvider], completion: @escaping ([PiAgentImageAttachment], [URL]) -> Void) {
        let group = DispatchGroup()
        let accumulator = DropItemAccumulator()

        for provider in providers {
            var didScheduleFile = false
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                didScheduleFile = true
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    defer { group.leave() }
                    let url: URL?
                    if let data = item as? Data {
                        url = URL(dataRepresentation: data, relativeTo: nil)
                    } else {
                        url = item as? URL
                    }
                    if let url, let image = imageAttachment(fromFileURL: url) {
                        accumulator.appendImage(image)
                    } else {
                        accumulator.appendFile(url)
                    }
                }
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) && !didScheduleFile {
                group.enter()
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    defer { group.leave() }
                    guard let data else { return }
                    let png = pngData(fromImageData: data) ?? data
                    accumulator.appendImage(imageAttachment(data: png, name: "dropped-image.png", mimeType: "image/png", fileReference: "dropped-image.png"))
                }
            }
        }

        group.notify(queue: .main) {
            let result = accumulator.result()
            completion(result.attachments, result.files)
        }
    }

    private final class DropItemAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        nonisolated(unsafe) private var attachments: [PiAgentImageAttachment] = []
        nonisolated(unsafe) private var files: [URL] = []

        nonisolated init() {}

        nonisolated func appendImage(_ attachment: PiAgentImageAttachment?) {
            guard let attachment else { return }
            lock.lock()
            attachments.append(attachment)
            lock.unlock()
        }

        nonisolated func appendFile(_ url: URL?) {
            guard let url else { return }
            lock.lock()
            files.append(url)
            lock.unlock()
        }

        nonisolated func result() -> (attachments: [PiAgentImageAttachment], files: [URL]) {
            lock.lock()
            let attachments = attachments
            let files = files
            lock.unlock()

            var seen = Set<String>()
            return (attachments, files.filter { seen.insert($0.path).inserted })
        }
    }

    nonisolated static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        var urls: [URL] = []
        if let read = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            urls.append(contentsOf: read)
        }
        let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        if let paths = pasteboard.propertyList(forType: filenamesType) as? [String] {
            urls.append(contentsOf: paths.map(URL.init(fileURLWithPath:)))
        }
        for item in pasteboard.pasteboardItems ?? [] {
            if let value = item.string(forType: .fileURL), let url = URL(string: value) {
                urls.append(url)
            }
        }
        var seen = Set<String>()
        return urls.filter { seen.insert($0.path).inserted }
    }

    nonisolated static func imageAttachment(fromFileURL url: URL) -> PiAgentImageAttachment? {
        guard let mimeType = mimeType(for: url), let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return imageAttachment(data: data, name: url.lastPathComponent, mimeType: mimeType, fileReference: url.path)
    }

    nonisolated static func imageAttachment(data: Data, name: String, mimeType: String, fileReference: String? = nil) -> PiAgentImageAttachment? {
        guard let processed = processLikePiCLI(data: data, mimeType: mimeType) else { return nil }
        return PiAgentImageAttachment(
            name: name,
            mimeType: processed.mimeType,
            data: processed.data.base64EncodedString(),
            sizeBytes: processed.data.count,
            fileReference: fileReference ?? name,
            dimensionNote: processed.dimensionNote
        )
    }

    nonisolated static func previewImage(for attachment: PiAgentImageAttachment) -> NSImage? {
        guard let data = Data(base64Encoded: attachment.data) else { return nil }
        return NSImage(data: data)
    }

    nonisolated private static func mimeType(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "tif", "tiff": return "image/tiff"
        case "heic": return "image/heic"
        default: return nil
        }
    }

    nonisolated private static func processLikePiCLI(data: Data, mimeType: String) -> (data: Data, mimeType: String, dimensionNote: String?)? {
        let encodedSize = data.base64EncodedString().utf8.count
        guard let image = NSImage(data: data) else { return nil }
        let originalSize = image.pixelSize
        if originalSize.width <= maxDimension,
           originalSize.height <= maxDimension,
           encodedSize < maxEncodedBytes,
           ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(mimeType) {
            return (data, mimeType, nil)
        }

        let scale = min(maxDimension / max(originalSize.width, 1), maxDimension / max(originalSize.height, 1), 1)
        var targetSize = CGSize(width: max(1, floor(originalSize.width * scale)), height: max(1, floor(originalSize.height * scale)))
        while targetSize.width >= 1 && targetSize.height >= 1 {
            if let resized = resizedBitmap(from: image, targetSize: targetSize) {
                let candidates = encodedCandidates(from: resized)
                if let candidate = candidates.first(where: { $0.data.base64EncodedString().utf8.count < maxEncodedBytes }) {
                    let dimensionNote = formatDimensionNote(original: originalSize, displayed: targetSize)
                    return (candidate.data, candidate.mimeType, dimensionNote)
                }
            }
            if targetSize.width == 1 && targetSize.height == 1 { break }
            targetSize = CGSize(width: max(1, floor(targetSize.width * 0.75)), height: max(1, floor(targetSize.height * 0.75)))
        }
        return nil
    }

    nonisolated private static func encodedCandidates(from rep: NSBitmapImageRep) -> [(data: Data, mimeType: String)] {
        var candidates: [(Data, String)] = []
        if let png = rep.representation(using: .png, properties: [:]) { candidates.append((png, "image/png")) }
        for quality in [0.80, 0.85, 0.70, 0.55, 0.40] {
            if let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]) {
                candidates.append((jpeg, "image/jpeg"))
            }
        }
        return candidates.sorted(by: { (lhs: (data: Data, mimeType: String), rhs: (data: Data, mimeType: String)) in
            lhs.data.count < rhs.data.count
        })
    }

    nonisolated private static func resizedBitmap(from image: NSImage, targetSize: CGSize) -> NSBitmapImageRep? {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(targetSize.width), pixelsHigh: Int(targetSize.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let rep else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: CGRect(origin: .zero, size: targetSize), from: CGRect(origin: .zero, size: image.size), operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    nonisolated private static func formatDimensionNote(original: CGSize, displayed: CGSize) -> String? {
        guard original != displayed else { return nil }
        let scale = original.width / max(displayed.width, 1)
        return "[Image: original \(Int(original.width))x\(Int(original.height)), displayed at \(Int(displayed.width))x\(Int(displayed.height)). Multiply coordinates by \(String(format: "%.2f", scale)) to map to original image.]"
    }

    nonisolated private static func pngData(fromImageData data: Data) -> Data? {
        guard let image = NSImage(data: data), let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

private extension NSImage {
    nonisolated var pixelSize: CGSize {
        if let rep = representations.max(by: { ($0.pixelsWide * $0.pixelsHigh) < ($1.pixelsWide * $1.pixelsHigh) }) {
            return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return size
    }
}

struct PiAgentSendButton: View {
    let isRunning: Bool
    let canSend: Bool
    let sendAction: () -> Void
    let stopAction: () -> Void

    var body: some View {
        Button(action: isRunning ? stopAction : sendAction) {
            Image(systemName: isRunning ? "stop.fill" : "arrow.up")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 34, height: 34)
                .background(
                    Circle()
                        .fill(backgroundColor)
                        .animation(.snappy(duration: 0.22), value: isRunning)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isRunning && !canSend)
        .help(isRunning ? "Stop Pi Agent" : "Send message")
        .accessibilityLabel(isRunning ? "Stop Pi Agent" : "Send message")
        .background {
            Button("Stop Pi Agent", action: stopAction)
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(!isRunning)
                .hidden()
        }
        .animation(.snappy(duration: 0.22), value: isRunning)
    }

    private var backgroundColor: Color {
        if isRunning { return .red.opacity(0.88) }
        return canSend ? AppTheme.brandAccent : AppTheme.mutedText.opacity(0.28)
    }
}

struct PiAgentModelSelection {
    let provider: String
    let modelID: String
}

struct PiAgentComposerFooterBar: View {
    let session: PiAgentSessionRecord
    @ObservedObject var viewModel: AppViewModel
    let transcript: [PiAgentTranscriptEntry]
    let supportedThinkingLevels: [String]

    var body: some View {
        HStack(spacing: 10) {
            PiAgentContextUsageMeter(
                session: session,
                transcript: transcript,
                fallbackModels: viewModel.enabledAvailableModels,
                showsSmartZoneHint: viewModel.appSettings.showContextSmartZoneHint,
                onCompact: { viewModel.compactSelectedPiAgentSession() }
            )
            PiAgentModelPicker(
                session: session,
                fallbackModels: viewModel.enabledAvailableModels,
                disabledModelIdentifiers: viewModel.appSettings.disabledModelIdentifiers,
                defaultModel: viewModel.defaultPiAgentModel(),
                isRunning: viewModel.isPiAgentSessionRunning(session.id),
                onRefresh: { viewModel.refreshPiAgentControlsForSelectedSession() },
                onCycle: { viewModel.cyclePiAgentModelForSelectedSession() },
                onSelect: { selection in
                    if let selection {
                        viewModel.setPiAgentModelForSelectedSession(provider: selection.provider, modelID: selection.modelID)
                    } else {
                        viewModel.setPiAgentModelForSelectedSession(provider: nil, modelID: nil)
                    }
                }
            )
            PiAgentThinkingPicker(
                level: session.thinkingLevel,
                supportedLevels: supportedThinkingLevels,
                defaultLevel: viewModel.defaultPiAgentThinkingLevel(for: supportedThinkingLevels),
                isRunning: viewModel.isPiAgentSessionRunning(session.id),
                onCycle: { viewModel.cyclePiAgentThinkingLevelForSelectedSession() },
                onSelect: { viewModel.setPiAgentThinkingLevelForSelectedSession($0) }
            )
        }
    }
}

struct PiAgentContextUsageMeter: View {
    let session: PiAgentSessionRecord
    let transcript: [PiAgentTranscriptEntry]
    let fallbackModels: [AvailableModel]
    let showsSmartZoneHint: Bool
    let onCompact: () -> Void
    @State private var isConfirmingCompaction = false
    @State private var isBreakdownPresented = false

    var body: some View {
        if session.isCompacting {
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                Text("Compacting context")
                    .font(.caption.weight(.semibold))
                if let tokens = session.contextTokens {
                    Text("\(compact(tokens)) tokens")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(AppTheme.mutedText)
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule(style: .continuous).fill(AppTheme.contentSubtleFill).stroke(AppTheme.contentStroke, lineWidth: 1))
            .fixedSize(horizontal: true, vertical: false)
            .help("Pi is compacting this conversation. Input is disabled until compaction finishes.")
        } else if let percent = session.contextPercent, let tokens = session.contextTokens, let window = session.contextWindow {
            HStack(spacing: 6) {
                HStack(spacing: 7) {
                    Text("Context")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .fixedSize()
                    PiAgentSmartZoneContextBar(
                        percent: percent,
                        showsSmartZoneHint: showsSmartZoneHint,
                        width: 92,
                        height: 10
                    )
                    Text("\(Int(percent))%")
                        .font(.caption.monospacedDigit().weight(.bold))
                        .lineLimit(1)
                    Text("\(compact(tokens))/\(compact(window))")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(AppTheme.mutedText)
                        .lineLimit(1)
                    Image(systemName: "info.circle")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppTheme.mutedText)
                        .accessibilityLabel("Show context usage details")
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule(style: .continuous).fill(AppTheme.contentSubtleFill).stroke(AppTheme.contentStroke, lineWidth: 1))
                .fixedSize(horizontal: true, vertical: false)
                .contentShape(Capsule(style: .continuous))
                .onTapGesture {
                    isBreakdownPresented.toggle()
                }
                .popover(isPresented: $isBreakdownPresented, arrowEdge: .bottom) {
                    PiAgentContextBreakdownPopover(
                        session: session,
                        transcript: transcript,
                        fallbackModels: fallbackModels,
                        showsSmartZoneHint: showsSmartZoneHint
                    )
                }
                .help(showsSmartZoneHint ? "Show context usage details. Smart zone hint is enabled in Settings." : "Show context usage details")

                Button {
                    isConfirmingCompaction = true
                } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.mutedText)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(AppTheme.contentSubtleFill).stroke(AppTheme.contentStroke, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Compact context")
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
            .alert("Compact context?", isPresented: $isConfirmingCompaction) {
                Button("Cancel", role: .cancel) {}
                Button("Compact") { onCompact() }
            } message: {
                Text("Pi will summarize older conversation history to free context. This keeps the session usable for longer prompts.")
            }
        }
    }

    private func compact(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return "\(value / 1_000)k" }
        return "\(value)"
    }
}

private struct PiAgentSmartZoneContextBar: View {
    let percent: Double
    let showsSmartZoneHint: Bool
    let width: CGFloat
    let height: CGFloat

    private var clampedPercent: Double {
        min(max(percent, 0), 100)
    }

    private var warningThreshold: Double {
        showsSmartZoneHint ? 40 : 70
    }

    private var usageFill: AnyShapeStyle {
        if clampedPercent >= 90 {
            return AnyShapeStyle(Color.red.gradient)
        }
        if clampedPercent >= warningThreshold {
            return AnyShapeStyle(Color.orange.gradient)
        }
        return AnyShapeStyle(AppTheme.brandAccent.gradient)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule(style: .continuous)
                .fill(AppTheme.contentFill.opacity(0.75))

            Capsule(style: .continuous)
                .fill(usageFill)
                .frame(width: width * clampedPercent / 100)

            if showsSmartZoneHint {
                PiAgentSmartZoneDottedMarker()
                    .stroke(Color.primary.opacity(0.72), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [1, 3]))
                    .frame(width: 1.5, height: height)
                    .position(x: width * 0.4, y: height / 2)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: width, height: height)
        .clipShape(Capsule(style: .continuous))
        .accessibilityLabel(showsSmartZoneHint ? "Context usage with smart zone marker" : "Context usage")
        .accessibilityValue("\(Int(clampedPercent)) percent")
    }
}

private struct PiAgentSmartZoneDottedMarker: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}

struct PiAgentContextBreakdownPopover: View {
    let session: PiAgentSessionRecord
    let transcript: [PiAgentTranscriptEntry]
    let fallbackModels: [AvailableModel]
    let showsSmartZoneHint: Bool

    private var usedPercent: Double {
        min(max(session.contextPercent ?? 0, 0), 100)
    }

    private var estimate: PiAgentContextBreakdownEstimate {
        PiAgentContextEstimateBuilder.build(
            session: session,
            transcript: transcript,
            fallbackModels: fallbackModels
        )
    }

    private var promptComposition: PiAgentPromptCompositionEstimate? {
        PiAgentContextEstimateBuilder.buildPromptComposition(systemPrompt: session.finalSystemPrompt)
    }

    private var visibleRows: [PiAgentContextVisualRow] {
        if session.contextBreakdown.isEmpty == false {
            return session.contextBreakdown.map {
                PiAgentContextVisualRow(
                    key: $0.key,
                    title: $0.title,
                    tokens: $0.tokens,
                    percent: $0.percent,
                    tint: tint(for: $0.key)
                )
            }
        }
        return estimate.rows.map {
            PiAgentContextVisualRow(
                key: $0.key,
                title: $0.title,
                tokens: $0.tokens,
                percent: $0.percent,
                tint: tint(for: $0.key)
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Context usage")
                    .font(.headline.weight(.semibold))
                if let tokens = session.contextTokens, let window = session.contextWindow {
                    HStack(spacing: 4) {
                        Image(systemName: "tugriksign.circle")
                            .font(.caption.weight(.semibold))
                        Text("\(format(tokens)) of \(format(window)) tokens · \(formatPercent(usedPercent))")
                            .font(.caption.monospacedDigit().weight(.semibold))
                    }
                    .foregroundStyle(AppTheme.mutedText)
                } else {
                    Text("Exact usage will appear after Pi reports session stats.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                }
            }

            PiAgentContextDotGrid(rows: visibleRows)

            VStack(alignment: .leading, spacing: 8) {
                if session.contextBreakdown.isEmpty == false {
                    Text("Exact from Pi RPC")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppTheme.mutedText)
                    ForEach(session.contextBreakdown) { item in
                        PiAgentContextBreakdownRow(
                            title: item.title,
                            tokens: item.tokens,
                            percent: item.percent,
                            detail: item.detail,
                            tint: tint(for: item.key)
                        )
                    }
                } else {
                    Text("Estimated")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppTheme.mutedText)
                    if estimate.rows.isEmpty {
                        PiAgentContextBreakdownRow(
                            title: "Used context",
                            tokens: session.contextTokens,
                            percent: session.contextPercent,
                            detail: nil,
                            tint: usedPercent >= 90 ? .red : (usedPercent >= 70 ? .orange : AppTheme.brandAccent)
                        )
                    } else {
                        ForEach(estimate.rows) { row in
                            PiAgentContextBreakdownRow(
                                title: row.title,
                                tokens: row.tokens,
                                percent: row.percent,
                                detail: row.detail,
                                tint: tint(for: row.key)
                            )
                        }
                    }
                    Text(estimate.note)
                        .font(.caption.italic())
                        .foregroundStyle(AppTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let promptComposition, promptComposition.rows.isEmpty == false {
                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Text("Prompt composition")
                            .font(.caption.weight(.bold))
                        Spacer()
                        tokenLabel(promptComposition.totalTokens, prefix: "~")
                            .foregroundStyle(AppTheme.mutedText)
                    }
                    Text("Estimated from the captured Pi runtime system prompt.")
                        .font(.caption2.italic())
                        .foregroundStyle(AppTheme.mutedText)
                    ForEach(promptComposition.rows) { row in
                        PiAgentPromptCompositionRowView(
                            title: row.title,
                            tokens: row.tokens,
                            percent: row.percent,
                            tint: tint(for: row.key)
                        )
                    }
                }
            }

            if let inputTokens = session.inputTokens,
               let outputTokens = session.outputTokens,
               let toolCalls = session.toolCalls {
                Divider()
                HStack(spacing: 12) {
                    PiAgentContextStat(label: "Input", value: format(inputTokens), icon: "tugriksign.circle")
                    PiAgentContextStat(label: "Output", value: format(outputTokens), icon: "tugriksign.circle")
                    PiAgentContextStat(label: "Tools", value: "\(toolCalls)", icon: "wrench.and.screwdriver")
                }
            }
        }
        .padding(14)
        .frame(width: 360, alignment: .leading)
    }

    private func tint(for key: String) -> Color {
        switch key {
        case "systemPrompt", "system_prompt":
            return AppTheme.assistantAccent
        case "systemTools", "system_tools", "toolCalls", "tool_calls", "toolResults", "tool_results", "promptTools":
            return .blue
        case "promptSkills":
            return AppTheme.assistantAccent
        case "promptProjectContext":
            return .orange
        case "promptCore", "messages", "estimatedMessages", "estimatedInputTokens":
            return AppTheme.brandAccent
        case "estimatedOutputTokens":
            return .green
        case "estimatedCachedPromptTools", "estimatedCacheTokens":
            return .blue
        case "estimatedOtherUsedContext":
            return .orange
        case "freeSpace", "free_space", "estimatedFreeSpace":
            return .secondary
        case "autocompactBuffer", "autocompact_buffer", "estimatedOutputBuffer":
            return .gray
        default:
            return AppTheme.brandAccent
        }
    }

    private func format(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 10_000 { return "\(value / 1_000)k" }
        return value.formatted()
    }

    private func formatPercent(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }

    private func tokenLabel(_ value: Int, prefix: String = "") -> some View {
        HStack(spacing: 3) {
            Image(systemName: "tugriksign.circle")
                .font(.caption2.weight(.semibold))
            Text("\(prefix)\(format(value))")
                .font(.caption.monospacedDigit().weight(.semibold))
        }
    }
}

private struct PiAgentSmartZoneExplanation: View {
    let usedPercent: Double

    private var isPastSmartZone: Bool {
        usedPercent >= 40
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Smart zone hint", systemImage: isPastSmartZone ? "exclamationmark.triangle.fill" : "brain.head.profile")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(isPastSmartZone ? .orange : .green)
                Spacer()
                Text("40% marker")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(AppTheme.mutedText)
            }

            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(Color.green.opacity(0.26))
                            .frame(width: width * 0.4)
                        Rectangle()
                            .fill(Color.orange.opacity(0.18))
                    }
                    Rectangle()
                        .fill(Color.green.opacity(0.95))
                        .frame(width: 2)
                        .offset(x: width * 0.4 - 1)
                    HStack(spacing: 0) {
                        Text("Smart zone · first 40%")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.green)
                            .frame(width: width * 0.4, alignment: .center)
                        Text("Dumb zone / overload risk · last 60%")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.orange)
                            .frame(width: width * 0.6, alignment: .center)
                    }
                }
            }
            .frame(height: 24)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            Text("Matt Pocock describes a practical heuristic: the first ~40% of context is the model's “smart zone”; beyond that, more tokens can increase overload and decision mistakes. Treat this as a cautionary guide, not a hard model limit.")
                .font(.caption2)
                .foregroundStyle(AppTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)

            Link("Read the AIHero article", destination: URL(string: "https://www.aihero.dev/why-the-anthropic-ralph-plugin-sucks")!)
                .font(.caption2.weight(.semibold))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(AppTheme.contentSubtleFill).stroke(AppTheme.contentStroke, lineWidth: 1))
    }
}

private struct PiAgentContextBreakdownRow: View {
    let title: String
    let tokens: Int?
    let percent: Double?
    let detail: String?
    let tint: Color

    private var clampedPercent: Double {
        min(max(percent ?? 0, 0), 100)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                summaryView
                    .foregroundStyle(AppTheme.mutedText)
                    .lineLimit(1)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(AppTheme.contentSubtleFill)
                    Capsule(style: .continuous)
                        .fill(tint)
                        .frame(width: proxy.size.width * clampedPercent / 100)
                }
            }
            .frame(height: 6)
            if let detail, detail.isEmpty == false {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var summaryView: some View {
        switch (tokens, percent) {
        case let (tokens?, percent?):
            HStack(spacing: 4) {
                tokenValue(tokens)
                Text("· \(formatPercent(percent))")
                    .font(.caption.monospacedDigit().weight(.semibold))
            }
        case let (tokens?, nil):
            tokenValue(tokens)
        case let (nil, percent?):
            Text(formatPercent(percent))
                .font(.caption.monospacedDigit().weight(.semibold))
        default:
            Text("Unavailable")
                .font(.caption.monospacedDigit().weight(.semibold))
        }
    }

    private func tokenValue(_ value: Int) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "tugriksign.circle")
                .font(.caption2.weight(.semibold))
            Text(format(value))
                .font(.caption.monospacedDigit().weight(.semibold))
        }
    }

    private func format(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 10_000 { return "\(value / 1_000)k" }
        return value.formatted()
    }

    private func formatPercent(_ value: Double) -> String {
        String(format: "%.1f%%", min(max(value, 0), 100))
    }
}

private struct PiAgentContextVisualRow {
    let key: String
    let title: String
    let tokens: Int?
    let percent: Double?
    let tint: Color
}

private struct PiAgentContextDotGrid: View {
    let rows: [PiAgentContextVisualRow]

    private let columns = Array(repeating: GridItem(.fixed(13), spacing: 7), count: 10)
    private let totalCells = 80

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 7) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                PiAgentContextDotCellView(cell: cell)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHidden(true)
    }

    private var cells: [PiAgentContextDotCell] {
        let positiveRows = rows.filter { ($0.percent ?? 0) > 0 }
        guard positiveRows.isEmpty == false else {
            return Array(repeating: .empty, count: totalCells)
        }

        var output: [PiAgentContextDotCell] = []
        var remaining = totalCells
        for (index, row) in positiveRows.enumerated() {
            let percent = min(max(row.percent ?? 0, 0), 100)
            let requested = max(Int(((percent / 100) * Double(totalCells)).rounded()), percent > 0 ? 1 : 0)
            let count = index == positiveRows.count - 1 ? min(remaining, max(requested, 0)) : min(remaining, requested)
            guard count > 0 else { continue }
            output.append(contentsOf: Array(repeating: dotCell(for: row), count: count))
            remaining -= count
            if remaining <= 0 { break }
        }

        if output.count < totalCells {
            output.append(contentsOf: Array(repeating: .empty, count: totalCells - output.count))
        }
        return Array(output.prefix(totalCells))
    }

    private func dotCell(for row: PiAgentContextVisualRow) -> PiAgentContextDotCell {
        if row.key.localizedCaseInsensitiveContains("buffer") {
            return .hollow(row.tint)
        }
        if row.key.localizedCaseInsensitiveContains("free") {
            return .dim
        }
        return .filled(row.tint)
    }
}

private struct PiAgentContextDotCell {
    enum Style {
        case filled
        case hollow
        case dim
        case empty
    }

    var style: Style
    var tint: Color

    static func filled(_ tint: Color) -> PiAgentContextDotCell { .init(style: .filled, tint: tint) }
    static func hollow(_ tint: Color) -> PiAgentContextDotCell { .init(style: .hollow, tint: tint) }
    static let dim = PiAgentContextDotCell(style: .dim, tint: AppTheme.mutedText)
    static let empty = PiAgentContextDotCell(style: .empty, tint: AppTheme.mutedText)
}

private struct PiAgentContextDotCellView: View {
    let cell: PiAgentContextDotCell

    var body: some View {
        ZStack {
            switch cell.style {
            case .filled:
                Circle()
                    .fill(cell.tint.opacity(0.85))
                    .frame(width: 9, height: 9)
            case .hollow:
                Circle()
                    .stroke(cell.tint.opacity(0.82), lineWidth: 1.3)
                    .frame(width: 10, height: 10)
            case .dim:
                Circle()
                    .fill(AppTheme.mutedText.opacity(0.45))
                    .frame(width: 4, height: 4)
            case .empty:
                Circle()
                    .fill(AppTheme.mutedText.opacity(0.18))
                    .frame(width: 3, height: 3)
            }
        }
        .frame(width: 13, height: 13)
    }
}

private struct PiAgentPromptCompositionRowView: View {
    let title: String
    let tokens: Int
    let percent: Double
    let tint: Color

    private var clampedPercent: Double {
        min(max(percent, 0), 100)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    HStack(spacing: 3) {
                        Image(systemName: "tugriksign.circle")
                            .font(.caption2.weight(.semibold))
                        Text(format(tokens))
                            .font(.caption2.monospacedDigit().weight(.semibold))
                    }
                    Text("· \(formatPercent(percent))")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                }
                .foregroundStyle(AppTheme.mutedText)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(AppTheme.contentSubtleFill)
                    Capsule(style: .continuous)
                        .fill(tint)
                        .frame(width: proxy.size.width * clampedPercent / 100)
                }
            }
            .frame(height: 4)
        }
    }

    private func format(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 10_000 { return "\(value / 1_000)k" }
        return value.formatted()
    }

    private func formatPercent(_ value: Double) -> String {
        String(format: "%.1f%%", min(max(value, 0), 100))
    }
}

private struct PiAgentContextStat: View {
    let label: String
    let value: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AppTheme.mutedText)
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.caption2.weight(.semibold))
                Text(value)
                    .font(.caption.monospacedDigit().weight(.bold))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PiAgentModelStatus: View {
    let session: PiAgentSessionRecord

    var body: some View {
        HStack(spacing: 6) {
            modelIcon
            Text(modelLabel)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.footnote.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Capsule(style: .continuous).fill(AppTheme.contentSubtleFill).stroke(AppTheme.contentStroke, lineWidth: 1))
    }

    @ViewBuilder
    private var modelIcon: some View {
        if let provider = session.modelOverrideProvider ?? session.modelProvider,
           ProviderLogo.assetName(for: provider) != nil {
            ProviderLogoImage(provider: provider, size: 16)
        } else {
            Image(systemName: "cpu")
        }
    }

    private var modelLabel: String {
        if let provider = session.modelOverrideProvider ?? session.modelProvider,
           let model = session.modelOverrideID ?? session.model {
            return "\(provider)/\(model)"
        }
        return "Pi default model"
    }
}

struct PiAgentThinkingStatus: View {
    let level: String?

    var body: some View {
        Label("Thinking: \(displayLevel)", systemImage: "brain.head.profile")
            .font(.footnote.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Capsule(style: .continuous).fill(AppTheme.contentSubtleFill).stroke(AppTheme.contentStroke, lineWidth: 1))
    }

    private var displayLevel: String {
        guard let level, !level.isEmpty else { return "default" }
        return (level == "none" ? "off" : level).capitalized
    }
}

struct PiAgentShortcutChip: View {
    let symbol: String
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(key)
                .font(.caption2.monospaced().weight(.bold))
            Text(label)
                .fontWidth(.condensed)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(AppTheme.mutedText)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(Capsule(style: .continuous).fill(AppTheme.contentSubtleFill))
    }
}

struct PiAgentRuntimeFooter: View {
    let session: PiAgentSessionRecord

    var body: some View {
        HStack(spacing: 7) {
            if let total = session.totalTokens {
                metric("total \(compact(total))", icon: "tugriksign.circle")
            }
            if let input = session.inputTokens {
                metric("in \(compact(input))", icon: "arrow.down.left")
            }
            if let output = session.outputTokens {
                metric("out \(compact(output))", icon: "arrow.up.right")
            }
            if let cacheRead = session.cacheReadTokens, cacheRead > 0 {
                metric("cache \(compact(cacheRead))", icon: "memorychip")
            }
            if let toolCalls = session.toolCalls {
                metric("\(toolCalls) tools", icon: "wrench.and.screwdriver")
            }
            if let cost = session.cost {
                metric(String(format: "$%.2f", cost), icon: "dollarsign.circle")
            }
            metric("subagents: \(session.subagentsEnabled ? "on" : "off")", icon: "rectangle.connected.to.line.below")
        }
        .font(.caption)
        .foregroundStyle(AppTheme.mutedText)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metric(_ text: String, icon: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.caption2.weight(.semibold))
            Text(text)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.18), value: text)
        }
        .lineLimit(1)
    }

    private func compact(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return "\(value / 1_000)k" }
        return "\(value)"
    }
}

struct PiAgentModelPicker: View {
    let session: PiAgentSessionRecord
    let fallbackModels: [AvailableModel]
    let disabledModelIdentifiers: Set<String>
    let defaultModel: AvailableModel?
    let isRunning: Bool
    let onRefresh: () -> Void
    let onCycle: () -> Void
    let onSelect: (PiAgentModelSelection?) -> Void

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                modelIcon
                Text(modelLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(AppTheme.mutedText)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .frame(maxWidth: 220, alignment: .leading)
            .background(Capsule(style: .continuous).fill(AppTheme.contentSubtleFill).stroke(AppTheme.contentStroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Model", systemImage: "cpu")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.mutedText)
                    Spacer()
                    Button {
                        onRefresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help("Refresh models")
                    .accessibilityLabel("Refresh models")
                }

                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(groupedModelOptions, id: \.provider) { group in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 6) {
                                    ProviderLabel(provider: group.provider, logoSize: 14, spacing: 5)
                                        .font(.caption.weight(.bold))
                                        .fontWidth(.expanded)
                                        .foregroundStyle(.primary)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 2)

                                VStack(spacing: 3) {
                                    ForEach(group.models) { model in
                                        Button {
                                            onSelect(.init(provider: model.provider, modelID: model.id))
                                            isPresented = false
                                        } label: {
                                            modelRow(
                                                title: model.id,
                                                subtitle: modelMetadataSubtitle(model),
                                                isSelected: model.provider == resolvedProvider && model.id == resolvedModelID
                                            )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 340)
            }
            .padding(12)
            .frame(width: 360)
        }
        .help(isRunning ? "Change this Pi session's model" : "Choose a model for this session before launch")
    }

    private func modelRow(title: String, subtitle: String, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? AppTheme.brandAccent : AppTheme.mutedText)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.mutedText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(isSelected ? AppTheme.selectionFill : Color.clear))
    }

    @ViewBuilder
    private var modelIcon: some View {
        if let provider = resolvedProvider,
           ProviderLogo.assetName(for: provider) != nil {
            ProviderLogoImage(provider: provider, size: 16)
        } else {
            Image(systemName: "cpu")
        }
    }

    private var modelOptions: [PiAgentModelOption] {
        if let models = session.availableModels, !models.isEmpty {
            return models.filter { !disabledModelIdentifiers.contains($0.selectionID) }
        }
        return fallbackModels.map { model in
            PiAgentModelOption(
                provider: model.provider,
                id: model.model,
                name: nil,
                contextWindow: Int(model.contextWindow),
                supportsThinking: model.supportsThinking,
                supportedThinkingLevels: model.supportedThinkingLevels,
                supportsImages: model.supportsImages
            )
        }
    }

    private var groupedModelOptions: [(provider: String, models: [PiAgentModelOption])] {
        Dictionary(grouping: modelOptions, by: \.provider)
            .map { provider, models in
                (
                    provider: provider,
                    models: models.sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
                )
            }
            .sorted { $0.provider.localizedCaseInsensitiveCompare($1.provider) == .orderedAscending }
    }

    private func modelMetadataSubtitle(_ model: PiAgentModelOption) -> String {
        var badges: [String] = []
        if let contextWindow = model.contextWindow { badges.append("ctx \(compactModelNumber(contextWindow))") }
        if let maxOutput = model.maxOutput { badges.append("out \(compactModelNumber(maxOutput))") }
        badges.append(model.supportsThinking == false ? "no thinking" : "thinking")
        if model.supportsImages == true { badges.append("images") }
        return badges.joined(separator: " · ")
    }

    private func compactModelNumber(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return "\(value / 1_000)K" }
        return "\(value)"
    }

    private var isUsingPiDefault: Bool { session.modelOverrideProvider == nil && session.modelOverrideID == nil }
    private var effectiveProvider: String? { session.modelOverrideProvider ?? session.modelProvider }
    private var effectiveModelID: String? { session.modelOverrideID ?? session.model }
    private var resolvedProvider: String? { effectiveProvider ?? defaultModel?.provider }
    private var resolvedModelID: String? { effectiveModelID ?? defaultModel?.model }

    private var modelLabel: String {
        if let provider = resolvedProvider, let model = resolvedModelID {
            return "\(provider)/\(model)"
        }
        return "Model"
    }
}

struct PiAgentThinkingPicker: View {
    let level: String?
    let supportedLevels: [String]
    let defaultLevel: String
    let isRunning: Bool
    let onCycle: () -> Void
    let onSelect: (String) -> Void

    @State private var isPresented = false
    @State private var hoveredLevel: String?
    @State private var optimisticLevel: String?

    private var levels: [String] { supportedLevels.isEmpty ? ["off"] : supportedLevels }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "brain.head.profile")
                Text("Thinking: \(displayLevel.capitalized)")
                    .lineLimit(1)
                    .truncationMode(.head)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(AppTheme.mutedText)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule(style: .continuous).fill(AppTheme.contentSubtleFill).stroke(AppTheme.contentStroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Thinking", systemImage: "brain.head.profile")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.mutedText)

                ForEach(levels, id: \.self) { candidate in
                    thinkingLevelRow(candidate)
                }
            }
            .padding(12)
            .frame(width: 220)
        }
        .help(isRunning ? "Change thinking level" : "Choose thinking level for this session before launch")
        .onChange(of: normalizedLevel) { _, _ in
            optimisticLevel = nil
        }
        .onChange(of: defaultLevel) { _, _ in
            optimisticLevel = nil
        }
        .onChange(of: supportedLevels) { _, _ in
            optimisticLevel = nil
        }
    }

    private func thinkingLevelRow(_ candidate: String) -> some View {
        let isSelected = candidate == resolvedLevel
        let isHovered = hoveredLevel == candidate
        let rowShape = RoundedRectangle(cornerRadius: 9, style: .continuous)

        return Button {
            optimisticLevel = candidate
            onSelect(candidate)
            isPresented = false
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isSelected ? AppTheme.brandAccent : AppTheme.mutedText)
                    .frame(width: 18, height: 18)

                Text(candidate.capitalized)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .padding(.horizontal, 10)
            .background(rowShape.fill(rowFill(isSelected: isSelected, isHovered: isHovered)))
            .contentShape(rowShape)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredLevel = hovering ? candidate : (hoveredLevel == candidate ? nil : hoveredLevel)
        }
        .accessibilityLabel("Thinking \(candidate.capitalized)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func rowFill(isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected { return AppTheme.selectionFill }
        if isHovered { return AppTheme.contentSubtleFill }
        return .clear
    }

    private var normalizedLevel: String? {
        guard let level else { return nil }
        return level == "none" ? "off" : level
    }

    private var resolvedLevel: String {
        optimisticLevel ?? normalizedLevel ?? defaultLevel
    }

    private var displayLevel: String {
        levels.contains(resolvedLevel) ? resolvedLevel : "\(resolvedLevel) unavailable"
    }
}

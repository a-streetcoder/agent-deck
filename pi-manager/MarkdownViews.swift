import AppKit
import SwiftUI
import WebKit

struct MarkdownDocumentView: View {
    let source: String
    var minimumHeight: CGFloat = 24
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        MarkdownWebView(content: source, contentHeight: $contentHeight)
            .frame(height: max(minimumHeight, contentHeight))
    }
}

struct MarkdownTextView: View {
    let source: String

    var body: some View {
        let document = MarkdownRenderCache.document(for: source)

        VStack(alignment: .leading, spacing: document.frontmatter == nil ? 8 : 12) {
            if let frontmatter = document.frontmatter, !frontmatter.isEmpty {
                Text(frontmatter)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(AppTheme.mutedText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(AppTheme.contentSubtleFill)
                    )
            }

            ForEach(document.blocks) { block in
                blockView(block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block.kind {
        case .heading(let level, let text):
            inlineText(text)
                .font(level <= 1 ? .title3.weight(.bold) : .headline.weight(.semibold))
                .padding(.top, level <= 2 ? 4 : 2)
        case .paragraph(let text):
            inlineText(text)
                .font(.body)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AppTheme.mutedText)
                inlineText(text)
                    .font(.body)
            }
        case .numbered(let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number).")
                    .font(.body.monospacedDigit().weight(.semibold))
                    .foregroundStyle(AppTheme.mutedText)
                    .frame(minWidth: 22, alignment: .trailing)
                inlineText(text)
                    .font(.body)
            }
        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(AppTheme.contentStroke)
                    .frame(width: 3)
                inlineText(text)
                    .font(.body)
                    .foregroundStyle(AppTheme.mutedText)
            }
        case .code(let text):
            Text(text)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(AppTheme.contentSubtleFill))
        }
    }

    private func inlineText(_ text: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) {
            return Text(attributed)
        }
        return Text(text)
    }
}

private struct CachedMarkdownDocument: Sendable {
    let frontmatter: String?
    let blocks: [MarkdownBlock]
}

@MainActor
private enum MarkdownRenderCache {
    private static var cache: [String: CachedMarkdownDocument] = [:]
    private static var order: [String] = []
    private static let limit = 256

    static func document(for source: String) -> CachedMarkdownDocument {
        let key = cacheKey(for: source)
        if let cached = cache[key] { return cached }

        let parsed = RawFrontmatterParser.parse(source)
        let markdown = parsed?.content ?? source
        let document = CachedMarkdownDocument(frontmatter: parsed?.frontmatter, blocks: MarkdownBlock.parse(markdown))
        cache[key] = document
        order.append(key)
        if order.count > limit {
            let overflow = order.count - limit
            for oldKey in order.prefix(overflow) {
                cache[oldKey] = nil
            }
            order.removeFirst(overflow)
        }
        return document
    }

    private static func cacheKey(for source: String) -> String {
        var hasher = Hasher()
        hasher.combine(source)
        return "\(source.count):\(hasher.finalize())"
    }
}

private struct MarkdownBlock: Identifiable, Hashable {
    enum Kind: Hashable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet(String)
        case numbered(Int, String)
        case quote(String)
        case code(String)
    }

    let id: Int
    let kind: Kind

    static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String] = []
        var inCode = false

        func flushParagraph() {
            let text = paragraph.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
            paragraph.removeAll()
            guard !text.isEmpty else { return }
            blocks.append(.init(id: blocks.count, kind: .paragraph(text)))
        }

        func appendSimple(_ kind: Kind) {
            flushParagraph()
            blocks.append(.init(id: blocks.count, kind: kind))
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCode {
                    appendSimple(.code(code.joined(separator: "\n")))
                    code.removeAll()
                    inCode = false
                } else {
                    flushParagraph()
                    inCode = true
                    code.removeAll()
                }
                continue
            }
            if inCode {
                code.append(line)
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }
            if let heading = parseHeading(trimmed) {
                appendSimple(.heading(level: heading.level, text: heading.text))
            } else if let bullet = parseBullet(trimmed) {
                appendSimple(.bullet(bullet))
            } else if let numbered = parseNumbered(trimmed) {
                appendSimple(.numbered(numbered.number, numbered.text))
            } else if trimmed.hasPrefix(">") {
                appendSimple(.quote(trimmed.dropFirst().trimmingCharacters(in: .whitespaces)))
            } else {
                paragraph.append(line)
            }
        }
        if inCode {
            appendSimple(.code(code.joined(separator: "\n")))
        }
        flushParagraph()
        return blocks.isEmpty ? [.init(id: 0, kind: .paragraph(source))] : blocks
    }

    private static func parseHeading(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard hashes > 0, hashes <= 6, line.dropFirst(hashes).first == " " else { return nil }
        return (hashes, String(line.dropFirst(hashes + 1)))
    }

    private static func parseBullet(_ line: String) -> String? {
        guard line.count > 2 else { return nil }
        let prefixes = ["- ", "* ", "+ "]
        guard let prefix = prefixes.first(where: { line.hasPrefix($0) }) else { return nil }
        return String(line.dropFirst(prefix.count))
    }

    private static func parseNumbered(_ line: String) -> (number: Int, text: String)? {
        let pattern = #"^(\d+)[\.)]\s+(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)),
              let numberRange = Range(match.range(at: 1), in: line),
              let textRange = Range(match.range(at: 2), in: line),
              let number = Int(line[numberRange]) else { return nil }
        return (number, String(line[textRange]))
    }
}

private final class PassthroughWKWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

private struct MarkdownWebView: NSViewRepresentable {
    let content: String
    @Binding var contentHeight: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    private var contentHash: Int {
        var hasher = Hasher()
        hasher.combine(content)
        hasher.combine(colorScheme)
        return hasher.finalize()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(contentHeight: $contentHeight)
    }

    func makeNSView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "contentHeight")

        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        config.websiteDataStore = .nonPersistent()
        config.preferences.isElementFullscreenEnabled = false
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = PassthroughWKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = Self.dynamicBackgroundColor
        if let scrollView = webView.enclosingScrollView {
            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = true
            scrollView.verticalScrollElasticity = .none
            scrollView.horizontalScrollElasticity = .none
            scrollView.drawsBackground = false
            scrollView.backgroundColor = .clear
        }
        loadHTML(in: webView, context: context)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.underPageBackgroundColor = Self.dynamicBackgroundColor
        if context.coordinator.lastContentHash != contentHash {
            loadHTML(in: webView, context: context)
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.navigationDelegate = nil
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "contentHeight")
    }

    private func loadHTML(in webView: WKWebView, context: Context) {
        context.coordinator.prepareForContentLoad(contentHash: contentHash)
        let parsed = RawFrontmatterParser.parse(content)
        let markdown = parsed?.content ?? content
        let frontmatterHTML = parsed?.frontmatter.map(Self.frontmatterHTML) ?? ""
        let payload = Self.javaScriptStringLiteral(markdown)

        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:;">
        <style>\(Self.css)</style>
        <script>\(MarkedJSSource.source)</script>
        </head>
        <body>
            \(frontmatterHTML)
            <div id="markdown-root"></div>
            <script>
                const markdown = \(payload);
                const root = document.getElementById('markdown-root');
                root.innerHTML = marked.parse(markdown, {
                    gfm: true,
                    breaks: false
                });

                function reportHeight() {
                    const bodyStyle = window.getComputedStyle(document.body);
                    const paddingTop = parseFloat(bodyStyle.paddingTop || '0');
                    const paddingBottom = parseFloat(bodyStyle.paddingBottom || '0');
                    const range = document.createRange();
                    range.selectNodeContents(document.body);
                    const rect = range.getBoundingClientRect();
                    const rootRect = root.getBoundingClientRect();
                    const frontmatter = document.querySelector('.frontmatter');
                    const frontmatterRect = frontmatter ? frontmatter.getBoundingClientRect() : { height: 0 };
                    const contentHeight = Math.max(rect.height, rootRect.height + frontmatterRect.height);
                    const height = Math.ceil(contentHeight + paddingTop + paddingBottom + 2);
                    window.webkit.messageHandlers.contentHeight.postMessage(height);
                }

                const heightReportState = { pending: false };
                function scheduleHeightReport() {
                    if (heightReportState.pending) {
                        return;
                    }
                    heightReportState.pending = true;
                    requestAnimationFrame(() => {
                        heightReportState.pending = false;
                        reportHeight();
                    });
                }

                const observer = new MutationObserver(scheduleHeightReport);
                observer.observe(document.body, { childList: true, subtree: true, characterData: true, attributes: true });

                reportHeight();
                scheduleHeightReport();
                window.addEventListener('load', scheduleHeightReport, { once: true });
                window.addEventListener('resize', scheduleHeightReport);
            </script>
        </body>
        </html>
        """

        webView.loadHTMLString(html, baseURL: nil)
    }

    private static let dynamicBackgroundColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0x1A/255.0, green: 0x1A/255.0, blue: 0x1A/255.0, alpha: 1)
            : NSColor(red: 0xFA/255.0, green: 0xFA/255.0, blue: 0xFA/255.0, alpha: 1)
    }

    nonisolated private static func frontmatterHTML(_ frontmatter: String) -> String {
        let escaped = frontmatter
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return "<pre class=\"frontmatter\">\(escaped)</pre>"
    }

    nonisolated private static func javaScriptStringLiteral(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value], options: [])
        let arrayLiteral = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(arrayLiteral.dropFirst().dropLast())
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var lastContentHash: Int?
        private var lastReportedHeight: CGFloat = 0
        private var contentHeight: Binding<CGFloat>

        init(contentHeight: Binding<CGFloat>) {
            self.contentHeight = contentHeight
        }

        func prepareForContentLoad(contentHash: Int) {
            lastContentHash = contentHash
            lastReportedHeight = 0
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "contentHeight" else { return }
            if let height = message.body as? CGFloat {
                applyContentHeight(height)
            } else if let number = message.body as? NSNumber {
                applyContentHeight(CGFloat(number.doubleValue))
            }
        }

        private func applyContentHeight(_ height: CGFloat) {
            let sanitizedHeight = ceil(max(height, 0))
            guard abs(sanitizedHeight - lastReportedHeight) > 0.5 else { return }
            lastReportedHeight = sanitizedHeight

            Task { @MainActor in
                guard abs(self.contentHeight.wrappedValue - sanitizedHeight) > 0.5 else { return }
                self.contentHeight.wrappedValue = sanitizedHeight
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }

    private static let css = """
    * {
        margin: 0;
        padding: 0;
        box-sizing: border-box;
    }

    body {
        font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
        font-size: 16px;
        line-height: 1.6;
        width: 100%;
        max-width: 100%;
        margin: 0;
        padding: 16px 20px 8px;
        overflow-x: hidden;
        color: #222222;
        background-color: #FAFAFA;
        -webkit-font-smoothing: antialiased;
        -webkit-user-select: text;
    }

    @media (prefers-color-scheme: dark) {
        body {
            color: #E0E0E0;
            background-color: #1A1A1A;
        }
        a { color: #6699CC; }
        code {
            background-color: #2A2A2A !important;
            color: #E07070 !important;
        }
        pre {
            background-color: #2A2A2A !important;
            border-color: #333333 !important;
            color: #E0E0E0 !important;
        }
        pre code {
            background: none !important;
            color: #E0E0E0 !important;
        }
        blockquote {
            border-left-color: #444444;
            color: #999999;
        }
        table th {
            background-color: #2A2A2A;
            border-color: #444444;
        }
        table td {
            border-color: #333333;
        }
        table tr:nth-child(even) {
            background-color: #222222;
        }
        hr {
            border-color: #333333;
        }
        pre.frontmatter {
            color: #999999;
            background-color: #222222;
            border-color: #333333;
        }
    }

    h1, h2, h3, h4, h5, h6 {
        font-weight: 700;
        line-height: 1.3;
        margin-top: 1.5em;
        margin-bottom: 0.5em;
    }

    body > *:first-child {
        margin-top: 0;
    }

    h1 { font-size: 2em; }
    h2 { font-size: 1.5em; }
    h3 { font-size: 1.25em; }
    h4 { font-size: 1.1em; }

    p {
        margin-bottom: 1em;
    }

    a {
        color: #3366AA;
        text-decoration: none;
    }
    a:hover {
        text-decoration: underline;
    }

    code {
        font-family: "SF Mono", SFMono-Regular, Menlo, monospace;
        font-size: 0.85em;
        background-color: #F0F0F0;
        color: #CC3333;
        padding: 0.15em 0.35em;
        border-radius: 3px;
    }

    pre {
        background-color: #F5F5F5;
        border: 1px solid #E0E0E0;
        border-radius: 4px;
        padding: 1em;
        margin-bottom: 1em;
        overflow-x: auto;
        max-width: 100%;
    }

    pre code {
        background: none;
        color: inherit;
        padding: 0;
        font-size: 0.85em;
    }

    blockquote {
        border-left: 3px solid #CCCCCC;
        padding-left: 1em;
        margin-left: 0;
        margin-bottom: 1em;
        color: #666666;
        font-style: italic;
    }

    ul, ol {
        margin-bottom: 1em;
        padding-left: 1.5em;
    }

    li {
        margin-bottom: 0.25em;
    }

    ul.contains-task-list {
        list-style: none;
        padding-left: 0;
    }

    li.task-list-item {
        display: flex;
        align-items: baseline;
        gap: 0.5em;
    }

    li.task-list-item input[type="checkbox"] {
        margin: 0;
    }

    table {
        border-collapse: collapse;
        width: 100%;
        margin-bottom: 1em;
    }

    th, td {
        text-align: left;
        padding: 0.5em 0.75em;
    }

    th {
        font-weight: 600;
        background-color: #F5F5F5;
        border-bottom: 2px solid #DDDDDD;
    }

    td {
        border-bottom: 1px solid #EEEEEE;
    }

    tr:nth-child(even) {
        background-color: #FAFAFA;
    }

    del {
        text-decoration: line-through;
        opacity: 0.6;
    }

    hr {
        border: none;
        border-top: 1px solid #DDDDDD;
        margin: 2em 0;
    }

    img {
        max-width: 100%;
        height: auto;
    }

    #markdown-root {
        width: 100%;
        max-width: 100%;
        overflow-x: hidden;
    }

    #markdown-root > * {
        max-width: 100%;
    }

    pre.frontmatter {
        font-family: "SF Mono", SFMono-Regular, Menlo, monospace;
        font-size: 12px;
        line-height: 1.5;
        color: #333333;
        background-color: #F0F0F0;
        border: 1px solid transparent;
        border-radius: 6px;
        padding: 10px 12px;
        margin-bottom: 24px;
        white-space: pre-wrap;
        word-wrap: break-word;
    }
    """
}

private enum RawFrontmatterParser {
    struct Result {
        let frontmatter: String?
        let content: String
    }

    static func parse(_ text: String) -> Result? {
        let lines = text.components(separatedBy: "\n")

        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return nil
        }

        for index in 1..<lines.count {
            if lines[index].trimmingCharacters(in: .whitespaces) == "---" {
                let frontmatterLines = Array(lines[1..<index])
                let frontmatter = frontmatterLines.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let contentStart = min(index + 1, lines.count)
                let content = Array(lines[contentStart...]).joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return Result(frontmatter: frontmatter.isEmpty ? nil : frontmatter, content: content)
            }
        }

        return nil
    }
}

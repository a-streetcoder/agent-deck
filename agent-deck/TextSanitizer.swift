import Foundation

/// Strip terminal chrome that sometimes leaks into model text/thinking streams.
///
/// Some providers (or CLI wrappers) decorate thinking with truecolor SGR codes, e.g.
/// `ESC[38;2;138;190;183mThinking:ESC[39m …`. When ESC is dropped on the wire,
/// the orphan CSI body still appears as `[38;2;138;190;183mThinking:[39m`.
enum TextSanitizer {
    private static let esc = "\u{001B}"
    private static let bel = "\u{0007}"

    /// Full CSI / OSC sequences with ESC prefix.
    private static let ansiWithEsc: NSRegularExpression = {
        let e = NSRegularExpression.escapedPattern(for: esc)
        let b = NSRegularExpression.escapedPattern(for: bel)
        let pattern =
            "\(e)\\[[0-9;?]*[ -/]*[@-~]"
            + "|\(e)\\][^\(b)\(e)]*(?:\(b)|\(e)\\\\)"
            + "|\(e)."
        return compile(pattern, fallbackNeverMatch: true)
    }()

    /// Orphan SGR bodies when ESC was stripped (common in RPC paths).
    /// Matches e.g. `[38;2;138;190;183m`, `[39m`, `[0m`, `[1;32m`.
    private static let orphanSgr: NSRegularExpression = {
        compile(#"\[(?:\d{1,3};){0,8}\d{1,3}m"#)
    }()

    /// Leading decorative "Thinking:" labels some streams inject into thinking content.
    private static let thinkingLabel: NSRegularExpression = {
        compile(#"^(?:Thinking|thinking|思考)\s*[:：]\s*"#)
    }()

    /**
     Remove ANSI / orphan color codes from model-facing text.

     - Parameter text: Raw stream or snapshot text.
     - Returns: Clean UTF-8 string safe for SwiftUI labels.
     */
    static func stripAnsi(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var s = text
        s = replace(ansiWithEsc, in: s, with: "")
        s = replace(orphanSgr, in: s, with: "")
        s = s.replacingOccurrences(of: esc, with: "")
        s = s.replacingOccurrences(of: "\u{009B}", with: "")
        return s
    }

    /**
     Sanitize assistant **thinking** content: strip ANSI and decorative labels.

     - Parameter text: Raw thinking block or delta accumulation.
     - Returns: Display-ready thinking string.
     */
    static func sanitizeThinking(_ text: String) -> String {
        var s = stripAnsi(text)
        s = s.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        let range = NSRange(s.startIndex..., in: s)
        s = thinkingLabel.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "")
        return s.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
    }

    /**
     Sanitize assistant **answer** text: strip ANSI only (keep markdown structure).

     - Parameter text: Raw answer text.
     - Returns: Display-ready answer string.
     */
    static func sanitizeAnswer(_ text: String) -> String {
        stripAnsi(text)
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    /**
     Compile a regex without force-try.

     - Parameters:
       - pattern: ICU regular expression source.
       - fallbackNeverMatch: If true, use `a^` when compile fails.
     - Returns: A usable `NSRegularExpression`.
     */
    private static func compile(_ pattern: String, fallbackNeverMatch: Bool = true) -> NSRegularExpression {
        if let re = try? NSRegularExpression(pattern: pattern, options: []) {
            return re
        }
        if fallbackNeverMatch, let never = try? NSRegularExpression(pattern: "a^", options: []) {
            return never
        }
        return try! NSRegularExpression(pattern: "a^", options: [])
    }
}

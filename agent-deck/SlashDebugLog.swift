#if DEBUG
import Foundation

enum SlashDebugLog {
    static func textChange(oldText: String, newText: String) {
        let oldTrigger = slashTriggerDescription(in: oldText)
        let newTrigger = slashTriggerDescription(in: newText)
        guard oldText.contains("/") || newText.contains("/") || oldTrigger != nil || newTrigger != nil else { return }
        write("slash.text.change", [
            "oldLen": oldText.count,
            "newLen": newText.count,
            "oldTrigger": oldTrigger,
            "newTrigger": newTrigger,
            "oldSlashCount": oldText.filter { $0 == "/" }.count,
            "newSlashCount": newText.filter { $0 == "/" }.count
        ])
    }

    static func panelRender(rows: [SlashSuggestionRow], phase: String, query: String, universe: SlashUniverse) {
        var fields = universe.debugLogFields(rowCount: rows.count)
        fields["phase"] = phase
        fields["query"] = query
        fields["selectableRows"] = rows.lazy.filter(\.isSelectable).count
        write("slash.panel.render", fields)
    }

    private static let queue = DispatchQueue(label: "com.agent-deck.slash-debug-log")
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Pi Deck", isDirectory: true)
            .appendingPathComponent("slash-debug.log")
    }

    static func write(_ event: String, _ fields: [String: CustomStringConvertible?] = [:]) {
        let timestamp = formatter.string(from: Date())
        var parts = ["\(timestamp) \(event)"]
        for key in fields.keys.sorted() {
            guard let value = fields[key] ?? nil else { continue }
            parts.append("\(key)=\(sanitize(String(describing: value)))")
        }
        let line = parts.joined(separator: " ") + "\n"
        queue.async {
            let url = logURL
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let data = line.data(using: .utf8) {
                    if FileManager.default.fileExists(atPath: url.path) {
                        let handle = try FileHandle(forWritingTo: url)
                        try handle.seekToEnd()
                        try handle.write(contentsOf: data)
                        try handle.close()
                    } else {
                        try data.write(to: url, options: .atomic)
                    }
                }
            } catch {
                // DEBUG diagnostics only; never affect app behavior.
            }
        }
    }

    private static func slashTriggerDescription(in text: String) -> String? {
        guard !text.isEmpty else { return nil }
        let nsText = text as NSString
        let tokenRange = nsText.range(of: "[^\\s]+$", options: .regularExpression)
        guard tokenRange.location != NSNotFound,
              let range = Range(tokenRange, in: text) else { return nil }
        let token = String(text[range])
        guard token.first == "/" else { return nil }
        let prefix = text[..<range.lowerBound]
        guard prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "slashTokenNotAtStart" }
        return "slash(query:\(String(token.dropFirst()).lowercased()))"
    }

    private static func sanitize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: " ", with: "_")
    }
}

extension SlashUniverse {
    func debugLogFields(durationMS: Double? = nil, rowCount: Int? = nil) -> [String: CustomStringConvertible?] {
        var fields: [String: CustomStringConvertible?] = [
            "skillCount": skills.count,
            "promptCount": prompts.count,
            "commandCount": commands.count,
            "loopCount": loops.count,
            "itemCount": allItems.count,
            "activeSkillCount": skills.filter(\.isActive).count,
            "inactiveSkillCount": skills.filter { !$0.isActive }.count
        ]
        if let durationMS { fields["durationMS"] = String(format: "%.2f", durationMS) }
        if let rowCount { fields["rowCount"] = rowCount }
        return fields
    }
}
#endif

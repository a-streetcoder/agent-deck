import Foundation
import SwiftUI

/// A Pi "Retry" status entry parsed into a displayable shape.
///
/// Pi's auto-retry layer is provider-agnostic — it emits a `Retry` status per attempt
/// plus a final `auto_retry_end` for every model provider — so the generic fields here
/// (`gaveUp`, `message`) always apply. `codex` carries the richer detail we can only
/// resolve when the underlying payload is recognisably Codex.
struct ProviderRetryInfo: Equatable {
    /// True when Pi stopped retrying without success.
    var gaveUp: Bool
    /// Best-effort human-readable error message.
    var message: String
    /// Codex-only enrichment, present when the payload is recognisably Codex.
    var codex: CodexDetail?

    /// Provider-specific detail. Only Codex is parsed today; other providers fall back
    /// to the generic fields above (send a real error sample to add one).
    struct CodexDetail: Equatable {
        var isUsageLimit: Bool
        var planType: String?
        var resetsAt: Date?
    }

    /// Parses a Pi "Retry" transcript entry. Returns `nil` for any other entry.
    init?(entry: PiAgentTranscriptEntry) {
        guard entry.role == .status, entry.title == "Retry" else { return nil }

        let primary = entry.text.isEmpty ? (entry.rawJSON ?? "") : entry.text

        // The entry is either an `auto_retry_end` envelope (carries attempt/success and
        // a nested `finalError`) or a single attempt whose text is the error itself.
        var errorPayload = primary
        if let envelope = Self.firstJSONObject(in: primary),
           (envelope["type"] as? String) == "auto_retry_end" {
            self.gaveUp = (envelope["success"] as? Bool) == false
            if let finalError = envelope["finalError"] as? String { errorPayload = finalError }
        } else {
            self.gaveUp = false
        }

        self.codex = CodexDetail(payload: errorPayload, entryTimestamp: entry.timestamp)
        self.message = Self.humanMessage(from: errorPayload)
    }

    // MARK: Parsing helpers

    /// Best-effort human message: a provider's `error.message`/`message`, else the
    /// payload stripped of any `"… error:"` prefix and trailing JSON.
    private static func humanMessage(from payload: String) -> String {
        if let object = firstJSONObject(in: payload) {
            if let error = object["error"] as? [String: Any],
               let message = error["message"] as? String, !message.isEmpty {
                return message
            }
            if let message = object["message"] as? String, !message.isEmpty {
                return message
            }
            if let nested = (object["errorMessage"] ?? object["finalError"]) as? String {
                return humanMessage(from: nested)
            }
        }
        var text = payload
        if let brace = text.firstIndex(of: "{") { text = String(text[..<brace]) }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix(":") {
            text = String(text.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.isEmpty ? "The model provider returned an error." : text
    }

    /// First balanced `{…}` object in `string`, parsed. No recursion.
    fileprivate static func firstJSONObject(in string: String) -> [String: Any]? {
        guard let range = balancedJSONRange(in: string),
              let data = String(string[range]).data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Finds the Codex error object inside an arbitrary string, descending through a
    /// retry envelope that nests the payload as a string (`errorMessage`/`finalError`).
    fileprivate static func codexBlob(in string: String) -> [String: Any]? {
        guard let object = firstJSONObject(in: string) else { return nil }
        if let error = object["error"] as? [String: Any], error["type"] is String {
            return object
        }
        if let nested = (object["errorMessage"] ?? object["finalError"]) as? String {
            return codexBlob(in: nested)
        }
        return nil
    }

    /// Range of the first balanced `{…}` object in `string`, respecting string literals.
    private static func balancedJSONRange(in string: String) -> Range<String.Index>? {
        guard let start = string.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < string.endIndex {
            let ch = string[index]
            if inString {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
            } else if ch == "\"" {
                inString = true
            } else if ch == "{" {
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth == 0 { return start..<string.index(after: index) }
            }
            index = string.index(after: index)
        }
        return nil
    }
}

extension ProviderRetryInfo.CodexDetail {
    /// Returns `nil` unless `payload` carries a recognisably Codex error.
    init?(payload: String, entryTimestamp: Date) {
        guard payload.contains("X-Codex-") || payload.contains("Codex error")
        else { return nil }
        guard let blob = ProviderRetryInfo.codexBlob(in: payload),
              let errorObj = blob["error"] as? [String: Any],
              let kind = errorObj["type"] as? String
        else { return nil }

        let headers = blob["headers"] as? [String: Any]
        self.isUsageLimit = (kind == "usage_limit_reached")
        self.planType = (errorObj["plan_type"] as? String)
            ?? (headers?["X-Codex-Plan-Type"] as? String)

        if let resetsAt = (errorObj["resets_at"] as? NSNumber)?.doubleValue, resetsAt > 0 {
            self.resetsAt = Date(timeIntervalSince1970: resetsAt)
        } else if let resetIn = (errorObj["resets_in_seconds"] as? NSNumber)?.doubleValue, resetIn > 0 {
            // resets_in_seconds is relative to when the error occurred.
            self.resetsAt = entryTimestamp.addingTimeInterval(resetIn)
        } else if let header = headers?["X-Codex-Primary-Reset-At"] as? String,
                  let resetsAt = Double(header), resetsAt > 0 {
            self.resetsAt = Date(timeIntervalSince1970: resetsAt)
        } else {
            self.resetsAt = nil
        }
    }
}

/// Clean transcript card for a Pi retry burst — replaces the raw-JSON status row.
struct PiAgentRetryCard: View {
    let info: ProviderRetryInfo
    let timestamp: Date

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.callout.weight(.semibold))
                .foregroundStyle(accent)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(headline)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                if let resetLine {
                    Text(resetLine)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(accent)
                }
            }

            Spacer(minLength: 0)

            Text(timestamp.formatted(date: .omitted, time: .shortened))
                .font(.caption2)
                .foregroundStyle(AppTheme.mutedText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(accent.opacity(AppTheme.roleFillOpacity))
                .stroke(accent.opacity(AppTheme.roleStrokeOpacity), lineWidth: 1)
        )
    }

    private var isUsageLimit: Bool { info.codex?.isUsageLimit == true }

    // Usage limits and in-progress retries are transient → amber. A burst that gave
    // up for any other reason is a real failure → red.
    private var accent: Color {
        if isUsageLimit { return AppTheme.roleTool }
        return info.gaveUp ? AppTheme.roleError : AppTheme.roleTool
    }

    private var icon: String {
        if isUsageLimit { return "hourglass" }
        return info.gaveUp ? "exclamationmark.triangle.fill" : "arrow.triangle.2.circlepath"
    }

    private var headline: String {
        if isUsageLimit { return "Codex usage limit reached" }
        if info.gaveUp { return "Model provider stopped retrying" }
        return "Retrying request…"
    }

    private var detail: String {
        var text = info.message.isEmpty ? "The model provider returned an error." : info.message
        if let plan = info.codex?.planType, !plan.isEmpty {
            text += " (\(plan.capitalized) plan)"
        }
        return text
    }

    private var resetLine: String? {
        guard isUsageLimit, let resetsAt = info.codex?.resetsAt else { return nil }
        let absolute = resetsAt.formatted(date: .omitted, time: .shortened)
        if let relative = Self.relativeReset(to: resetsAt) {
            return "Resets at \(absolute) · in \(relative)"
        }
        return "Resets at \(absolute)"
    }

    private static func relativeReset(to date: Date) -> String? {
        let seconds = date.timeIntervalSinceNow
        guard seconds > 0 else { return nil }
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "under a minute" }
        if minutes < 60 { return "~\(minutes) min" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "~\(hours) hr" : "~\(hours) hr \(remainder) min"
    }
}

import Foundation
import SwiftUI

/// A Pi "Retry" status entry parsed into a displayable shape.
///
/// Pi's auto-retry layer is provider-agnostic — it emits a `Retry` status per attempt
/// plus a final `auto_retry_end` for every model provider — so `gaveUp`, `isQuotaLimit`
/// and `message` always apply. `resetsAt` / `planType` are filled in only when the
/// underlying provider payload is one we can parse (Codex, Gemini).
///
/// Parsing runs once at thread-build time (`chronologicalChildren`), never per render —
/// the parsed value rides on the `.retry` thread child, so the card itself does no work.
struct ProviderRetryInfo: Hashable {
    /// True when Pi stopped retrying without success.
    var gaveUp: Bool
    /// True when the error heuristically looks like a quota / rate-limit exhaustion.
    var isQuotaLimit: Bool
    /// Best-effort human-readable error message.
    var message: String
    /// When the limit clears, if the provider's payload tells us (Codex / Gemini).
    var resetsAt: Date?
    /// Codex-only plan tier, e.g. "plus".
    var planType: String?

    /// Parses a Pi "Retry" transcript entry. Returns `nil` for any other entry.
    init?(entry: PiAgentTranscriptEntry) {
        guard entry.role == .status, entry.title == "Retry" else { return nil }

        let primary = entry.text.isEmpty ? (entry.rawJSON ?? "") : entry.text

        // The entry is either an `auto_retry_end` envelope (carries success and a nested
        // `finalError`) or a single attempt whose text is the error itself.
        var errorPayload = primary
        if let envelope = Self.firstJSONObject(in: primary),
           (envelope["type"] as? String) == "auto_retry_end" {
            self.gaveUp = (envelope["success"] as? Bool) == false
            if let finalError = envelope["finalError"] as? String { errorPayload = finalError }
        } else {
            self.gaveUp = false
        }

        self.message = Self.humanMessage(from: errorPayload)
        self.isQuotaLimit = Self.detectsQuotaLimit(payload: errorPayload)

        let codex = Self.parseCodex(payload: errorPayload, entryTimestamp: entry.timestamp)
        self.planType = codex?.planType
        self.resetsAt = codex?.resetsAt
            ?? Self.parseGeminiReset(payload: errorPayload, entryTimestamp: entry.timestamp)
    }

    // MARK: Generic parsing

    /// Best-effort human message: a provider's `error.message` / `message`, else the
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

    /// Heuristic: does this retry payload look like a quota / rate-limit exhaustion?
    /// Conservative — curated keywords plus an HTTP 429 status code, no bare-substring
    /// matches. Works for any provider without a provider-specific parser.
    private static func detectsQuotaLimit(payload: String) -> Bool {
        let lower = payload.lowercased()
        let keywords = [
            "usage limit", "usage_limit", "rate limit", "rate_limit", "quota",
            "too many requests", "insufficient_quota", "resource_exhausted",
            "resource has been exhausted",
        ]
        if keywords.contains(where: { lower.contains($0) }) { return true }

        guard let object = firstJSONObject(in: payload) else { return false }
        func isTooManyRequests(_ dict: [String: Any]) -> Bool {
            ["status_code", "code", "status"].contains { key in
                (dict[key] as? NSNumber)?.intValue == 429
            }
        }
        if isTooManyRequests(object) { return true }
        if let error = object["error"] as? [String: Any], isTooManyRequests(error) {
            return true
        }
        return false
    }

    // MARK: Provider-specific reset times

    /// Codex: `error.resets_at` (unix), `error.resets_in_seconds`, or the
    /// `X-Codex-Primary-Reset-At` header — whichever is present.
    private static func parseCodex(payload: String, entryTimestamp: Date)
        -> (resetsAt: Date?, planType: String?)? {
        guard payload.contains("X-Codex-") || payload.contains("Codex error"),
              let object = errorJSON(in: payload) else { return nil }
        let error = object["error"] as? [String: Any]
        let headers = object["headers"] as? [String: Any]
        let planType = (error?["plan_type"] as? String)
            ?? (headers?["X-Codex-Plan-Type"] as? String)

        var resetsAt: Date?
        if let value = (error?["resets_at"] as? NSNumber)?.doubleValue, value > 0 {
            resetsAt = Date(timeIntervalSince1970: value)
        } else if let value = (error?["resets_in_seconds"] as? NSNumber)?.doubleValue, value > 0 {
            resetsAt = entryTimestamp.addingTimeInterval(value)
        } else if let header = headers?["X-Codex-Primary-Reset-At"] as? String,
                  let value = Double(header), value > 0 {
            resetsAt = Date(timeIntervalSince1970: value)
        }

        guard resetsAt != nil || planType != nil else { return nil }
        return (resetsAt, planType)
    }

    /// Gemini: a `RESOURCE_EXHAUSTED` error carries the wait in `error.details[]` →
    /// `google.rpc.RetryInfo.retryDelay` (a Go duration string, e.g. `"34s"`).
    private static func parseGeminiReset(payload: String, entryTimestamp: Date) -> Date? {
        guard payload.contains("RESOURCE_EXHAUSTED"),
              let object = errorJSON(in: payload),
              let error = object["error"] as? [String: Any],
              let details = error["details"] as? [Any] else { return nil }
        for case let detail as [String: Any] in details {
            guard let type = detail["@type"] as? String, type.contains("RetryInfo"),
                  let delay = detail["retryDelay"] as? String,
                  let seconds = parseGoDuration(delay) else { continue }
            return entryTimestamp.addingTimeInterval(seconds)
        }
        return nil
    }

    /// Parses a Go-style duration string (`"34s"`, `"1m30s"`, `"1.5s"`).
    private static func parseGoDuration(_ string: String) -> TimeInterval? {
        var total: TimeInterval = 0
        var number = ""
        var sawUnit = false
        for ch in string {
            if ch.isNumber || ch == "." {
                number.append(ch)
            } else {
                guard let value = Double(number) else { return nil }
                switch ch {
                case "h": total += value * 3600
                case "m": total += value * 60
                case "s": total += value
                default: return nil
                }
                number = ""
                sawUnit = true
            }
        }
        return (sawUnit && number.isEmpty) ? total : nil
    }

    // MARK: JSON helpers

    /// First balanced `{…}` object in `string`, parsed. No recursion.
    private static func firstJSONObject(in string: String) -> [String: Any]? {
        guard let range = balancedJSONRange(in: string),
              let data = String(string[range]).data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Resolves the object carrying the provider `error`, descending through a retry
    /// envelope that nests the payload as a string (`errorMessage` / `finalError`).
    private static func errorJSON(in string: String) -> [String: Any]? {
        guard let object = firstJSONObject(in: string) else { return nil }
        if object["error"] == nil,
           let nested = (object["errorMessage"] ?? object["finalError"]) as? String {
            return errorJSON(in: nested)
        }
        return object
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

    // Quota limits and in-progress retries are transient → amber. A burst that gave
    // up for any other reason is a real failure → red.
    private var accent: Color {
        if info.isQuotaLimit { return AppTheme.roleTool }
        return info.gaveUp ? AppTheme.roleError : AppTheme.roleTool
    }

    private var icon: String {
        if info.isQuotaLimit { return "hourglass" }
        return info.gaveUp ? "exclamationmark.triangle.fill" : "arrow.triangle.2.circlepath"
    }

    private var headline: String {
        if info.isQuotaLimit { return "Usage limit reached" }
        if info.gaveUp { return "Model provider stopped retrying" }
        return "Retrying request…"
    }

    private var detail: String {
        var text = info.message.isEmpty ? "The model provider returned an error." : info.message
        if let plan = info.planType, !plan.isEmpty {
            text += " (\(plan.capitalized) plan)"
        }
        return text
    }

    private var resetLine: String? {
        guard let resetsAt = info.resetsAt else { return nil }
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

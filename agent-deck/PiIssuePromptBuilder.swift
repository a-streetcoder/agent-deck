import Foundation

enum PiIssuePromptBuilder {
    static func projectPrompt(project: DiscoveredProject, initialInstruction: String) -> String {
        initialInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func issueDraft(detail: GitHubIssueDetail, project: DiscoveredProject) -> String {
        ""
    }

    static func rpcMessage(userText: String, issue: PiAgentIssueAttachment, projectName: String, projectPath: String) -> String {
        let visibleText = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = issueContextBlock(issue: issue, projectName: projectName, projectPath: projectPath)
        return [visibleText, context].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private static func issueContextBlock(issue: PiAgentIssueAttachment, projectName: String, projectPath: String) -> String {
        var lines: [String] = [
            "<github-issue-context>",
            "project: \(projectName)",
            "project-path: \(projectPath)",
            "repository: \(issue.repository)",
            "issue-number: \(issue.number)",
            "title: \(issue.title)",
            "url: \(issue.url.absoluteString)",
            "state: \(issue.state)"
        ]

        if let stateReason = trimmed(issue.stateReason) {
            lines.append("state-reason: \(stateReason)")
        }
        if let type = trimmed(issue.type) {
            lines.append("type: \(type)")
        }
        if let author = trimmed(issue.author) {
            lines.append("author: \(author)")
        }
        if !issue.assignees.isEmpty {
            lines.append("assignees: \(issue.assignees.joined(separator: ", "))")
        }
        if !issue.labels.isEmpty {
            lines.append("labels: \(issue.labels.joined(separator: ", "))")
        }

        lines.append("created-at: \(iso8601(issue.createdAt))")
        lines.append("updated-at: \(iso8601(issue.updatedAt))")
        if let closedAt = issue.closedAt {
            lines.append("closed-at: \(iso8601(closedAt))")
        }

        let body = trimmed(issue.body) ?? "(empty)"
        lines.append("")
        lines.append("body:")
        lines.append(body)

        let relationships = relationshipLines(issue)
        if !relationships.isEmpty {
            lines.append("")
            lines.append("relationships:")
            lines.append(contentsOf: relationships)
        }

        lines.append("")
        lines.append("comments:")
        if issue.comments.isEmpty {
            lines.append("(none)")
        } else {
            for comment in issue.comments {
                lines.append("")
                lines.append("[comment #\(comment.id)]")
                lines.append("author: \(comment.author)")
                lines.append("created-at: \(iso8601(comment.createdAt))")
                if comment.updatedAt != comment.createdAt {
                    lines.append("updated-at: \(iso8601(comment.updatedAt))")
                }
                lines.append("url: \(comment.url.absoluteString)")
                lines.append("body:")
                lines.append(trimmed(comment.body) ?? "(empty)")
            }
        }

        lines.append("</github-issue-context>")
        return lines.joined(separator: "\n")
    }

    private static func relationshipLines(_ issue: PiAgentIssueAttachment) -> [String] {
        var lines: [String] = []
        if let parent = issue.parent {
            lines.append("- parent: \(referenceSummary(parent))")
        }
        lines.append(contentsOf: issue.subIssues.map { "- sub-issue: \(referenceSummary($0))" })
        lines.append(contentsOf: issue.blockedBy.map { "- blocked-by: \(referenceSummary($0))" })
        lines.append(contentsOf: issue.blocking.map { "- blocking: \(referenceSummary($0))" })
        return lines
    }

    private static func referenceSummary(_ reference: PiAgentIssueReferenceAttachment) -> String {
        var parts = ["\(reference.repository)#\(reference.number)", reference.title]
        if let type = trimmed(reference.type) {
            parts.append("[\(type)]")
        }
        parts.append("{\(reference.state)}")
        return parts.joined(separator: " ")
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

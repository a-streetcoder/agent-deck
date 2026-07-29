import Foundation

nonisolated enum GitHubHostKind: String, Hashable, Sendable {
    case github
    case other
}

nonisolated struct GitHubRemote: Hashable, Sendable {
    let host: String
    let owner: String
    let repo: String
    let remoteURL: String

    var hostKind: GitHubHostKind {
        host.caseInsensitiveCompare("github.com") == .orderedSame ? .github : .other
    }

    var nameWithOwner: String {
        "\(owner)/\(repo)"
    }

    var isGitHubDotCom: Bool {
        hostKind == .github
    }
}

nonisolated struct GitHubHostAccount: Hashable, Sendable {
    let host: String
    let login: String
    let scopes: [String]
    let gitProtocol: String?
    let tokenSource: String?
    let isActive: Bool
}

nonisolated struct GitHubSession: Hashable, Sendable {
    let source: GitHubSessionSource
    let account: GitHubHostAccount
}

nonisolated enum GitHubSessionSource: String, Hashable, Sendable {
    case ghCLI = "GitHub CLI"
    case nativeOAuth = "GitHub Sign-In"
}

nonisolated enum GitHubConnectionState: Hashable, Sendable {
    case unavailable(reason: String)
    case disconnected
    case checking
    case available(GitHubHostAccount)
    case connected(GitHubHostAccount)
    case failed(message: String)

    var summary: String {
        switch self {
        case let .unavailable(reason):
            return reason
        case .disconnected:
            return "Not connected"
        case .checking:
            return "Checking GitHub status…"
        case let .available(account):
            return "GitHub CLI authenticated as \(account.login)"
        case let .connected(account):
            return "Connected as \(account.login)"
        case let .failed(message):
            return message
        }
    }

    var account: GitHubHostAccount? {
        switch self {
        case let .available(account), let .connected(account):
            return account
        default:
            return nil
        }
    }

    var isConnected: Bool {
        if case .connected = self {
            return true
        }
        return false
    }
}

nonisolated enum GitDiffKind: String, Hashable {
    case staged = "Staged"
    case unstaged = "Unstaged"
    case untracked = "Untracked"
    case conflicted = "Conflicted"
}

nonisolated struct RepositoryFileChange: Identifiable, Hashable {
    let path: String
    let indexStatus: Character
    let worktreeStatus: Character

    var id: String { path }
    var isUntracked: Bool { indexStatus == "?" && worktreeStatus == "?" }
    var isConflicted: Bool {
        [indexStatus, worktreeStatus].contains("U") ||
        (indexStatus == "A" && worktreeStatus == "A") ||
        (indexStatus == "D" && worktreeStatus == "D")
    }
    var hasIndexChanges: Bool { indexStatus != " " && indexStatus != "?" }
    var hasWorktreeChanges: Bool { worktreeStatus != " " && worktreeStatus != "?" }
    var statusSummary: String { "\(indexStatus)\(worktreeStatus)" }
}

nonisolated struct RepositoryChangesSnapshot: Hashable {
    let branchName: String
    let upstreamBranch: String?
    let aheadCount: Int
    let behindCount: Int
    let staged: [RepositoryFileChange]
    let unstaged: [RepositoryFileChange]
    let untracked: [RepositoryFileChange]
    let conflicted: [RepositoryFileChange]

    var totalChangeCount: Int {
        staged.count + unstaged.count + untracked.count + conflicted.count
    }

    var canCommit: Bool {
        !staged.isEmpty
    }

    var canPush: Bool {
        upstreamBranch != nil && aheadCount > 0
    }

    var canStageAll: Bool {
        !unstaged.isEmpty || !untracked.isEmpty || !conflicted.isEmpty
    }

    var canUnstageAll: Bool {
        !staged.isEmpty
    }
}

nonisolated struct PiAgentIssueCommentAttachment: Identifiable, Codable, Hashable {
    let id: Int
    let author: String
    let body: String
    let createdAt: Date
    let updatedAt: Date
    let url: URL
}

nonisolated struct PiAgentIssueReferenceAttachment: Codable, Hashable {
    let repository: String
    let number: Int
    let title: String
    let url: URL
    let state: String
    let type: String?
}

/// Historical transcript payload for issue/PR chips. Kept for decoding older sessions only.
nonisolated struct PiAgentIssueAttachment: Identifiable, Codable, Hashable {
    let repository: String
    let number: Int
    let title: String
    let url: URL
    let state: String
    let type: String?
    let isPullRequest: Bool
    let author: String?
    let labels: [String]
    let assignees: [String]
    let createdAt: Date
    let updatedAt: Date
    let closedAt: Date?
    let stateReason: String?
    let body: String
    let parent: PiAgentIssueReferenceAttachment?
    let subIssues: [PiAgentIssueReferenceAttachment]
    let blockedBy: [PiAgentIssueReferenceAttachment]
    let blocking: [PiAgentIssueReferenceAttachment]
    let comments: [PiAgentIssueCommentAttachment]

    var id: String { "\(repository)#\(number)" }
    var kindTitle: String { isPullRequest ? "Pull Request" : "Issue" }
    var kindShortTitle: String { isPullRequest ? "PR" : "Issue" }

    private enum CodingKeys: String, CodingKey {
        case repository, number, title, url, state, type, isPullRequest, author, labels, assignees
        case createdAt, updatedAt, closedAt, stateReason, body, parent, subIssues, blockedBy, blocking, comments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        repository = try container.decode(String.self, forKey: .repository)
        number = try container.decode(Int.self, forKey: .number)
        title = try container.decode(String.self, forKey: .title)
        url = try container.decode(URL.self, forKey: .url)
        state = try container.decode(String.self, forKey: .state)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        isPullRequest = try container.decodeIfPresent(Bool.self, forKey: .isPullRequest) ?? false
        author = try container.decodeIfPresent(String.self, forKey: .author)
        labels = try container.decode([String].self, forKey: .labels)
        assignees = try container.decode([String].self, forKey: .assignees)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        closedAt = try container.decodeIfPresent(Date.self, forKey: .closedAt)
        stateReason = try container.decodeIfPresent(String.self, forKey: .stateReason)
        body = try container.decode(String.self, forKey: .body)
        parent = try container.decodeIfPresent(PiAgentIssueReferenceAttachment.self, forKey: .parent)
        subIssues = try container.decode([PiAgentIssueReferenceAttachment].self, forKey: .subIssues)
        blockedBy = try container.decode([PiAgentIssueReferenceAttachment].self, forKey: .blockedBy)
        blocking = try container.decode([PiAgentIssueReferenceAttachment].self, forKey: .blocking)
        comments = try container.decode([PiAgentIssueCommentAttachment].self, forKey: .comments)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(repository, forKey: .repository)
        try container.encode(number, forKey: .number)
        try container.encode(title, forKey: .title)
        try container.encode(url, forKey: .url)
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(type, forKey: .type)
        try container.encode(isPullRequest, forKey: .isPullRequest)
        try container.encodeIfPresent(author, forKey: .author)
        try container.encode(labels, forKey: .labels)
        try container.encode(assignees, forKey: .assignees)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(closedAt, forKey: .closedAt)
        try container.encodeIfPresent(stateReason, forKey: .stateReason)
        try container.encode(body, forKey: .body)
        try container.encodeIfPresent(parent, forKey: .parent)
        try container.encode(subIssues, forKey: .subIssues)
        try container.encode(blockedBy, forKey: .blockedBy)
        try container.encode(blocking, forKey: .blocking)
        try container.encode(comments, forKey: .comments)
    }
}

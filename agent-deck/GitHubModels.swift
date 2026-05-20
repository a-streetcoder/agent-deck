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
    let token: String
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

nonisolated enum GitHubIssueStateFilter: String, CaseIterable, Identifiable {
    case open = "Open"
    case closed = "Closed"
    case all = "All"

    var id: String { rawValue }

    var searchQualifier: String? {
        switch self {
        case .open: return "is:open"
        case .closed: return "is:closed"
        case .all: return nil
        }
    }
}

nonisolated struct GitHubIssueRelationshipSummary: Hashable {
    let blockedBy: Int
    let totalBlockedBy: Int
    let blocking: Int
    let totalBlocking: Int

    var hasRelationships: Bool {
        blockedBy > 0 || totalBlockedBy > 0 || blocking > 0 || totalBlocking > 0
    }
}

nonisolated struct GitHubSubIssuesSummary: Hashable {
    let total: Int
    let completed: Int
    let percentCompleted: Int

    var hasSubIssues: Bool { total > 0 }
}

nonisolated struct GitHubIssueReference: Identifiable, Hashable {
    let id: Int
    let number: Int
    let title: String
    let repository: String
    let url: URL
    let state: String
    let type: String?
}

nonisolated struct GitHubWorkItem: Identifiable, Hashable {
    let id: String
    let number: Int
    let title: String
    let repository: String
    let url: URL
    let isPullRequest: Bool
    let state: String
    let stateReason: String?
    let type: String?
    let labels: [String]
    let assignees: [String]
    let author: String?
    let body: String
    let commentCount: Int
    let createdAt: Date
    let updatedAt: Date
    let closedAt: Date?
    let subIssuesSummary: GitHubSubIssuesSummary?
    let issueDependenciesSummary: GitHubIssueRelationshipSummary?

    func with(state: String, closedAt: Date?) -> GitHubWorkItem {
        GitHubWorkItem(
            id: id,
            number: number,
            title: title,
            repository: repository,
            url: url,
            isPullRequest: isPullRequest,
            state: state,
            stateReason: stateReason,
            type: type,
            labels: labels,
            assignees: assignees,
            author: author,
            body: body,
            commentCount: commentCount,
            createdAt: createdAt,
            updatedAt: updatedAt,
            closedAt: closedAt,
            subIssuesSummary: subIssuesSummary,
            issueDependenciesSummary: issueDependenciesSummary
        )
    }
}

nonisolated struct GitHubBoardColumn: Identifiable, Hashable {
    let title: String
    let items: [GitHubWorkItem]

    var id: String { title }
}

nonisolated struct GitHubBoardSnapshot: Hashable {
    let columns: [GitHubBoardColumn]
    let totalCount: Int
    let shownCount: Int
    let incompleteResults: Bool
    let queryDescription: String
    let rateLimitRemaining: Int?
    let rateLimitResetAt: Date?

    var allItems: [GitHubWorkItem] {
        columns
            .flatMap(\.items)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func replacing(_ item: GitHubWorkItem) -> GitHubBoardSnapshot {
        let updatedColumns = columns.map { column in
            GitHubBoardColumn(
                title: column.title,
                items: column.items.map { $0.id == item.id ? item : $0 }
            )
        }
        return GitHubBoardSnapshot(
            columns: updatedColumns,
            totalCount: totalCount,
            shownCount: shownCount,
            incompleteResults: incompleteResults,
            queryDescription: queryDescription,
            rateLimitRemaining: rateLimitRemaining,
            rateLimitResetAt: rateLimitResetAt
        )
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

nonisolated struct GitHubIssueComment: Identifiable, Hashable {
    let id: Int
    let author: String
    let body: String
    let createdAt: Date
    let updatedAt: Date
    let url: URL
}

nonisolated struct GitHubIssueDetail: Hashable {
    let item: GitHubWorkItem
    let body: String
    let state: String
    let stateReason: String?
    let type: String?
    let author: String?
    let assignees: [String]
    let labels: [String]
    let createdAt: Date
    let updatedAt: Date
    let closedAt: Date?
    let parent: GitHubIssueReference?
    let subIssues: [GitHubIssueReference]
    let blockedBy: [GitHubIssueReference]
    let blocking: [GitHubIssueReference]
    let comments: [GitHubIssueComment]

    func with(state: String, closedAt: Date?) -> GitHubIssueDetail {
        GitHubIssueDetail(
            item: item.with(state: state, closedAt: closedAt),
            body: body,
            state: state,
            stateReason: stateReason,
            type: type,
            author: author,
            assignees: assignees,
            labels: labels,
            createdAt: createdAt,
            updatedAt: updatedAt,
            closedAt: closedAt,
            parent: parent,
            subIssues: subIssues,
            blockedBy: blockedBy,
            blocking: blocking,
            comments: comments
        )
    }
}

nonisolated struct PiAgentIssueCommentAttachment: Identifiable, Codable, Hashable {
    let id: Int
    let author: String
    let body: String
    let createdAt: Date
    let updatedAt: Date
    let url: URL

    init(comment: GitHubIssueComment) {
        self.id = comment.id
        self.author = comment.author
        self.body = comment.body
        self.createdAt = comment.createdAt
        self.updatedAt = comment.updatedAt
        self.url = comment.url
    }
}

nonisolated struct PiAgentIssueReferenceAttachment: Codable, Hashable {
    let repository: String
    let number: Int
    let title: String
    let url: URL
    let state: String
    let type: String?

    init(reference: GitHubIssueReference) {
        self.repository = reference.repository
        self.number = reference.number
        self.title = reference.title
        self.url = reference.url
        self.state = reference.state
        self.type = reference.type
    }
}

nonisolated struct PiAgentIssueAttachment: Identifiable, Codable, Hashable {
    let repository: String
    let number: Int
    let title: String
    let url: URL
    let state: String
    let type: String?
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

    init(detail: GitHubIssueDetail) {
        self.repository = detail.item.repository
        self.number = detail.item.number
        self.title = detail.item.title
        self.url = detail.item.url
        self.state = detail.state
        self.type = detail.type
        self.author = detail.author
        self.labels = detail.labels
        self.assignees = detail.assignees
        self.createdAt = detail.createdAt
        self.updatedAt = detail.updatedAt
        self.closedAt = detail.closedAt
        self.stateReason = detail.stateReason
        self.body = detail.body
        self.parent = detail.parent.map(PiAgentIssueReferenceAttachment.init(reference:))
        self.subIssues = detail.subIssues.map(PiAgentIssueReferenceAttachment.init(reference:))
        self.blockedBy = detail.blockedBy.map(PiAgentIssueReferenceAttachment.init(reference:))
        self.blocking = detail.blocking.map(PiAgentIssueReferenceAttachment.init(reference:))
        self.comments = detail.comments.map(PiAgentIssueCommentAttachment.init(comment:))
    }
}

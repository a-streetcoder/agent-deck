import Foundation

/// A skill repository imported from GitHub / skills.sh and cloned into
/// app-managed storage. The selected skill roots inside the clone are
/// registered in `AppSettings.externalSkillPaths` like any other catalog
/// entry; this record holds the extra git metadata needed to check for and
/// apply upstream updates.
nonisolated struct ImportedSkillRepository: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    /// Normalized https clone URL, never carrying credentials.
    var remoteURL: String
    var owner: String
    var repo: String
    /// Branch the clone tracks.
    var ref: String
    /// App-managed clone directory.
    var clonePath: String
    /// Repo-relative skill root directories that have been checked out.
    /// An empty string entry means the repo root itself is the skill.
    var syncedSkillRelativePaths: [String]
    /// `HEAD` commit at the last successful sync (clone or update).
    var lastSyncedCommit: String
    var lastSyncedDate: Date
    /// When the user last ran "Check for Updates", if ever.
    var lastCheckedDate: Date?
    /// Remote `HEAD` recorded by the last manual update check.
    var latestKnownRemoteCommit: String?

    var displayName: String { "\(owner)/\(repo)" }

    var webURL: URL? {
        URL(string: "https://github.com/\(owner)/\(repo)")
    }

    /// True when the last manual check found a commit ahead of what is synced.
    var hasKnownUpdate: Bool {
        guard let latestKnownRemoteCommit, !latestKnownRemoteCommit.isEmpty else { return false }
        return latestKnownRemoteCommit != lastSyncedCommit
    }

    /// Absolute on-disk paths of the synced skill roots.
    var syncedSkillRootPaths: [String] {
        let base = URL(fileURLWithPath: clonePath, isDirectory: true)
        return syncedSkillRelativePaths.map { relativePath in
            relativePath.isEmpty
                ? base.standardizedFileURL.path
                : base.appendingPathComponent(relativePath, isDirectory: true).standardizedFileURL.path
        }
    }

    /// True when `skillFilePath` (a `SKILL.md` path) lives inside this clone.
    func contains(skillFilePath: String) -> Bool {
        let standardizedClone = URL(fileURLWithPath: clonePath, isDirectory: true).standardizedFileURL.path
        let standardizedSkill = URL(fileURLWithPath: skillFilePath).standardizedFileURL.path
        return standardizedSkill == standardizedClone
            || standardizedSkill.hasPrefix(standardizedClone + "/")
    }
}

/// A git remote parsed from user input: a GitHub URL, `owner/repo` shorthand,
/// a skills.sh URL, or a generic git URL — plus an optional skill the input
/// pointed directly at (a skills.sh deep link or a `/tree/<branch>/<path>`).
nonisolated struct RemoteSkillSource: Hashable, Sendable {
    /// https clone URL.
    var remoteURL: String
    var owner: String
    var repo: String
    /// Explicit branch from a `/tree/<branch>` URL; `nil` uses the default branch.
    var ref: String?
    /// Skill folder slug the input pointed at, if any (e.g. a skills.sh deep link).
    var preselectedSkillSlug: String?

    var displayName: String { "\(owner)/\(repo)" }
}

/// A skill discovered inside a remote repo during the import sheet's "Fetch"
/// step, before anything is checked out.
nonisolated struct RemoteSkillCandidate: Identifiable, Hashable, Sendable {
    let name: String
    let description: String?
    /// Repo-relative skill root directory; empty when `SKILL.md` is at the repo root.
    let repoRelativeDirectory: String
    /// Count of `.md` files under the skill directory besides `SKILL.md`.
    let referenceFileCount: Int

    var id: String { repoRelativeDirectory.isEmpty ? "<root>" : repoRelativeDirectory }

    /// True when the whole repo is the skill (`SKILL.md` at the repo root).
    var isWholeRepository: Bool { repoRelativeDirectory.isEmpty }
}

/// Metadata returned by a discovery clone, before any skill is checked out.
nonisolated struct ClonedRepositoryInfo: Sendable {
    let clonePath: String
    /// Branch the clone actually checked out (the repo default unless overridden).
    let resolvedRef: String
    let headCommit: String
}

nonisolated enum SkillRepositoryUpdateStatus: Hashable, Sendable {
    case upToDate
    case updateAvailable(remoteCommit: String)
}

/// How the user chose to resolve a single conflicting skill file during an update.
nonisolated enum SkillConflictResolution: String, Hashable, Sendable {
    case keepMine
    case takeRemote
}

/// A file changed both locally (an in-place edit) and upstream, so a plain
/// fast-forward update cannot apply cleanly.
nonisolated struct SkillRepositoryConflict: Identifiable, Hashable, Sendable {
    /// Repo-relative path of the conflicting file.
    let repoRelativePath: String

    var id: String { repoRelativePath }
    var fileName: String { (repoRelativePath as NSString).lastPathComponent }
}

nonisolated enum SkillRepositoryUpdateOutcome: Sendable {
    case alreadyUpToDate
    case updated(newCommit: String)
    case conflicts([SkillRepositoryConflict])
}

/// Everything the import sheet needs after fetching a repo: the discovered
/// skills, the clone they live in, and — when the repo is already imported —
/// the existing record so a re-fetch adds skills instead of re-cloning.
nonisolated struct RemoteSkillImportContext: Hashable, Sendable {
    let source: RemoteSkillSource
    let clonePath: URL
    let resolvedRef: String
    let headCommit: String
    let candidates: [RemoteSkillCandidate]
    /// Non-nil when this repo has already been imported before.
    let existingRepository: ImportedSkillRepository?

    /// Repo-relative directories already synced from a previous import.
    var alreadySyncedDirectories: Set<String> {
        Set(existingRepository?.syncedSkillRelativePaths ?? [])
    }

    /// True when nothing has been imported from this clone yet — so an
    /// abandoned discovery clone can safely be deleted.
    var isFreshClone: Bool { existingRepository == nil }
}

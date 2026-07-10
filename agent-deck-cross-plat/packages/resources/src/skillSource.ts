/**
 * Parse a user's skill-repository input into a clone URL + optional ref + subdir
 * (native SkillRepositorySyncService.resolveSource). Pure, no I/O. Accepts an
 * `owner/repo` shorthand, a `skills.sh/<owner>/<repo>[/<slug>]` link, an SSH
 * remote, or a web tree URL (whose branch + path become the ref + subdir).
 */

export interface RemoteSkillSource {
  /** The https/ssh clone URL (`.git`-suffixed for GitHub shorthand). */
  cloneUrl: string;
  /** The branch to clone/track, when the input pinned one (a `/tree/<branch>`). */
  ref?: string;
  /** Limit discovery to this repo subdirectory (a web/skills.sh deep link). */
  subdir?: string;
}

// skills.sh first path segments that are site pages, not owners (native).
const SKILLS_SH_RESERVED = new Set(["docs", "topics", "agents", "leaderboard", "about", "search"]);
const SEGMENT = /^[A-Za-z0-9._-]+$/;

function stripGitSuffix(s: string): string {
  return s.replace(/\.git$/i, "");
}

/**
 * A repo subdirectory that's safe to join onto the clone path — no `..` traversal
 * and not absolute, so a crafted deep link can't scope discovery OUTSIDE the
 * clone. Returns undefined (import the whole repo) for an empty/unsafe value.
 */
function safeSubdir(raw: string | undefined): string | undefined {
  if (!raw) return undefined;
  const norm = raw.replace(/^\/+|\/+$/g, "");
  if (!norm || norm.startsWith("/") || norm.split("/").some((seg) => seg === ".."))
    return undefined;
  return norm;
}

/** `git@host:owner/repo(.git)` → `https://host/owner/repo.git`. */
function parseSshRemote(input: string): RemoteSkillSource | null {
  const match = /^git@([^:]+):(.+)$/.exec(input);
  if (!match) return null;
  const [, host, rest] = match;
  const path = stripGitSuffix(rest!).replace(/^\/+|\/+$/g, "");
  if (!path.includes("/")) return null;
  return { cloneUrl: `https://${host}/${path}.git` };
}

/** `[https://]host/owner/repo[/tree/<branch>/<path…>]` → clone URL (+ ref/subdir). */
function parseWebUrl(input: string): RemoteSkillSource | null {
  let url: URL;
  try {
    url = new URL(/^https?:\/\//i.test(input) ? input : `https://${input}`);
  } catch {
    return null;
  }
  const segments = url.pathname.split("/").filter(Boolean);
  if (segments.length < 2) return null;
  const [owner, repo, ...rest] = segments;
  const cloneUrl = `https://${url.host}/${owner}/${stripGitSuffix(repo!)}.git`;
  // GitHub `/tree/<branch>/<path…>` and GitLab `/-/tree/<branch>/<path…>`.
  const treeAt = rest[0] === "-" && rest[1] === "tree" ? 2 : rest[0] === "tree" ? 1 : -1;
  if (treeAt >= 0 && rest.length > treeAt) {
    const ref = rest[treeAt];
    const subdir = safeSubdir(rest.slice(treeAt + 1).join("/"));
    return { cloneUrl, ref, ...(subdir ? { subdir } : {}) };
  }
  return { cloneUrl };
}

/** `skills.sh/<owner>/<repo>[/<slug>]` → GitHub clone URL (+ the slug as subdir). */
function parseSkillsSh(input: string): RemoteSkillSource | null {
  const match = /^(?:https?:\/\/)?skills\.sh\/(.+)$/i.exec(input.trim());
  if (!match) return null;
  const segments = match[1]!.split("/").filter(Boolean);
  if (segments.length < 2) return null;
  const [owner, repo, slug] = segments;
  if (SKILLS_SH_RESERVED.has(owner!.toLowerCase())) return null;
  const subdir = safeSubdir(slug);
  return {
    cloneUrl: `https://github.com/${owner}/${stripGitSuffix(repo!)}.git`,
    ...(subdir ? { subdir } : {}),
  };
}

/** `owner/repo` (exactly two path segments) → GitHub clone URL. */
function parseShorthand(input: string): RemoteSkillSource | null {
  const segments = input.trim().split("/");
  if (segments.length !== 2) return null;
  const [owner, repo] = segments;
  if (!SEGMENT.test(owner!) || !SEGMENT.test(stripGitSuffix(repo!))) return null;
  return { cloneUrl: `https://github.com/${owner}/${stripGitSuffix(repo!)}.git` };
}

/** A local filesystem path or file:// URL — cloned verbatim (also the hermetic
 *  test form: `git clone <local-path>`). */
function isDirectSource(raw: string): boolean {
  return (
    raw.startsWith("/") ||
    raw.startsWith("./") ||
    raw.startsWith("../") ||
    raw.startsWith("~") ||
    raw.startsWith("file://") ||
    /^[A-Za-z]:[\\/]/.test(raw) // Windows drive path
  );
}

export function resolveSkillSource(input: string): RemoteSkillSource | null {
  const raw = input.trim();
  if (!raw) return null;
  if (isDirectSource(raw)) return { cloneUrl: raw };
  if (raw.startsWith("git@")) return parseSshRemote(raw);
  if (/^(?:https?:\/\/)?skills\.sh\//i.test(raw)) return parseSkillsSh(raw);
  // A dotted first segment (github.com/…) or an explicit scheme is a web URL.
  const firstSegment = raw.replace(/^https?:\/\//i, "").split("/")[0] ?? "";
  if (/^https?:\/\//i.test(raw) || firstSegment.includes(".")) return parseWebUrl(raw);
  return parseShorthand(raw);
}

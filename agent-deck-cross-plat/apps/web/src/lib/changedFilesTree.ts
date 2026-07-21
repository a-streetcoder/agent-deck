import type { DiffFileEntry } from "@agent-deck/contracts";

/**
 * Changed-file tree grouping (Slice 10), ported from t3code's
 * `apps/web/src/lib/turnDiffTree.ts` (MIT) and adapted to our wire entry
 * (`DiffFileEntry`: git status letter + nullable insertions/deletions where
 * the donor carried additions/deletions). The donor's shape survives intact:
 *   - files nest under directory nodes keyed by their path segments,
 *   - single-child directory chains compact into one "a/b/c" node,
 *   - directories aggregate their descendants' add/del stats,
 *   - directories sort before files, both name-sorted (numeric, base).
 */

export interface DiffStat {
  additions: number;
  deletions: number;
}

export interface DiffTreeDirectoryNode {
  kind: "directory";
  name: string;
  path: string;
  stat: DiffStat;
  children: DiffTreeNode[];
}

export interface DiffTreeFileNode {
  kind: "file";
  name: string;
  path: string;
  /** null for binary files (numstat reports no line counts). */
  stat: DiffStat | null;
  entry: DiffFileEntry;
}

export type DiffTreeNode = DiffTreeDirectoryNode | DiffTreeFileNode;

interface MutableDirectoryNode {
  name: string;
  path: string;
  stat: DiffStat;
  directories: Map<string, MutableDirectoryNode>;
  files: DiffTreeFileNode[];
}

const SORT_LOCALE_OPTIONS: Intl.CollatorOptions = { numeric: true, sensitivity: "base" };

function normalizePathSegments(pathValue: string): string[] {
  return pathValue
    .replaceAll("\\", "/")
    .split("/")
    .filter((segment) => segment.length > 0);
}

function compareByName(a: { name: string }, b: { name: string }): number {
  return a.name.localeCompare(b.name, undefined, SORT_LOCALE_OPTIONS);
}

function readStat(entry: DiffFileEntry): DiffStat | null {
  if (typeof entry.insertions !== "number" || typeof entry.deletions !== "number") {
    return null;
  }
  return { additions: entry.insertions, deletions: entry.deletions };
}

function compactDirectoryNode(node: DiffTreeDirectoryNode): DiffTreeDirectoryNode {
  const compactedChildren = node.children.map((child) =>
    child.kind === "directory" ? compactDirectoryNode(child) : child,
  );

  let compactedNode: DiffTreeDirectoryNode = { ...node, children: compactedChildren };

  while (compactedNode.children.length === 1 && compactedNode.children[0]?.kind === "directory") {
    const onlyChild = compactedNode.children[0];
    compactedNode = {
      kind: "directory",
      name: `${compactedNode.name}/${onlyChild.name}`,
      path: onlyChild.path,
      stat: onlyChild.stat,
      children: onlyChild.children,
    };
  }

  return compactedNode;
}

function toTreeNodes(directory: MutableDirectoryNode): DiffTreeNode[] {
  const subdirectories: DiffTreeDirectoryNode[] = Array.from(directory.directories.values())
    .toSorted(compareByName)
    .map<DiffTreeDirectoryNode>((subdirectory) => ({
      kind: "directory",
      name: subdirectory.name,
      path: subdirectory.path,
      stat: { additions: subdirectory.stat.additions, deletions: subdirectory.stat.deletions },
      children: toTreeNodes(subdirectory),
    }))
    .map((subdirectory) => compactDirectoryNode(subdirectory));

  const files = directory.files.toSorted(compareByName);
  return [...subdirectories, ...files];
}

/** Sum the per-file stats (binary files contribute nothing). */
export function summarizeDiffStats(files: readonly DiffFileEntry[]): DiffStat {
  return files.reduce<DiffStat>(
    (acc, file) => {
      const stat = readStat(file);
      if (!stat) return acc;
      return {
        additions: acc.additions + stat.additions,
        deletions: acc.deletions + stat.deletions,
      };
    },
    { additions: 0, deletions: 0 },
  );
}

/** Group a changed-file set into the donor's compacted directory tree. */
export function buildChangedFilesTree(files: readonly DiffFileEntry[]): DiffTreeNode[] {
  const root: MutableDirectoryNode = {
    name: "",
    path: "",
    stat: { additions: 0, deletions: 0 },
    directories: new Map(),
    files: [],
  };

  for (const file of files) {
    const segments = normalizePathSegments(file.path);
    if (segments.length === 0) continue;

    const filePath = segments.join("/");
    const fileName = segments.at(-1);
    if (!fileName) continue;
    const stat = readStat(file);
    const ancestors: MutableDirectoryNode[] = [root];
    let currentDirectory = root;

    for (const segment of segments.slice(0, -1)) {
      const nextPath = currentDirectory.path ? `${currentDirectory.path}/${segment}` : segment;
      const existing = currentDirectory.directories.get(segment);
      if (existing) {
        currentDirectory = existing;
      } else {
        const created: MutableDirectoryNode = {
          name: segment,
          path: nextPath,
          stat: { additions: 0, deletions: 0 },
          directories: new Map(),
          files: [],
        };
        currentDirectory.directories.set(segment, created);
        currentDirectory = created;
      }
      ancestors.push(currentDirectory);
    }

    currentDirectory.files.push({
      kind: "file",
      name: fileName,
      path: filePath,
      stat,
      entry: file,
    });

    if (stat) {
      for (const ancestor of ancestors) {
        ancestor.stat.additions += stat.additions;
        ancestor.stat.deletions += stat.deletions;
      }
    }
  }

  return toTreeNodes(root);
}

/** Every directory path in the tree, for expand/collapse-all bookkeeping. */
export function collectDirectoryPaths(nodes: readonly DiffTreeNode[]): string[] {
  const paths: string[] = [];
  for (const node of nodes) {
    if (node.kind !== "directory") continue;
    paths.push(node.path);
    paths.push(...collectDirectoryPaths(node.children));
  }
  return paths;
}

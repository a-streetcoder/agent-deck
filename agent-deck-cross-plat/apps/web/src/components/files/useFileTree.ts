import { useCallback, useEffect, useRef, useState } from "react";
import type { FileListEntry } from "@agent-deck/contracts";
import { useAppStore } from "../../state/store.ts";
import { fetchFileList } from "../../state/wsBridge.ts";

/**
 * The Files panel's lazy directory cache + expansion state (Slice 13b).
 *
 * Our server browses ONE directory per `file_list` op (unlike the donor's
 * whole-tree index behind `@pierre/trees`), so the tree loads lazily: the root
 * on connect, each subdirectory the first time it is expanded. This hook owns
 * that cache (keyed by repo-relative path, "" = the project root) and the
 * expanded-directory set; the {@link FileTree} renderer is a pure view over it.
 *
 * Freshness rules mirror the diff surface's:
 *   - a session switch fully resets (cache + expansion cleared, root reloaded) —
 *     the previous project's tree must never bleed into the new one;
 *   - a (re)connection reloads the root (an offline fetch rejected); cached
 *     subdirectory listings survive (files rarely move under a live session);
 *   - a stale fetch that resolves after a switch is dropped by a generation
 *     guard (the reset bumps the generation the in-flight fetch captured).
 */

export interface DirState {
  status: "loading" | "loaded" | "error";
  entries: readonly FileListEntry[];
  truncated: boolean;
  error?: string;
}

export interface FileTreeController {
  /** Directory listing state, keyed by relative path ("" = the project root). */
  readonly dirs: ReadonlyMap<string, DirState>;
  /** The currently-expanded directory paths. */
  readonly expanded: ReadonlySet<string>;
  /** Expand (lazy-loading on first open) or collapse one directory. */
  readonly toggleDir: (path: string) => void;
  /** Re-fetch the root and every currently-loaded directory (refresh button). */
  readonly reload: () => void;
}

export function useFileTree(sessionId: string | null): FileTreeController {
  const connection = useAppStore((state) => state.connection);
  const [dirs, setDirs] = useState<ReadonlyMap<string, DirState>>(new Map());
  const [expanded, setExpanded] = useState<ReadonlySet<string>>(new Set());
  // Bumped on every session change so a fetch started for the previous session
  // (captured its generation) is ignored when it finally resolves.
  const generationRef = useRef(0);
  // Live mirrors read inside stable callbacks without widening their deps.
  const dirsRef = useRef(dirs);
  const expandedRef = useRef(expanded);
  dirsRef.current = dirs;
  expandedRef.current = expanded;

  const loadDir = useCallback(
    (path: string): void => {
      if (sessionId === null) return;
      const myGeneration = generationRef.current;
      setDirs((prev) => {
        const next = new Map(prev);
        const existing = next.get(path);
        // Keep any prior entries visible while re-fetching (refresh/reconnect).
        next.set(path, {
          status: "loading",
          entries: existing?.entries ?? [],
          truncated: existing?.truncated ?? false,
        });
        return next;
      });
      void fetchFileList(path === "" ? undefined : path)
        .then((result) => {
          if (myGeneration !== generationRef.current || result === null) return;
          setDirs((prev) => {
            const next = new Map(prev);
            next.set(path, {
              status: "loaded",
              entries: result.entries,
              truncated: result.truncated,
            });
            return next;
          });
        })
        .catch((error: unknown) => {
          if (myGeneration !== generationRef.current) return;
          setDirs((prev) => {
            const next = new Map(prev);
            next.set(path, {
              status: "error",
              entries: [],
              truncated: false,
              error: error instanceof Error ? error.message : String(error),
            });
            return next;
          });
        });
    },
    [sessionId],
  );

  // Session switch: drop the previous project's tree entirely (and invalidate
  // any in-flight fetch). The load effect below then seeds the fresh root.
  useEffect(() => {
    generationRef.current += 1;
    setDirs(new Map());
    setExpanded(new Set());
  }, [sessionId]);

  // Seed (and, on reconnect, re-seed) the root once the socket is up. Cached
  // subdirectory listings are left intact across a reconnect; the root refresh
  // is enough to catch a tree that changed while the session was live.
  useEffect(() => {
    if (sessionId === null || connection !== "open") return;
    loadDir("");
  }, [sessionId, connection, loadDir]);

  const toggleDir = useCallback(
    (path: string): void => {
      // Decide open-vs-close from the ref, so the setExpanded updater stays
      // PURE — the lazy-load side-effect below must not live inside it, or
      // React StrictMode's dev-mode double-invoke would fire loadDir twice
      // (a redundant file_list round-trip on every first expand).
      const isOpen = expandedRef.current.has(path);
      setExpanded((prev) => {
        const next = new Set(prev);
        if (isOpen) next.delete(path);
        else next.add(path);
        return next;
      });
      // Lazy-load on first open (or retry after an error); an already-loaded
      // directory just re-reveals its cached rows.
      if (!isOpen) {
        const state = dirsRef.current.get(path);
        if (state === undefined || state.status === "error") loadDir(path);
      }
    },
    [loadDir],
  );

  const reload = useCallback((): void => {
    loadDir("");
    for (const path of expandedRef.current) loadDir(path);
  }, [loadDir]);

  return { dirs, expanded, toggleDir, reload };
}

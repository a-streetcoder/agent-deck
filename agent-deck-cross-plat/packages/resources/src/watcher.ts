import { mkdirSync } from "node:fs";
import { watch, type FSWatcher } from "chokidar";
import { watchDirs, type ResourceRoots } from "./paths.ts";

/** Chokidar cannot watch paths that don't exist yet — create them first. */
export function ensureDirs(dirs: string[]): string[] {
  for (const dir of dirs) {
    try {
      mkdirSync(dir, { recursive: true });
    } catch {
      // Non-writable location — the watcher will simply miss this dir.
    }
  }
  return dirs;
}

/**
 * Debounced resource watching. Coarse-grained by design: any change under a
 * resource directory triggers one callback; consumers re-scan (scans are
 * cheap: a handful of small markdown files).
 */
export function watchResources(
  roots: ResourceRoots,
  onChange: () => void,
  debounceMs = 250,
): FSWatcher {
  let timer: NodeJS.Timeout | null = null;
  const watcher = watch(ensureDirs(watchDirs(roots)), {
    ignoreInitial: true,
    awaitWriteFinish: { stabilityThreshold: 150, pollInterval: 50 },
  });
  watcher.on("all", () => {
    if (timer) clearTimeout(timer);
    timer = setTimeout(onChange, debounceMs);
  });
  return watcher;
}

import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

/**
 * Compare an ES module URL with Node's argv entry path.
 *
 * Comparing the strings directly fails on Windows when the checkout path has
 * spaces (`file://.../AI%20Playground` versus `C:\\...\\AI Playground`).
 */
export function isMainModule(
  moduleUrl: string,
  argvEntry: string | undefined,
  platform: NodeJS.Platform = process.platform,
): boolean {
  if (!argvEntry) return false;

  try {
    const modulePath = path.resolve(fileURLToPath(moduleUrl));
    const entryPath = path.resolve(argvEntry);
    return platform === "win32"
      ? modulePath.toLowerCase() === entryPath.toLowerCase()
      : modulePath === entryPath;
  } catch {
    return false;
  }
}

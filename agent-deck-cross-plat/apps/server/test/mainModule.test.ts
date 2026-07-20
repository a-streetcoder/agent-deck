import { mkdirSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { describe, expect, it } from "vitest";
import { isMainModule } from "../src/mainModule.ts";

describe("isMainModule", () => {
  it("matches a filesystem entry when its module URL contains escaped spaces", () => {
    const root = mkdtempSync(path.join(tmpdir(), "agent deck-main-"));
    const entry = path.join(root, "folder with spaces", "index.ts");
    mkdirSync(path.dirname(entry), { recursive: true });

    expect(isMainModule(pathToFileURL(entry).href, entry)).toBe(true);
    expect(isMainModule(pathToFileURL(entry).href, path.join(root, "other.ts"))).toBe(false);
  });

  it("does not treat an import without an argv entry as the main module", () => {
    expect(isMainModule(import.meta.url, undefined)).toBe(false);
  });
});

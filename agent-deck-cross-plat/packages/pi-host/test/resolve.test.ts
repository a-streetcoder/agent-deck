import { chmodSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { PiNotFoundError, resolvePiBinary } from "../src/resolve.ts";

function makeFakePi(dir: string): string {
  const name = process.platform === "win32" ? "pi.cmd" : "pi";
  const file = path.join(dir, name);
  writeFileSync(file, process.platform === "win32" ? "@echo off\n" : "#!/bin/sh\n");
  if (process.platform !== "win32") chmodSync(file, 0o755);
  return file;
}

describe("resolvePiBinary", () => {
  it("honors AGENT_DECK_PI_PATH when the file exists", () => {
    const dir = mkdtempSync(path.join(tmpdir(), "pi-resolve-"));
    const fake = makeFakePi(dir);
    const resolved = resolvePiBinary({ AGENT_DECK_PI_PATH: fake, PATH: "" });
    expect(resolved).toEqual({ path: fake, source: "env" });
  });

  it("fails loudly when an env override points at a missing file", () => {
    expect(() =>
      resolvePiBinary({ AGENT_DECK_PI_PATH: "/nope/definitely/missing/pi", PATH: "" }),
    ).toThrow(PiNotFoundError);
  });

  it("finds pi on PATH", () => {
    const dir = mkdtempSync(path.join(tmpdir(), "pi-resolve-"));
    const fake = makeFakePi(dir);
    const resolved = resolvePiBinary({ PATH: dir });
    expect(resolved).toEqual({ path: fake, source: "path" });
  });

  it("returns an absolute path even when the PATH entry is relative", () => {
    // pnpm puts a relative "node_modules/.bin" on PATH; the resolved binary is
    // later spawned with an arbitrary cwd, so a relative result would ENOENT.
    const dir = mkdtempSync(path.join(tmpdir(), "pi-resolve-"));
    const fake = makeFakePi(dir);
    const relDir = path.relative(process.cwd(), dir);
    const resolved = resolvePiBinary({ PATH: relDir });
    expect(path.isAbsolute(resolved.path)).toBe(true);
    expect(resolved).toEqual({ path: fake, source: "path" });
  });

  it("prefers the env override over PATH", () => {
    const overrideDir = mkdtempSync(path.join(tmpdir(), "pi-resolve-"));
    const pathDir = mkdtempSync(path.join(tmpdir(), "pi-resolve-"));
    const override = makeFakePi(overrideDir);
    makeFakePi(pathDir);
    const resolved = resolvePiBinary({ AGENT_DECK_PI_PATH: override, PATH: pathDir });
    expect(resolved).toEqual({ path: override, source: "env" });
  });
});

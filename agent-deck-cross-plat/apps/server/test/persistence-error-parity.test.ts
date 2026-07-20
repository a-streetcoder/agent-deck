import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { Runtime } from "effect";
import { describe, expect, it } from "vitest";
import { SessionIndex, SettingsStore } from "../src/persistence.ts";

/**
 * Slice 6 facade contract: a filesystem error thrown while opening a store or
 * flushing a write must surface as the ORIGINAL fs `Error` the legacy class
 * threw (an `instanceof Error` carrying an `err.code`), NOT Effect's opaque
 * FiberFailure wrapper. The facade routes every fallible construct/write through
 * `runSyncUnwrapped`, mirroring the sibling `pushBus.ts` facade. Fastify's error
 * path and any `err.code === "ENOSPC"`-style branch depend on that identity.
 */

/** Assert a thrown value kept its raw fs-Error identity (no FiberFailure wrap). */
function expectRawFsError(fn: () => void): void {
  let thrown: unknown;
  try {
    fn();
  } catch (error) {
    thrown = error;
  }
  expect(thrown).toBeInstanceOf(Error);
  expect(Runtime.isFiberFailure(thrown)).toBe(false);
  expect(typeof (thrown as NodeJS.ErrnoException).code).toBe("string");
}

describe("persistence facade — fs errors keep their legacy identity", () => {
  it("a construct-time mkdir failure surfaces the raw fs Error, not a FiberFailure", () => {
    // A data dir whose parent component is a regular file: mkdirSync throws
    // (ENOTDIR/EEXIST) synchronously inside the store's `make*` effect.
    const file = path.join(mkdtempSync(path.join(tmpdir(), "persist-err-")), "not-a-dir");
    writeFileSync(file, "x");
    expectRawFsError(() => new SessionIndex(path.join(file, "sub")));
  });

  it("a flush failure surfaces the raw fs Error, not a FiberFailure", () => {
    const dir = mkdtempSync(path.join(tmpdir(), "persist-err-"));
    const store = new SettingsStore(dir);
    // Remove the data dir out from under the store: the next flush's
    // writeFileSync(tmp) throws ENOENT out of the mutator's Effect.sync body.
    rmSync(dir, { recursive: true, force: true });
    expectRawFsError(() => store.setDefaultSkill("x", true));
  });
});

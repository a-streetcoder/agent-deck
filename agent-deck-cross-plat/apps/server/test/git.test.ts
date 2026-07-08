import { describe, expect, it } from "vitest";
import { parseStatus } from "../src/git.ts";

describe("git porcelain parsing", () => {
  it("parses the branch and file changes", () => {
    const out = parseStatus(
      "## main...origin/main [ahead 1]\n M src/a.ts\n?? new file.ts\nA  added.ts\n",
    );
    expect(out.branch).toBe("main");
    expect(out.files).toEqual([
      { status: " M", path: "src/a.ts" },
      { status: "??", path: "new file.ts" }, // a path with a space survives verbatim
      { status: "A ", path: "added.ts" },
    ]);
  });

  it("handles a bare branch with no upstream", () => {
    expect(parseStatus("## feature-x\n").branch).toBe("feature-x");
  });

  it("handles a fresh repo with no commits yet", () => {
    expect(parseStatus("## No commits yet on main\n?? README.md\n").branch).toBe("main");
  });

  it("reports no branch for a detached HEAD", () => {
    const out = parseStatus("## HEAD (no branch)\n M src/a.ts\n");
    expect(out.branch).toBeUndefined();
    expect(out.files).toEqual([{ status: " M", path: "src/a.ts" }]);
  });

  it("a clean tree yields no files", () => {
    const out = parseStatus("## main...origin/main\n");
    expect(out.files).toEqual([]);
  });
});

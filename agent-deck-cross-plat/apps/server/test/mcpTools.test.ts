import { describe, expect, it } from "vitest";
import { mcpServerConfigsFromEnv } from "../src/mcpTools.ts";

describe("mcpServerConfigsFromEnv", () => {
  it("parses a JSON array of stdio server configs", () => {
    const configs = mcpServerConfigsFromEnv(
      JSON.stringify([
        { id: "a", command: "node", args: ["a.js"] },
        { id: "b", command: "uvx", args: ["some-mcp"] },
      ]),
    );
    expect(configs).toHaveLength(2);
    expect(configs[0]).toMatchObject({ id: "a", command: "node" });
  });

  it("drops entries missing id or command, and non-objects", () => {
    const configs = mcpServerConfigsFromEnv(
      JSON.stringify([
        { id: "ok", command: "node" },
        { id: "no-command" },
        { command: "no-id" },
        "garbage",
        null,
      ]),
    );
    expect(configs.map((c) => c.id)).toEqual(["ok"]);
  });

  it("returns [] for empty, malformed, or non-array input", () => {
    expect(mcpServerConfigsFromEnv(undefined)).toEqual([]);
    expect(mcpServerConfigsFromEnv("")).toEqual([]);
    expect(mcpServerConfigsFromEnv("not json")).toEqual([]);
    expect(mcpServerConfigsFromEnv(JSON.stringify({ not: "an array" }))).toEqual([]);
  });
});

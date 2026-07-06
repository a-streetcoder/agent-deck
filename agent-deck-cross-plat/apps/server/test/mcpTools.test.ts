import { describe, expect, it } from "vitest";
import { mcpServerConfigsFromEnv, scopeMcpBridgeSpecs } from "../src/mcpTools.ts";

describe("scopeMcpBridgeSpecs", () => {
  const specs = [
    { name: "agent_deck_memory_write" },
    { name: "managed_subagent" },
    { name: "mcp__github__create_issue" },
    { name: "mcp__linear__list" },
  ];

  it("keeps non-MCP tools and only the allowed servers' MCP tools", () => {
    const scoped = scopeMcpBridgeSpecs(specs, ["github"]).map((s) => s.name);
    expect(scoped).toEqual([
      "agent_deck_memory_write",
      "managed_subagent",
      "mcp__github__create_issue",
    ]);
  });

  it("drops ALL MCP tools for an empty allowlist (agent declares none)", () => {
    expect(scopeMcpBridgeSpecs(specs, []).map((s) => s.name)).toEqual([
      "agent_deck_memory_write",
      "managed_subagent",
    ]);
  });

  it("matches a server id by its sanitized bridge prefix, not a substring", () => {
    // "git" must NOT match the "github" server (prefix is mcp__git__, not a substring).
    expect(scopeMcpBridgeSpecs(specs, ["git"]).some((s) => s.name.startsWith("mcp__"))).toBe(false);
    // A server id with an unsafe char is sanitized the same way the tool name is.
    const withDot = [{ name: "mcp__my_server__x" }];
    expect(scopeMcpBridgeSpecs(withDot, ["my.server"]).map((s) => s.name)).toEqual([
      "mcp__my_server__x",
    ]);
  });
});

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

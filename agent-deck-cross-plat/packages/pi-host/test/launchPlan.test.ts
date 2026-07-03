import { describe, expect, it } from "vitest";
import { buildLaunchArgs, type LaunchPlan } from "../src/launchPlan.ts";

const REQUIRED_ISOLATION_FLAGS = [
  "--no-extensions",
  "--no-skills",
  "--no-prompt-templates",
  "--no-themes",
];

const SAMPLE_PLANS: LaunchPlan[] = [
  { kind: "parent" },
  {
    kind: "parent",
    extensions: ["/ext/ask-user.ts", "/ext/web.ts"],
    appendSystemPrompts: ["/proj/.pi/APPEND_SYSTEM.md", "subagent catalog"],
    skills: ["/skills/a", "/skills/b"],
    promptTemplates: ["/prompts/p.md"],
    resumeSessionPath: "/sessions/s.jsonl",
    provider: "anthropic",
    model: "claude-sonnet-5",
    thinking: "medium",
  },
  {
    kind: "agent",
    systemPrompt: { mode: "replace", text: "You are the reviewer." },
    tools: ["read", "grep"],
    skills: ["/skills/review"],
    sessionDir: "/runs/r1/sessions",
    model: "claude-sonnet-5:low",
  },
  {
    kind: "agent",
    systemPrompt: { mode: "append", text: "Extra guidance." },
    tools: [],
    resumeSessionPath: "/runs/r1/sessions/child.jsonl",
  },
  { kind: "helper", systemPrompt: "Generate a title.", provider: "anthropic", model: "m" },
];

describe("buildLaunchArgs invariants (every plan shape)", () => {
  it.each(SAMPLE_PLANS.map((plan) => [plan.kind, plan] as const))(
    "%s plan starts with --mode rpc and carries all four isolation flags",
    (_kind, plan) => {
      const args = buildLaunchArgs(plan);
      expect(args.slice(0, 2)).toEqual(["--mode", "rpc"]);
      for (const flag of REQUIRED_ISOLATION_FLAGS) {
        expect(args).toContain(flag);
      }
    },
  );

  it("never emits an undefined or empty flag value (except the deliberate empty append)", () => {
    for (const plan of SAMPLE_PLANS) {
      const args = buildLaunchArgs(plan);
      args.forEach((arg, i) => {
        expect(arg).toBeTypeOf("string");
        if (arg === "" && args[i - 1] === "--append-system-prompt") return;
        expect(arg.length).toBeGreaterThan(0);
      });
    }
  });
});

describe("parent plan", () => {
  it("re-enables only explicitly assigned resources, in contract order", () => {
    const args = buildLaunchArgs(SAMPLE_PLANS[1]!);
    expect(args).toEqual([
      "--mode",
      "rpc",
      "--no-extensions",
      "--no-skills",
      "--no-prompt-templates",
      "--no-themes",
      "--extension",
      "/ext/ask-user.ts",
      "--extension",
      "/ext/web.ts",
      "--append-system-prompt",
      "/proj/.pi/APPEND_SYSTEM.md",
      "--append-system-prompt",
      "subagent catalog",
      "--skill",
      "/skills/a",
      "--skill",
      "/skills/b",
      "--prompt-template",
      "/prompts/p.md",
      "--session",
      "/sessions/s.jsonl",
      "--provider",
      "anthropic",
      "--model",
      "claude-sonnet-5",
      "--thinking",
      "medium",
    ]);
  });

  it("bare parent plan is just the base invariant", () => {
    expect(buildLaunchArgs({ kind: "parent" })).toEqual([
      "--mode",
      "rpc",
      "--no-extensions",
      "--no-skills",
      "--no-prompt-templates",
      "--no-themes",
    ]);
  });
});

describe("agent plan", () => {
  it("replace mode injects --system-prompt and suppresses APPEND_SYSTEM.md", () => {
    const args = buildLaunchArgs(SAMPLE_PLANS[2]!);
    expect(args).toContain("--system-prompt");
    const appendIndex = args.indexOf("--append-system-prompt");
    expect(args[appendIndex + 1]).toBe("");
    expect(args).toContain("--tools");
    expect(args[args.indexOf("--tools") + 1]).toBe("read,grep");
    expect(args[args.indexOf("--session-dir") + 1]).toBe("/runs/r1/sessions");
  });

  it("append mode uses --append-system-prompt with the prompt text", () => {
    const args = buildLaunchArgs(SAMPLE_PLANS[3]!);
    expect(args).not.toContain("--system-prompt");
    expect(args[args.indexOf("--append-system-prompt") + 1]).toBe("Extra guidance.");
  });

  it("empty tools list becomes --no-tools; undefined leaves pi defaults", () => {
    const withEmpty = buildLaunchArgs(SAMPLE_PLANS[3]!);
    expect(withEmpty).toContain("--no-tools");
    const withDefault = buildLaunchArgs({
      kind: "agent",
      systemPrompt: { mode: "replace", text: "x" },
    });
    expect(withDefault).not.toContain("--no-tools");
    expect(withDefault).not.toContain("--tools");
  });

  it("rejects sessionDir combined with resumeSessionPath", () => {
    expect(() =>
      buildLaunchArgs({
        kind: "agent",
        systemPrompt: { mode: "replace", text: "x" },
        sessionDir: "/a",
        resumeSessionPath: "/b",
      }),
    ).toThrow(/exclusive/);
  });
});

describe("helper plan", () => {
  it("is fully isolated and forces :off thinking on the model", () => {
    const args = buildLaunchArgs(SAMPLE_PLANS[4]!);
    for (const flag of ["--no-session", "--no-tools", "--no-context-files"]) {
      expect(args).toContain(flag);
    }
    expect(args[args.indexOf("--model") + 1]).toBe("m:off");
    expect(args[args.indexOf("--append-system-prompt") + 1]).toBe("");
  });

  it("keeps an explicit thinking suffix untouched", () => {
    const args = buildLaunchArgs({ kind: "helper", systemPrompt: "t", model: "m:low" });
    expect(args[args.indexOf("--model") + 1]).toBe("m:low");
  });
});

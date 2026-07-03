/**
 * Typed launch plans for the three M1 pi subprocess shapes, mirroring the native
 * app's four production launch paths (commit helper arrives with ship support).
 *
 * Contract source: agent-deck-documentation/pi-rpc-launch-flags.md.
 *
 * Invariant (structurally unskippable): every launch starts with
 *   --mode rpc --no-extensions --no-skills --no-prompt-templates --no-themes
 * and re-enables ONLY explicitly assigned resources.
 */

export type ThinkingLevel = "off" | "minimal" | "low" | "medium" | "high" | "xhigh";

export interface ModelSelection {
  provider?: string;
  /** pi `--model` pattern; may already carry a `:<thinking>` suffix. */
  model?: string;
}

/** Main chat session: normal pi runtime, explicit Agent Deck resources only. */
export interface ParentSessionPlan extends ModelSelection {
  kind: "parent";
  /** Resume an existing pi session file. */
  resumeSessionPath?: string;
  /** Bridge + command extension sources, in load order. */
  extensions?: string[];
  /**
   * Explicit --append-system-prompt values, in order. Callers must FIRST preserve
   * the active APPEND_SYSTEM.md (project, else global) because any explicit value
   * suppresses pi's automatic discovery.
   */
  appendSystemPrompts?: string[];
  /** Default + current-project skill assignment paths. */
  skills?: string[];
  /** Default + current-project prompt template paths. */
  promptTemplates?: string[];
  thinking?: ThinkingLevel;
}

/** Agent-backed session (M1 core) / native subagent child: injected system prompt. */
export interface AgentSessionPlan extends ModelSelection {
  kind: "agent";
  systemPrompt: { mode: "replace" | "append"; text: string };
  /**
   * Tool policy: undefined → pi defaults; non-empty → --tools allowlist;
   * empty array → --no-tools.
   */
  tools?: string[];
  extensions?: string[];
  skills?: string[];
  /** Fresh child runs store session files under this directory. */
  sessionDir?: string;
  /** Continue a prior child session. */
  resumeSessionPath?: string;
}

/** Isolated one-shot helper (titles, commit messages): no session, no resources. */
export interface HelperPlan extends ModelSelection {
  kind: "helper";
  systemPrompt: string;
}

export type LaunchPlan = ParentSessionPlan | AgentSessionPlan | HelperPlan;

const BASE_ARGS = [
  "--mode",
  "rpc",
  "--no-extensions",
  "--no-skills",
  "--no-prompt-templates",
  "--no-themes",
] as const;

function repeated(flag: string, values: readonly string[] | undefined): string[] {
  return (values ?? []).flatMap((value) => [flag, value]);
}

/** Force `:off` thinking on helper models unless the pattern already has a suffix. */
function helperModelPattern(model: string): string {
  return model.includes(":") ? model : `${model}:off`;
}

export function buildLaunchArgs(plan: LaunchPlan): string[] {
  const args: string[] = [...BASE_ARGS];

  switch (plan.kind) {
    case "parent": {
      args.push(...repeated("--extension", plan.extensions));
      args.push(...repeated("--append-system-prompt", plan.appendSystemPrompts));
      args.push(...repeated("--skill", plan.skills));
      args.push(...repeated("--prompt-template", plan.promptTemplates));
      if (plan.resumeSessionPath) args.push("--session", plan.resumeSessionPath);
      if (plan.provider) args.push("--provider", plan.provider);
      if (plan.model) args.push("--model", plan.model);
      if (plan.thinking) args.push("--thinking", plan.thinking);
      break;
    }
    case "agent": {
      if (plan.sessionDir && plan.resumeSessionPath) {
        throw new Error("AgentSessionPlan: sessionDir and resumeSessionPath are exclusive");
      }
      if (plan.sessionDir) args.push("--session-dir", plan.sessionDir);
      if (plan.resumeSessionPath) args.push("--session", plan.resumeSessionPath);
      if (plan.systemPrompt.mode === "replace") {
        args.push("--system-prompt", plan.systemPrompt.text);
        // Suppress pi's automatic APPEND_SYSTEM.md discovery for replaced prompts.
        args.push("--append-system-prompt", "");
      } else {
        args.push("--append-system-prompt", plan.systemPrompt.text);
      }
      if (plan.tools !== undefined) {
        if (plan.tools.length > 0) args.push("--tools", plan.tools.join(","));
        else args.push("--no-tools");
      }
      args.push(...repeated("--extension", plan.extensions));
      args.push(...repeated("--skill", plan.skills));
      if (plan.provider) args.push("--provider", plan.provider);
      if (plan.model) args.push("--model", plan.model);
      break;
    }
    case "helper": {
      args.push("--no-session", "--no-tools", "--no-context-files");
      args.push("--system-prompt", plan.systemPrompt);
      args.push("--append-system-prompt", "");
      if (plan.provider) args.push("--provider", plan.provider);
      if (plan.model) args.push("--model", helperModelPattern(plan.model));
      break;
    }
  }

  return args;
}

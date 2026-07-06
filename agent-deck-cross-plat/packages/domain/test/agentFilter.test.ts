import { describe, expect, it } from "vitest";
import { AGENT_FILTERS, agentMatchesFilter, type AgentInfo } from "../src/resources.ts";

/**
 * The Agents screen scope/filter chips (native SidebarModels): pure predicates
 * shared by server and UI. This pins the "overridden" chip — a builtin whose
 * values are partly redefined by a settings.json override — alongside the
 * neighbouring "replaced"/"custom"/"disabled" ones it is easy to confuse with.
 */

function agent(overrides: Partial<AgentInfo>): AgentInfo {
  return {
    name: "coder",
    systemPromptMode: "replace",
    scope: "builtin",
    filePath: "/x/coder.md",
    body: "",
    shadowed: false,
    replacesBuiltin: false,
    ...overrides,
  };
}

describe("agentMatchesFilter", () => {
  it("'overridden' matches only a builtin carrying a settings.json override", () => {
    const overridden = agent({ scope: "builtin", overridden: true });
    const pristine = agent({ scope: "builtin" });
    const projectAgent = agent({ name: "mine", scope: "project" });

    expect(agentMatchesFilter(overridden, "overridden")).toBe(true);
    expect(agentMatchesFilter(pristine, "overridden")).toBe(false);
    // A project agent redefining a builtin is "replaced"/"custom", not "overridden".
    expect(agentMatchesFilter(projectAgent, "overridden")).toBe(false);
  });

  it("keeps 'overridden' distinct from 'replaced' and 'custom'", () => {
    // An overridden builtin is still a builtin: not custom, not (by itself) replaced.
    const overridden = agent({ scope: "builtin", overridden: true });
    expect(agentMatchesFilter(overridden, "custom")).toBe(false);
    expect(agentMatchesFilter(overridden, "replaced")).toBe(false);

    // A project agent that shadows a builtin is replaced + custom, not overridden.
    const replacer = agent({ name: "coder", scope: "project", replacesBuiltin: true });
    expect(agentMatchesFilter(replacer, "replaced")).toBe(true);
    expect(agentMatchesFilter(replacer, "custom")).toBe(true);
    expect(agentMatchesFilter(replacer, "overridden")).toBe(false);
  });

  it("'all' matches everything; scope chips match their own scope", () => {
    const g = agent({ scope: "global" });
    expect(agentMatchesFilter(g, "all")).toBe(true);
    expect(agentMatchesFilter(g, "global")).toBe(true);
    expect(agentMatchesFilter(g, "project")).toBe(false);
    expect(agentMatchesFilter(agent({ disabled: true }), "disabled")).toBe(true);
  });

  it("every declared filter is covered by the predicate (no missing case)", () => {
    const sample = agent({ overridden: true, disabled: true, replacesBuiltin: true });
    for (const f of AGENT_FILTERS) {
      expect(() => agentMatchesFilter(sample, f)).not.toThrow();
    }
  });
});

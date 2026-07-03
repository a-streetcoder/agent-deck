import type { ResourceScope } from "@agent-deck/domain";

const SCOPE_COLOR: Record<ResourceScope, string> = {
  builtin: "var(--color-source-builtin)",
  library: "var(--color-source-library)",
  project: "var(--color-source-project)",
  global: "var(--color-brand-accent)",
};

export function ScopeChip({ scope }: { scope: ResourceScope }) {
  return (
    <span
      className="rounded-capsule px-2 py-0.5 text-xs font-medium"
      style={{
        color: SCOPE_COLOR[scope],
        border: `1px solid ${SCOPE_COLOR[scope]}`,
      }}
      data-testid="scope-chip"
      data-scope={scope}
    >
      {scope}
    </span>
  );
}

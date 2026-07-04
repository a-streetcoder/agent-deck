import { Send } from "lucide-react";
import type { AgentInfo, ResourceScope } from "@agent-deck/domain";

/**
 * Native AgentAvatarView: a circle tinted by source kind (10% fill / 18%
 * stroke) with a paperplane fallback glyph. Source tints per DesignSystem:
 * builtin orange, library purple, project green, global brand accent.
 */
const SOURCE_TINT: Record<ResourceScope, string> = {
  builtin: "var(--color-source-builtin)",
  library: "var(--color-source-library)",
  project: "var(--color-source-project)",
  global: "var(--color-brand-accent)",
};

export function agentSourceColor(agent: Pick<AgentInfo, "scope">): string {
  return SOURCE_TINT[agent.scope];
}

export function AgentAvatar({
  agent,
  size = 40,
}: {
  agent: Pick<AgentInfo, "scope" | "name">;
  size?: number;
}) {
  const tint = agentSourceColor(agent);
  return (
    <span
      className="flex shrink-0 items-center justify-center rounded-full"
      style={{
        width: size,
        height: size,
        background: `color-mix(in srgb, ${tint} 10%, transparent)`,
        border: `1px solid color-mix(in srgb, ${tint} 18%, transparent)`,
        color: tint,
      }}
      aria-hidden
    >
      <Send size={Math.round(size * 0.42)} />
    </span>
  );
}

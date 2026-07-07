// Thinking-level model: the ladder pi exposes and how a model's reasoning
// capability restricts it. pi's ThinkingLevel union is "off" | "minimal" |
// "low" | "medium" | "high" | "xhigh" (pi-agent-core 0.80.3).

export const THINKING_LEVELS = ["off", "minimal", "low", "medium", "high", "xhigh"] as const;
export type ThinkingLevel = (typeof THINKING_LEVELS)[number];

/**
 * The thinking levels a model can actually use.
 *
 * pi's RPC `ModelInfo` exposes only `reasoning: boolean` (no per-model level
 * list), so this mirrors native's own fallback (PiAgentViews.swift:7001,
 * `supportsThinking ? … : ["off"]`): a model that can't reason offers only
 * "off"; a reasoning model offers the full ladder. `reasoning` is gated strictly
 * on `false` so an unknown/still-loading model defaults to the full ladder (no
 * flash to "off" before the catalog resolves).
 */
export function thinkingLevelsForModel(reasoning: boolean | undefined): ThinkingLevel[] {
  return reasoning === false ? ["off"] : [...THINKING_LEVELS];
}

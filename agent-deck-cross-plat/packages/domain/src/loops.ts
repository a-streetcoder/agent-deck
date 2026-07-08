/**
 * Loop definitions (native LoopModels.swift LoopDefinition + LoopDefinitionStore):
 * a saved template that repeats an agent run up to `maxIterations` until a
 * validation command succeeds. This is the DEFINITION model + Bank library; the
 * run engine (LoopRun / iterations / worktrees / validation execution) is a
 * later slice. Persisted one-file-per-loop under ~/.pi/agent/loops as `.loop.md`
 * (frontmatter + the goal as the markdown body), mirroring the agent catalog.
 */

/** The per-iteration orchestration shape (native LoopStructureKind). */
export type LoopStructure =
  | "singleAgent"
  | "makerChecker"
  | "agentPipeline"
  | "parallelAgents"
  | "discoveryTriage"
  | "humanApproval";

export const LOOP_STRUCTURES: LoopStructure[] = [
  "singleAgent",
  "makerChecker",
  "agentPipeline",
  "parallelAgents",
  "discoveryTriage",
  "humanApproval",
];

export const LOOP_STRUCTURE_LABEL: Record<LoopStructure, string> = {
  singleAgent: "Single agent",
  makerChecker: "Maker / checker",
  agentPipeline: "Agent pipeline",
  parallelAgents: "Parallel agents",
  discoveryTriage: "Discovery + triage",
  humanApproval: "Human approval",
};

/** Where an iteration writes its work (native LoopWriteTarget). */
export type LoopWriteTarget = "artifactMarkdown" | "newWorktree" | "currentCheckout";

export const LOOP_WRITE_TARGETS: LoopWriteTarget[] = [
  "artifactMarkdown",
  "newWorktree",
  "currentCheckout",
];

export const LOOP_WRITE_TARGET_LABEL: Record<LoopWriteTarget, string> = {
  artifactMarkdown: "Artifact (markdown)",
  newWorktree: "New worktree",
  currentCheckout: "Current checkout",
};

/** `user` loops are editable; `builtin` loops are read-only (duplicate to edit). */
export type LoopSource = "user" | "builtin";

export const LOOP_MAX_ITERATIONS_LIMIT = 20;
export const LOOP_DEFAULT_MAX_ITERATIONS = 3;

export interface LoopDefinition {
  /** Stable id — the file path for on-disk loops. */
  id: string;
  name: string;
  description: string;
  /** The goal / prompt template (stored as the markdown body). */
  goal: string;
  structure: LoopStructure;
  /** The primary agent this loop drives (native single-agent = makerName). */
  agentName?: string;
  /** 1..LOOP_MAX_ITERATIONS_LIMIT; the fixed iteration cap. */
  maxIterations: number;
  /** Shell command whose exit 0 stops the loop early (the success condition). */
  validationCommand: string;
  writeTarget: LoopWriteTarget;
  source: LoopSource;
  filePath: string;
}

/** Clamp a requested iteration count into the native 1..limit range. */
export function clampMaxIterations(value: number): number {
  if (!Number.isFinite(value)) return LOOP_DEFAULT_MAX_ITERATIONS;
  return Math.min(LOOP_MAX_ITERATIONS_LIMIT, Math.max(1, Math.floor(value)));
}

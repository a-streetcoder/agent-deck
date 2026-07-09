import type { ProjectMeta } from "@agent-deck/domain";

/**
 * A session's shown title: pi's generated title once it exists, otherwise a
 * native-style "Draft · <project>" placeholder for an untitled draft.
 */
export function sessionDisplayTitle(title: string | undefined, projectName: string): string {
  const trimmed = title?.trim();
  return trimmed ? trimmed : `Draft · ${projectName}`;
}

/**
 * Resolve a session's project name consistently everywhere (picker + header):
 * no project id → "All Projects" (native's aggregate/no-folder selection); a
 * dangling id (project since removed) → "Unknown project"; otherwise the name.
 */
export function projectDisplayName(projects: ProjectMeta[], projectId: string | undefined): string {
  if (!projectId) return "All Projects";
  return projects.find((p) => p.id === projectId)?.name ?? "Unknown project";
}

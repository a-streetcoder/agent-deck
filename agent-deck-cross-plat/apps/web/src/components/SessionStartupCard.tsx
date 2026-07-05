import { Folder, WandSparkles } from "lucide-react";
import { useAppStore } from "../state/store.ts";

/**
 * Pre-launch surface shown in an empty session (native PiAgentStartupViews):
 * instead of a blank transcript, preview what this draft will run with — the
 * agent, the project cwd, and the skills assigned to that project. The
 * interactive launch controls (model / thinking / agent) live in the composer
 * below.
 */
export function SessionStartupCard() {
  const currentAgentName = useAppStore((state) => state.currentAgentName);
  const currentProjectId = useAppStore((state) => state.currentProjectId);
  const projects = useAppStore((state) => state.projects);
  const session = useAppStore((state) => state.session);

  const project = projects.find((p) => p.id === currentProjectId) ?? null;
  const agentName = currentAgentName ?? session?.agentName ?? "Pi Agent";
  const projectName = project?.name ?? "Default";
  const skills = project?.assignedSkills ?? [];

  return (
    <div className="mx-auto mt-12 w-full max-w-md" data-testid="session-startup">
      <div className="rounded-2xl border border-border-subtle bg-surface-elevated p-5 shadow-card">
        <div
          className="text-[10px] font-semibold uppercase tracking-wider text-text-muted"
          style={{ fontStretch: "expanded" }}
        >
          New session
        </div>
        <h2
          className="mt-1 text-lg font-semibold text-text-primary"
          style={{ fontStretch: "expanded" }}
          data-testid="startup-agent"
        >
          {agentName}
        </h2>
        <p className="mt-1 text-sm text-text-muted">
          Send a message below to launch. It will run with:
        </p>

        <dl className="mt-4 space-y-3 text-sm">
          <div className="flex items-start justify-between gap-3">
            <dt className="flex items-center gap-1.5 text-text-muted">
              <Folder size={13} aria-hidden /> Project
            </dt>
            <dd className="min-w-0 text-right">
              <div className="truncate font-medium text-text-primary" style={{ fontStretch: "expanded" }}>
                {projectName}
              </div>
              {session?.cwd ? (
                <div className="truncate font-mono text-[11px] text-text-muted">{session.cwd}</div>
              ) : null}
            </dd>
          </div>

          <div className="flex items-start justify-between gap-3">
            <dt className="flex items-center gap-1.5 text-text-muted">
              <WandSparkles size={13} aria-hidden /> Skills
            </dt>
            <dd
              className="flex max-w-[70%] flex-wrap justify-end gap-1.5"
              data-testid="startup-skills"
            >
              {skills.length > 0 ? (
                skills.map((skill) => (
                  <span
                    key={skill}
                    className="rounded-capsule border border-border-subtle bg-surface px-2 py-0.5 text-xs text-text-secondary"
                  >
                    {skill}
                  </span>
                ))
              ) : (
                <span className="text-text-muted">None assigned</span>
              )}
            </dd>
          </div>
        </dl>
      </div>
    </div>
  );
}

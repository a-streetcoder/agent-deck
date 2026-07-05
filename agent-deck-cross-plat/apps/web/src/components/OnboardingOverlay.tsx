import { useState } from "react";
import { FolderPlus, Sparkles, X } from "lucide-react";
import { useAppStore } from "../state/store.ts";

/**
 * First-run welcome (native WelcomeOnboardingSheet, adapted to a non-blocking
 * banner). Shows while a new user has no projects and hasn't dismissed it,
 * pointing them at the first setup step. Auto-hides once a project exists. Kept
 * non-blocking so it never covers the composer or nav.
 */
const KEY = "agentdeck-onboarding-dismissed";

function wasDismissed(): boolean {
  try {
    return localStorage.getItem(KEY) === "1";
  } catch {
    return false;
  }
}

export function OnboardingOverlay() {
  const projects = useAppStore((state) => state.projects);
  const projectsLoaded = useAppStore((state) => state.projectsLoaded);
  const setView = useAppStore((state) => state.setView);
  const [dismissed, setDismissed] = useState(wasDismissed);

  // Wait for the initial fetch so a returning user never flashes the banner.
  if (!projectsLoaded || projects.length > 0 || dismissed) return null;

  const dismiss = (): void => {
    try {
      localStorage.setItem(KEY, "1");
    } catch {
      // Storage disabled — it just won't be remembered across reloads.
    }
    setDismissed(true);
  };

  return (
    <div
      className="flex items-center gap-3 border-b border-border-subtle bg-[var(--color-selection-fill)] px-6 py-2.5"
      data-testid="onboarding"
    >
      <Sparkles size={15} className="shrink-0 text-[var(--color-brand-accent)]" aria-hidden />
      <div className="min-w-0 flex-1">
        <span className="text-sm font-medium text-text-primary" style={{ fontStretch: "expanded" }}>
          Welcome to Agent Deck
        </span>
        <span className="ml-2 text-xs text-text-muted">
          Add a project — point it at a repo or folder — then pick an agent and start chatting.
        </span>
      </div>
      <button
        data-testid="onboarding-add-project"
        className="flex shrink-0 items-center gap-1.5 rounded-capsule px-3 py-1 text-xs font-medium shadow-capsule"
        style={{
          background:
            "linear-gradient(180deg, var(--color-brand-accent-bright), var(--color-brand-accent))",
          color: "var(--color-accent-foreground)",
        }}
        onClick={() => setView("projects")}
      >
        <FolderPlus size={13} aria-hidden /> Add a project
      </button>
      <button
        data-testid="onboarding-skip"
        className="shrink-0 rounded p-1 text-text-muted hover:text-text-primary"
        aria-label="Dismiss welcome"
        onClick={dismiss}
      >
        <X size={14} />
      </button>
    </div>
  );
}

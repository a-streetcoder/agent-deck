import { useState } from "react";
import { ArrowLeft, ArrowRight, FolderPlus, X } from "lucide-react";
import { cn } from "@/lib/cn";
import { useAppStore } from "../state/store.ts";

/**
 * First-run onboarding (native WelcomeOnboardingSheet): a paged illustrated flow
 * introducing Agent Deck, reusing the native app's own onboarding artwork
 * (public/onboarding/pop-onb-*). Shows while a new user has no projects and
 * hasn't dismissed it; the final page's CTA jumps to adding a project. The images
 * live under public/ so they load only when this overlay renders (first run).
 */
const KEY = "agentdeck-onboarding-dismissed";

interface Page {
  image: string;
  title: string;
  description: string;
}

// Copy ported from native OnboardingViews.swift (Mac-specific wording generalized).
const PAGES: Page[] = [
  {
    image: "/onboarding/pop-onb-1.jpg",
    title: "Command Pi from Agent Deck",
    description:
      "Run Pi coding sessions from a focused workspace with project context, models, repo activity, and session state in one place.",
  },
  {
    image: "/onboarding/pop-onb-2.png",
    title: "Work in a Coding Chat",
    description:
      "Use a customizable chat built for implementation work: full transcripts, tool calls, file previews, attachments, and live controls.",
  },
  {
    image: "/onboarding/pop-onb-3.png",
    title: "Orchestrate Deck Agents",
    description:
      "Delegate focused work to custom Deck agents, run them alone or in parallel, supervise decisions, and keep worktrees isolated.",
  },
  {
    image: "/onboarding/pop-onb-4.png",
    title: "Shape Your Agent System",
    description:
      "Create, organize, assign, and reuse agents, skills, and prompts so project workflows become clear, portable, and repeatable.",
  },
  {
    image: "/onboarding/pop-onb-5.png",
    title: "Manage Project Instructions",
    description:
      "Control system guidance, AGENTS.md, CLAUDE.md, and project-scoped instructions from one place instead of hunting through files.",
  },
  {
    image: "/onboarding/pop-onb-6.png",
    title: "Connect the Wider Workflow",
    description:
      "Bring in GitHub, project folders, environment keys, and model setup when you need them. Setup checks confirm the workspace is ready.",
  },
];

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
  const [page, setPage] = useState(0);

  // Wait for the initial fetch so a returning user never flashes the overlay.
  if (!projectsLoaded || projects.length > 0 || dismissed) return null;

  const dismiss = (): void => {
    try {
      localStorage.setItem(KEY, "1");
    } catch {
      // Storage disabled — it just won't be remembered across reloads.
    }
    setDismissed(true);
  };

  const current = PAGES[page]!;
  const isLast = page === PAGES.length - 1;

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-6"
      data-testid="onboarding"
      role="dialog"
      aria-modal="true"
      aria-label="Welcome to Agent Deck"
    >
      <div className="flex w-full max-w-md flex-col overflow-hidden rounded-2xl border border-border-strong bg-surface-elevated shadow-elevated">
        <div className="relative aspect-[4/3] w-full bg-surface-subtle">
          <img
            key={current.image}
            data-testid="onboarding-image"
            src={current.image}
            alt=""
            className="h-full w-full object-cover"
          />
          <button
            data-testid="onboarding-skip"
            className="absolute right-2 top-2 rounded-full bg-black/40 p-1 text-white/80 hover:text-white"
            aria-label="Skip"
            onClick={dismiss}
          >
            <X size={15} />
          </button>
        </div>

        <div className="flex flex-col gap-3 px-5 py-4">
          <h2
            data-testid="onboarding-title"
            className="text-base font-semibold text-text-primary"
            style={{ fontStretch: "expanded" }}
          >
            {current.title}
          </h2>
          <p className="text-sm leading-relaxed text-text-secondary">{current.description}</p>

          <div className="flex items-center gap-1.5 pt-1" aria-hidden>
            {PAGES.map((p, i) => (
              <span
                key={p.image}
                className={cn(
                  "h-1.5 rounded-full transition-all",
                  i === page ? "w-4 bg-[var(--color-brand-accent)]" : "w-1.5 bg-border-strong",
                )}
              />
            ))}
          </div>

          <div className="flex items-center justify-between pt-1">
            <button
              data-testid="onboarding-back"
              className={cn(
                "flex items-center gap-1 rounded-capsule px-2.5 py-1 text-xs text-text-secondary hover:text-text-primary",
                page === 0 && "invisible",
              )}
              onClick={() => setPage((p) => Math.max(0, p - 1))}
            >
              <ArrowLeft size={13} /> Back
            </button>

            {isLast ? (
              <button
                data-testid="onboarding-add-project"
                className="flex items-center gap-1.5 rounded-capsule px-3.5 py-1.5 text-xs font-medium shadow-capsule"
                style={{
                  background:
                    "linear-gradient(180deg, var(--color-brand-accent-bright), var(--color-brand-accent))",
                  color: "var(--color-accent-foreground)",
                }}
                onClick={() => {
                  dismiss();
                  setView("projects");
                }}
              >
                <FolderPlus size={13} aria-hidden /> Add a project
              </button>
            ) : (
              <button
                data-testid="onboarding-next"
                className="flex items-center gap-1.5 rounded-capsule px-3.5 py-1.5 text-xs font-medium shadow-capsule"
                style={{
                  background:
                    "linear-gradient(180deg, var(--color-brand-accent-bright), var(--color-brand-accent))",
                  color: "var(--color-accent-foreground)",
                }}
                onClick={() => setPage((p) => Math.min(PAGES.length - 1, p + 1))}
              >
                Continue <ArrowRight size={13} aria-hidden />
              </button>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}

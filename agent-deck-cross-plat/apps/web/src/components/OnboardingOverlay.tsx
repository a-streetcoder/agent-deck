import { useEffect, useRef, useState } from "react";
import {
  ArrowLeft,
  ArrowRight,
  Check,
  CheckCircle2,
  Copy,
  FolderPlus,
  RefreshCw,
  Rocket,
  ShieldCheck,
  SlidersHorizontal,
  Stethoscope,
  TriangleAlert,
  XCircle,
  X,
} from "lucide-react";
import { THINKING_LEVELS } from "@agent-deck/domain";
import { cn } from "@/lib/cn";
import { useAppStore, type AppView } from "../state/store.ts";

/**
 * First-run onboarding (native WelcomeOnboardingSheet): a phased flow, not just a
 * marketing slideshow. Native runs tour → Setup Check → Preferences → Final; this
 * builds tour → Setup Check → Final (Preferences is added separately). The Setup
 * Check is a real dependency doctor (the same /runtime/doctor the Doctor screen
 * uses) that flags what's missing with fixes, and the Final step smart-routes to
 * wherever setup still needs attention (native OnboardingFinalView.primaryTarget).
 * Reuses the native onboarding artwork (public/onboarding/pop-onb-*).
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

/**
 * Force the onboarding to show regardless of projects/dismissed state — a way to
 * replay it (the flow otherwise only appears on genuine first run). Triggered by
 * `?onboarding` in the URL or `localStorage['agentdeck-onboarding-force']='1'`
 * (set via devtools in the desktop app, where the URL is fixed).
 */
const FORCE_KEY = "agentdeck-onboarding-force";
function onboardingForced(): boolean {
  try {
    if (new URLSearchParams(window.location.search).has("onboarding")) return true;
    return localStorage.getItem(FORCE_KEY) === "1";
  } catch {
    return false;
  }
}

type Phase = "tour" | "setup" | "preferences" | "final";

interface HealthCheck {
  id: string;
  label: string;
  status: "ok" | "warn" | "error";
  detail: string;
  fixCommand?: string;
}

/** The onboarding-preferences slice of AppSettings (native OnboardingPreferences). */
interface Prefs {
  autoTitle: boolean;
  worktreeIsolation: boolean;
  gitAutomation: boolean;
  defaultModel: string | null;
  defaultThinking: string | null;
}

interface CatalogModel {
  provider: string;
  id: string;
  name?: string;
}

// Native SetupCheckStatus mapping: ok → Ready, warn → Optional, error → Missing.
const STATUS_META = {
  ok: { label: "Ready", Icon: CheckCircle2, color: "var(--color-success)" },
  warn: { label: "Optional", Icon: TriangleAlert, color: "var(--color-warning)" },
  error: { label: "Missing", Icon: XCircle, color: "var(--color-role-error)" },
} as const;

/** Copy a check's fix command; flips to "Copied" briefly (native Doctor Fix). */
function CopyFixButton({ command }: { command: string }) {
  const [copied, setCopied] = useState(false);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  useEffect(() => {
    return () => {
      if (timer.current) clearTimeout(timer.current);
    };
  }, []);
  const copy = (): void => {
    let promise: Promise<void> | undefined;
    try {
      promise = navigator.clipboard?.writeText(command);
    } catch {
      return;
    }
    void promise?.then(
      () => {
        setCopied(true);
        if (timer.current) clearTimeout(timer.current);
        timer.current = setTimeout(() => setCopied(false), 1500);
      },
      () => {},
    );
  };
  return (
    <button
      data-testid="onboarding-fix-copy"
      data-fix-command={command}
      title={`Copy: ${command}`}
      className="flex shrink-0 items-center gap-1 rounded-capsule border border-border-strong px-2 py-0.5 font-mono text-[10px] text-text-secondary hover:text-text-primary"
      onClick={copy}
    >
      {copied ? <Check size={11} /> : <Copy size={11} />}
      {copied ? "Copied" : "Copy fix"}
    </button>
  );
}

const primaryButtonClass =
  "flex items-center gap-1.5 rounded-capsule px-3.5 py-1.5 text-xs font-medium shadow-capsule";
const primaryButtonStyle = {
  background:
    "linear-gradient(180deg, var(--color-brand-accent-bright), var(--color-brand-accent))",
  color: "var(--color-accent-foreground)",
} as const;

export function OnboardingOverlay() {
  const projects = useAppStore((state) => state.projects);
  const projectsLoaded = useAppStore((state) => state.projectsLoaded);
  const setView = useAppStore((state) => state.setView);
  const session = useAppStore((state) => state.session);
  const forced = onboardingForced();
  // When forced, ignore a prior dismissal so a returning user can still replay it.
  const [dismissed, setDismissed] = useState(() => (forced ? false : wasDismissed()));
  const [phase, setPhase] = useState<Phase>("tour");
  const [page, setPage] = useState(0);
  const [checks, setChecks] = useState<HealthCheck[]>([]);
  const [checksLoading, setChecksLoading] = useState(false);
  const [prefs, setPrefs] = useState<Prefs | null>(null);
  const [models, setModels] = useState<CatalogModel[]>([]);
  // Monotonic request id: a slow earlier /runtime/doctor response must not
  // overwrite a newer one (rapid Re-check, or the setup→final refetch).
  const checksReq = useRef(0);
  // Serializes preference PATCHes so two writes to the same key can't land out
  // of order (last click must win on the server, not last-to-arrive).
  const patchChain = useRef<Promise<unknown>>(Promise.resolve());

  // A close during this session always wins (even when forced via ?onboarding,
  // where the URL param would otherwise keep re-showing it).
  if (dismissed) return null;
  // Wait for the initial fetch so a returning user never flashes the overlay.
  // `forced` replays it regardless of projects/dismissal — used for testing.
  if (!forced && (!projectsLoaded || projects.length > 0)) return null;

  const dismiss = (): void => {
    try {
      localStorage.setItem(KEY, "1");
      localStorage.removeItem(FORCE_KEY); // clear the replay flag so it doesn't reappear
    } catch {
      // Storage disabled — it just won't be remembered across reloads.
    }
    setDismissed(true);
  };
  const finishTo = (view: AppView): void => {
    dismiss();
    setView(view);
  };

  const runChecks = (): void => {
    const req = ++checksReq.current;
    setChecksLoading(true);
    void fetch("/runtime/doctor")
      .then((response) => response.json())
      .then((data: { report: { checks: HealthCheck[] } }) => {
        if (req === checksReq.current) setChecks(data.report.checks);
      })
      .catch(() => {
        if (req === checksReq.current) setChecks([]);
      })
      .finally(() => {
        if (req === checksReq.current) setChecksLoading(false);
      });
  };
  // Load the current preferences + the active session's model catalog (there's no
  // session-independent model list; the bootstrap session provides one when a
  // provider is configured, otherwise the picker is empty until one is).
  const loadPreferences = (): void => {
    // Load the saved settings ONCE — refetching after the user has toggled would
    // overwrite the optimistic local edits with (possibly stale) server state.
    if (prefs === null) {
      void fetch("/settings")
        .then((response) => response.json())
        .then((data: { settings: Prefs }) => {
          const s = data.settings;
          setPrefs({
            autoTitle: s.autoTitle,
            worktreeIsolation: s.worktreeIsolation,
            gitAutomation: s.gitAutomation,
            defaultModel: s.defaultModel,
            defaultThinking: s.defaultThinking,
          });
        })
        .catch(() => {});
    }
    const sid = session?.id;
    if (sid && models.length === 0) {
      void fetch(`/sessions/${encodeURIComponent(sid)}/models`)
        .then((response) => (response.ok ? response.json() : { models: [] }))
        .then((data: { models: CatalogModel[] }) => setModels(data.models))
        .catch(() => setModels([]));
    }
  };
  // Optimistic locally; the PATCH is serialized through a chain so two writes to
  // the same key land in click order. The server merges only the provided fields.
  const patchPref = (patch: Partial<Prefs>): void => {
    setPrefs((p) => (p ? { ...p, ...patch } : p));
    patchChain.current = patchChain.current
      .catch(() => {})
      .then(() =>
        fetch("/settings", {
          method: "PATCH",
          headers: { "content-type": "application/json" },
          body: JSON.stringify(patch),
        }).catch(() => {}),
      );
  };

  const goto = (next: Phase): void => {
    setPhase(next);
    if (next === "setup" || next === "final") runChecks();
    if (next === "preferences") loadPreferences();
  };

  // Final-step routing gates (native OnboardingFinalView.primaryTarget). pi/node
  // hard-error → Review Setup; no provider creds → Connect a Provider; no project
  // → Add a Project; otherwise everything's ready → Start Coding.
  const checkById = (id: string): HealthCheck | undefined => checks.find((c) => c.id === id);
  const piMissing =
    checkById("pi-binary")?.status === "error" || checkById("node")?.status === "error";
  const providerMissing = (checkById("auth")?.status ?? "warn") !== "ok";
  const projectMissing = projects.length === 0;
  const finalCta: { label: string; view: AppView; Icon: typeof Rocket } = piMissing
    ? { label: "Review Setup", view: "doctor", Icon: Stethoscope }
    : providerMissing
      ? { label: "Connect a Provider", view: "providers", Icon: ShieldCheck }
      : projectMissing
        ? { label: "Add a Project", view: "projects", Icon: FolderPlus }
        : { label: "Start Coding", view: "chat", Icon: Rocket };

  const tourPage = PAGES[page]!;
  const isLastTourPage = page === PAGES.length - 1;

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-6"
      data-testid="onboarding"
      role="dialog"
      aria-modal="true"
      aria-label="Welcome to Agent Deck"
    >
      <div className="flex max-h-[86vh] w-full max-w-md flex-col overflow-hidden rounded-2xl border border-border-strong bg-surface-elevated shadow-elevated">
        {phase === "tour" ? (
          <>
            <div className="relative aspect-[4/3] w-full shrink-0 bg-surface-subtle">
              <img
                key={tourPage.image}
                data-testid="onboarding-image"
                src={tourPage.image}
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
                {tourPage.title}
              </h2>
              <p className="text-sm leading-relaxed text-text-secondary">{tourPage.description}</p>
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
                {isLastTourPage ? (
                  <button
                    data-testid="onboarding-check-setup"
                    className={primaryButtonClass}
                    style={primaryButtonStyle}
                    onClick={() => goto("setup")}
                  >
                    <Stethoscope size={13} aria-hidden /> Check Setup
                  </button>
                ) : (
                  <button
                    data-testid="onboarding-next"
                    className={primaryButtonClass}
                    style={primaryButtonStyle}
                    onClick={() => setPage((p) => Math.min(PAGES.length - 1, p + 1))}
                  >
                    Continue <ArrowRight size={13} aria-hidden />
                  </button>
                )}
              </div>
            </div>
          </>
        ) : null}

        {phase === "setup" ? (
          <div className="flex min-h-0 flex-col" data-testid="onboarding-setup">
            <div className="flex items-center justify-between px-5 pb-2 pt-4">
              <div className="flex items-center gap-2">
                <Stethoscope size={16} className="text-text-secondary" />
                <h2
                  className="text-base font-semibold text-text-primary"
                  style={{ fontStretch: "expanded" }}
                >
                  Setup Check
                </h2>
              </div>
              <button
                data-testid="onboarding-recheck"
                className="flex items-center gap-1 rounded-capsule border border-border-strong px-2.5 py-1 text-xs text-text-secondary hover:text-text-primary disabled:opacity-40"
                disabled={checksLoading}
                onClick={runChecks}
              >
                <RefreshCw size={11} className={checksLoading ? "animate-spin" : undefined} />
                {checksLoading ? "Checking…" : "Re-check"}
              </button>
            </div>
            <p className="px-5 pb-2 text-xs text-text-muted">
              Agent Deck works best once these pass. You can continue anyway.
            </p>
            <div className="min-h-0 flex-1 space-y-2 overflow-y-auto px-5 pb-3">
              {checks.length === 0 && checksLoading ? (
                <div className="py-6 text-center text-sm text-text-muted">Checking your setup…</div>
              ) : null}
              {checks.map((check) => {
                const { label, Icon, color } = STATUS_META[check.status];
                const isProvider = check.id === "auth";
                return (
                  <div
                    key={check.id}
                    className="flex items-start gap-3 rounded-lg border border-border-subtle bg-surface px-3 py-2.5"
                    data-testid="onboarding-check"
                    data-check-id={check.id}
                    data-check-status={check.status}
                  >
                    <Icon size={16} style={{ color }} className="mt-0.5 shrink-0" />
                    <div className="min-w-0 flex-1">
                      <div className="flex items-center gap-2">
                        <span className="text-sm font-medium text-text-primary">{check.label}</span>
                        <span className="text-[10px] uppercase tracking-wide" style={{ color }}>
                          {label}
                        </span>
                      </div>
                      <div className="break-words font-mono text-xs text-text-muted">
                        {check.detail}
                      </div>
                      {isProvider && check.status !== "ok" ? (
                        <button
                          data-testid="onboarding-connect-provider"
                          className="mt-1.5 rounded-capsule border border-border-strong px-2 py-0.5 text-[11px] text-text-secondary hover:text-text-primary"
                          onClick={() => finishTo("providers")}
                        >
                          Connect a provider
                        </button>
                      ) : null}
                    </div>
                    {check.fixCommand ? <CopyFixButton command={check.fixCommand} /> : null}
                  </div>
                );
              })}
            </div>
            <div className="flex items-center justify-between border-t border-border-subtle px-5 py-3">
              <button
                data-testid="onboarding-setup-back"
                className="flex items-center gap-1 rounded-capsule px-2.5 py-1 text-xs text-text-secondary hover:text-text-primary"
                onClick={() => setPhase("tour")}
              >
                <ArrowLeft size={13} /> Back
              </button>
              <button
                data-testid="onboarding-setup-continue"
                className={primaryButtonClass}
                style={primaryButtonStyle}
                onClick={() => goto("preferences")}
              >
                Continue <ArrowRight size={13} aria-hidden />
              </button>
            </div>
          </div>
        ) : null}

        {phase === "preferences" ? (
          <div className="flex min-h-0 flex-col" data-testid="onboarding-preferences">
            <div className="flex items-center gap-2 px-5 pb-1 pt-4">
              <SlidersHorizontal size={16} className="text-text-secondary" />
              <h2
                className="text-base font-semibold text-text-primary"
                style={{ fontStretch: "expanded" }}
              >
                Preferences
              </h2>
            </div>
            <p className="px-5 pb-2 text-xs text-text-muted">
              Defaults for new sessions — you can change these anytime later.
            </p>
            <div className="min-h-0 flex-1 space-y-3 overflow-y-auto px-5 pb-3">
              {prefs ? (
                <>
                  <PrefToggle
                    testid="pref-auto-title"
                    label="Auto-name sessions"
                    description="Generate a session title from your first message."
                    checked={prefs.autoTitle}
                    onChange={(v) => patchPref({ autoTitle: v })}
                  />
                  <PrefToggle
                    testid="pref-worktree"
                    label="Isolate sessions in a worktree"
                    description="Run each session in its own git worktree."
                    checked={prefs.worktreeIsolation}
                    onChange={(v) => patchPref({ worktreeIsolation: v })}
                  />
                  <PrefToggle
                    testid="pref-git-automation"
                    label="Automate git commits"
                    description="Let sessions stage and commit changes as they work."
                    checked={prefs.gitAutomation}
                    onChange={(v) => patchPref({ gitAutomation: v })}
                  />
                  <div className="flex flex-col gap-1 pt-1">
                    <label className="text-sm font-medium text-text-primary" htmlFor="pref-model">
                      Default model
                    </label>
                    <select
                      id="pref-model"
                      data-testid="pref-model"
                      className="rounded-md border border-border-strong bg-surface px-2 py-1.5 text-sm text-text-primary outline-none focus:border-accent"
                      value={prefs.defaultModel ?? ""}
                      onChange={(event) => patchPref({ defaultModel: event.target.value || null })}
                    >
                      <option value="">Pi&apos;s default</option>
                      {models.map((model) => (
                        <option
                          key={`${model.provider}/${model.id}`}
                          value={`${model.provider}:${model.id}`}
                        >
                          {model.name ?? model.id}
                        </option>
                      ))}
                    </select>
                    {models.length === 0 ? (
                      <span className="text-[11px] text-text-muted">
                        Connect a model provider to choose a default model.
                      </span>
                    ) : null}
                  </div>
                  <div className="flex flex-col gap-1">
                    <label
                      className="text-sm font-medium text-text-primary"
                      htmlFor="pref-thinking"
                    >
                      Default thinking
                    </label>
                    <select
                      id="pref-thinking"
                      data-testid="pref-thinking"
                      className="rounded-md border border-border-strong bg-surface px-2 py-1.5 text-sm text-text-primary outline-none focus:border-accent"
                      value={prefs.defaultThinking ?? ""}
                      onChange={(event) =>
                        patchPref({ defaultThinking: event.target.value || null })
                      }
                    >
                      <option value="">Pi&apos;s default</option>
                      {THINKING_LEVELS.map((level) => (
                        <option key={level} value={level}>
                          {level}
                        </option>
                      ))}
                    </select>
                  </div>
                </>
              ) : (
                <div className="py-6 text-center text-sm text-text-muted">Loading preferences…</div>
              )}
            </div>
            <div className="flex items-center justify-between border-t border-border-subtle px-5 py-3">
              <button
                data-testid="onboarding-preferences-back"
                className="flex items-center gap-1 rounded-capsule px-2.5 py-1 text-xs text-text-secondary hover:text-text-primary"
                onClick={() => setPhase("setup")}
              >
                <ArrowLeft size={13} /> Back
              </button>
              <button
                data-testid="onboarding-preferences-continue"
                className={primaryButtonClass}
                style={primaryButtonStyle}
                onClick={() => goto("final")}
              >
                Continue <ArrowRight size={13} aria-hidden />
              </button>
            </div>
          </div>
        ) : null}

        {phase === "final" ? (
          <div className="flex flex-col gap-3 px-5 py-5" data-testid="onboarding-final">
            <h2
              className="text-base font-semibold text-text-primary"
              style={{ fontStretch: "expanded" }}
            >
              {piMissing || providerMissing || projectMissing ? "Almost there" : "You're all set"}
            </h2>
            <p className="text-sm leading-relaxed text-text-secondary">
              {piMissing
                ? "Pi isn't ready yet — review setup to finish installing it."
                : providerMissing
                  ? "Connect a model provider so Pi has a model to run."
                  : projectMissing
                    ? "Add a project folder to start a coding session in it."
                    : "Your workspace is ready. Jump into a coding session with Pi."}
            </p>
            <div className="flex flex-col gap-1.5 py-1">
              <FinalGate label="Pi runtime" ok={!piMissing} />
              <FinalGate label="Model provider" ok={!providerMissing} />
              <FinalGate label="A project" ok={!projectMissing} />
            </div>
            <div className="flex items-center justify-between pt-1">
              <button
                data-testid="onboarding-final-back"
                className="flex items-center gap-1 rounded-capsule px-2.5 py-1 text-xs text-text-secondary hover:text-text-primary"
                onClick={() => setPhase("setup")}
              >
                <ArrowLeft size={13} /> Back
              </button>
              <button
                data-testid="onboarding-finish"
                data-target={finalCta.view}
                className={primaryButtonClass}
                style={primaryButtonStyle}
                onClick={() => finishTo(finalCta.view)}
              >
                <finalCta.Icon size={13} aria-hidden /> {finalCta.label}
              </button>
            </div>
          </div>
        ) : null}
      </div>
    </div>
  );
}

function PrefToggle({
  testid,
  label,
  description,
  checked,
  onChange,
}: {
  testid: string;
  label: string;
  description: string;
  checked: boolean;
  onChange: (value: boolean) => void;
}) {
  return (
    <div className="flex items-start justify-between gap-3">
      <div className="min-w-0">
        <div className="text-sm font-medium text-text-primary">{label}</div>
        <div className="text-xs text-text-muted">{description}</div>
      </div>
      <button
        type="button"
        role="switch"
        aria-checked={checked}
        aria-label={label}
        data-testid={testid}
        onClick={() => onChange(!checked)}
        className={cn(
          "relative mt-0.5 h-5 w-9 shrink-0 rounded-capsule transition-colors",
          checked ? "bg-[var(--color-brand-accent)]" : "bg-border-strong",
        )}
      >
        <span
          className={cn(
            "absolute top-0.5 h-4 w-4 rounded-full bg-white transition-all",
            checked ? "left-[18px]" : "left-0.5",
          )}
        />
      </button>
    </div>
  );
}

function FinalGate({ label, ok }: { label: string; ok: boolean }) {
  return (
    <div className="flex items-center gap-2 text-xs" data-testid="onboarding-gate" data-ok={ok}>
      {ok ? (
        <CheckCircle2 size={13} style={{ color: "var(--color-success)" }} />
      ) : (
        <XCircle size={13} style={{ color: "var(--color-role-error)" }} />
      )}
      <span className={ok ? "text-text-secondary" : "text-text-primary"}>{label}</span>
    </div>
  );
}

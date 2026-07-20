import {
  Brain,
  CircleDot,
  Cpu,
  FileText,
  Folder,
  GitBranch,
  Key,
  MessageSquareText,
  Repeat,
  Plug,
  Send,
  Server,
  ShieldCheck,
  Stethoscope,
  WandSparkles,
} from "lucide-react";
import { cn } from "@/lib/cn";
import { hasIntegratedDesktopChrome, isMacDesktop } from "@/lib/native";
import { useAppStore, type AppView } from "../state/store.ts";
import {
  PANEL_FADE,
  PANEL_MOVE,
  SessionsCollapsedCard,
  SessionsExpandedOverlay,
} from "./SessionsPanel.tsx";

/**
 * Native sidebar structure (SidebarViews.swift): pixel-font brand title bar,
 * sectioned nav (icon + expanded-width label, accent icon when selected),
 * and the sessions pull-up panel pinned at the bottom. When the panel
 * expands, the nav recedes (scale .98, y -24, fade) exactly like
 * CodingAgentPanelLayers.
 */

// No "Pi Agent" row: the pi-agent chat isn't a nav destination — it's the
// detail screen you reach by selecting (or starting) a session in the pull-up
// panel below, exactly like the native sidebar (which excludes .agent).
const WORKSPACE_NAV: Array<{ id: AppView; label: string; icon: typeof Send }> = [
  { id: "projects", label: "Projects", icon: Folder },
  { id: "instructions", label: "Instructions", icon: FileText },
  { id: "issues", label: "Issues", icon: CircleDot },
  { id: "git", label: "Git", icon: GitBranch },
  { id: "agents", label: "Agents", icon: Send },
  { id: "skills", label: "Skills", icon: WandSparkles },
  { id: "loops", label: "Loops", icon: Repeat },
  { id: "prompts", label: "Prompts", icon: MessageSquareText },
  { id: "memory", label: "Memory", icon: Brain },
];

const RUNTIME_NAV: Array<{ id: AppView; label: string; icon: typeof Send }> = [
  { id: "models", label: "Models", icon: Cpu },
  { id: "providers", label: "Providers", icon: ShieldCheck },
  { id: "environment", label: "Environment", icon: Key },
  { id: "extensions", label: "Extensions", icon: Plug },
  { id: "mcp", label: "MCP", icon: Server },
  { id: "doctor", label: "Doctor", icon: Stethoscope },
];

export function Sidebar() {
  const view = useAppStore((state) => state.view);
  const setView = useAppStore((state) => state.setView);
  const panelExpanded = useAppStore((state) => state.panelExpanded);
  const setPanelExpanded = useAppStore((state) => state.setPanelExpanded);
  // On the macOS desktop build the window's traffic lights overlap the top-left,
  // so drop the wordmark below them and make the strip a drag region.
  const macDesktop = isMacDesktop();
  const integratedDesktopChrome = hasIntegratedDesktopChrome();

  const rowClass = (active: boolean): string =>
    cn(
      "flex w-full items-center gap-2.5 rounded-md px-3 py-1.5 text-left text-[13px] font-medium transition-colors",
      active
        ? "bg-[var(--color-selection-fill)] text-text-primary"
        : "text-text-secondary hover:bg-[var(--color-hover-fill)]",
    );

  const sectionHeader = (label: string) => (
    <div className="px-4 pb-1 pt-3 text-[10px] font-semibold uppercase tracking-wider text-text-muted">
      {label}
    </div>
  );

  return (
    <aside
      className={cn(
        "flex w-[280px] shrink-0 flex-col overflow-hidden bg-surface-elevated",
        !integratedDesktopChrome && "border-r border-border-subtle",
      )}
      data-testid="sidebar"
    >
      {/* Brand title bar — the pixel wordmark's only appearance (native rule). */}
      <div
        className={cn(
          "flex items-center gap-3 px-4 pb-1",
          macDesktop ? "pt-9 [-webkit-app-region:drag]" : "pt-2.5",
        )}
        data-testid="sidebar-brand"
        aria-label="Agent Deck"
      >
        {(["AGENT", "DECK"] as const).map((word) => (
          <span
            key={word}
            className="translate-y-px whitespace-nowrap font-pixel text-[18px] leading-none text-text-primary"
          >
            {word}
          </span>
        ))}
      </div>

      {/* Panel host: everything below the logo. Two permanently-mounted
          layers — the nav (with the collapsed sessions card at its bottom)
          recedes while the expanded panel slides up and docks here. */}
      <div className="relative min-h-0 flex-1">
        {/* Nav layer */}
        <div
          className="absolute inset-0 flex flex-col"
          inert={panelExpanded}
          aria-hidden={panelExpanded}
          style={{
            transition: `${PANEL_MOVE}, ${PANEL_FADE}`,
            transformOrigin: "top",
            transform: panelExpanded ? "scale(0.98) translateY(-24px)" : "none",
            opacity: panelExpanded ? 0 : 1,
            pointerEvents: panelExpanded ? "none" : "auto",
          }}
        >
          <div className="min-h-0 flex-1 overflow-y-auto pb-2">
            {sectionHeader("Workspace")}
            <nav className="space-y-0.5 px-2">
              {WORKSPACE_NAV.map((item) => {
                const Icon = item.icon;
                const active = view === item.id;
                return (
                  <button
                    key={item.id}
                    className={rowClass(active)}
                    data-testid={`nav-${item.id}`}
                    onClick={() => setView(item.id)}
                  >
                    <Icon
                      size={15}
                      style={{ color: active ? "var(--color-brand-accent)" : undefined }}
                    />
                    <span style={{ fontStretch: "expanded" }}>{item.label}</span>
                  </button>
                );
              })}
            </nav>

            {sectionHeader("Runtime")}
            <nav className="space-y-0.5 px-2">
              {RUNTIME_NAV.map((item) => {
                const Icon = item.icon;
                const active = view === item.id;
                return (
                  <button
                    key={item.id}
                    className={rowClass(active)}
                    data-testid={`nav-${item.id}`}
                    onClick={() => setView(item.id)}
                  >
                    <Icon
                      size={15}
                      style={{ color: active ? "var(--color-brand-accent)" : undefined }}
                    />
                    <span style={{ fontStretch: "expanded" }}>{item.label}</span>
                  </button>
                );
              })}
            </nav>
          </div>
          <SessionsCollapsedCard onExpand={() => setPanelExpanded(true)} />
        </div>

        {/* Expanded layer — docks below the logo, full height. */}
        <SessionsExpandedOverlay
          expanded={panelExpanded}
          onCollapse={() => setPanelExpanded(false)}
        />
      </div>
    </aside>
  );
}

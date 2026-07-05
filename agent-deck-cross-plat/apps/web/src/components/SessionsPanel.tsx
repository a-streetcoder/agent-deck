import { useState } from "react";
import { ChevronDown, ChevronUp, GitFork, Pencil, Plus, Trash2 } from "lucide-react";
import type { SessionMeta } from "@agent-deck/domain";
import { cn } from "@/lib/cn";
import { useAppStore } from "../state/store.ts";
import {
  deleteSession,
  forkSession,
  newChat,
  renameSession,
  switchToSession,
} from "../state/wsBridge.ts";

/**
 * The Coding-Agent sessions panel, ported from the native sidebar
 * (CodingAgentSidebarPanel.swift + CodingAgentPanelLayers in ContentView.swift).
 *
 * Two permanently-mounted layers below the brand title bar:
 *   - the NAV layer (sections + the collapsed sessions card at its bottom),
 *     which recedes (scale .98, y -24, fade) when the panel expands;
 *   - the EXPANDED layer, which fills the whole area below the logo and
 *     slides up to dock there (origin bottom, y +52 → 0, scale .94 → 1).
 * Motion and fade run on separate curves (spring ~420ms / ease-out 220ms);
 * only transform/opacity animate — never layout.
 */

export const PANEL_MOVE = "transform 420ms cubic-bezier(0.32, 1.06, 0.38, 1)";
export const PANEL_FADE = "opacity 220ms ease-out";

function TypingDots() {
  return (
    <span className="flex items-center gap-0.5" data-testid="typing-dots">
      {[0, 1, 2].map((i) => (
        <span
          key={i}
          className="inline-block h-1.5 w-1.5 animate-pulse rounded-full bg-text-muted"
          style={{ animationDelay: `${i * 160}ms` }}
        />
      ))}
    </span>
  );
}

function SessionRow({
  session,
  active,
  running,
  onSelect,
}: {
  session: SessionMeta;
  active: boolean;
  running: boolean;
  onSelect: () => void;
}) {
  const [renaming, setRenaming] = useState(false);
  const [draft, setDraft] = useState(session.title ?? "");

  const commitRename = (): void => {
    const title = draft.trim();
    setRenaming(false);
    if (title && title !== session.title) void renameSession(session.id, title);
  };

  if (renaming) {
    return (
      <div
        className="flex items-center gap-2 rounded-md px-2.5 py-1"
        data-testid={`chat-${session.id}`}
      >
        <input
          autoFocus
          data-testid={`chat-rename-input-${session.id}`}
          className="min-w-0 flex-1 rounded border border-border-strong bg-surface px-1.5 py-0.5 text-[13px] text-text-primary outline-none focus:border-accent"
          value={draft}
          onChange={(event) => setDraft(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === "Enter") commitRename();
            if (event.key === "Escape") setRenaming(false);
          }}
          onBlur={commitRename}
        />
      </div>
    );
  }

  return (
    <div
      className={cn(
        "group flex w-full items-center gap-2 rounded-md px-2.5 py-1.5 text-left transition-colors",
        "focus-visible:outline focus-visible:outline-2 focus-visible:outline-[var(--color-brand-accent)]",
        active
          ? "bg-[var(--color-selection-fill)] text-text-primary"
          : "text-text-secondary hover:bg-[var(--color-hover-fill)]",
        !active && session.endedAt && "opacity-60 saturate-50",
      )}
      data-testid={`chat-${session.id}`}
      title={session.agentName ? `agent: ${session.agentName}` : undefined}
      role="button"
      tabIndex={0}
      onClick={onSelect}
      onKeyDown={(event) => {
        if (event.key === "Enter" || event.key === " ") {
          event.preventDefault();
          onSelect();
        }
      }}
    >
      <span
        className="min-w-0 flex-1 truncate text-[13px] font-medium"
        style={{ fontStretch: "expanded" }}
        data-testid="chat-title"
      >
        {session.title ?? "New chat"}
      </span>
      {running ? <TypingDots /> : null}
      {/* Hover-reveal actions (native session row). */}
      <span className="flex shrink-0 items-center gap-0.5 opacity-0 transition-opacity focus-within:opacity-100 group-hover:opacity-100">
        <button
          data-testid={`chat-rename-${session.id}`}
          className="rounded p-0.5 text-text-muted hover:text-text-primary"
          title="Rename"
          onClick={(event) => {
            event.stopPropagation();
            setDraft(session.title ?? "");
            setRenaming(true);
          }}
        >
          <Pencil size={12} />
        </button>
        <button
          data-testid={`chat-fork-${session.id}`}
          className="rounded p-0.5 text-text-muted enabled:hover:text-text-primary disabled:opacity-30"
          title={session.piSessionFile ? "Duplicate" : "Nothing to duplicate yet"}
          disabled={!session.piSessionFile}
          onClick={(event) => {
            event.stopPropagation();
            void forkSession(session.id);
          }}
        >
          <GitFork size={12} />
        </button>
        <button
          data-testid={`chat-delete-${session.id}`}
          className="rounded p-0.5 text-text-muted hover:text-[var(--color-role-error)]"
          title="Delete"
          onClick={(event) => {
            event.stopPropagation();
            void deleteSession(session.id);
          }}
        >
          <Trash2 size={12} />
        </button>
      </span>
    </div>
  );
}

function useSessionsData() {
  const sessions = useAppStore((state) => state.sessions);
  const projects = useAppStore((state) => state.projects);
  const currentProjectId = useAppStore((state) => state.currentProjectId);
  const currentSession = useAppStore((state) => state.session);
  const agentStatus = useAppStore((state) => state.transcript.agentStatus);
  const setView = useAppStore((state) => state.setView);

  const byNewest = [...sessions].sort((a, b) => b.createdAt.localeCompare(a.createdAt));
  const projectName = (id?: string): string =>
    id ? (projects.find((p) => p.id === id)?.name ?? "Unknown project") : "Default";

  return { byNewest, currentProjectId, currentSession, agentStatus, setView, projectName };
}

/** Collapsed card — lives at the bottom of the NAV layer. */
export function SessionsCollapsedCard({ onExpand }: { onExpand: () => void }) {
  const { byNewest, currentProjectId, currentSession, agentStatus, setView } = useSessionsData();
  const currentProjectSessions = byNewest.filter((s) => (s.projectId ?? null) === currentProjectId);

  return (
    <div className="px-2 pb-2">
      <div className="rounded-2xl border border-border-subtle bg-surface-elevated p-2 shadow-card">
        <div className="flex items-center justify-between px-1.5 pb-1">
          <span
            className="text-xs font-semibold text-text-primary"
            style={{ fontStretch: "expanded" }}
          >
            Sessions
          </span>
          <span className="flex items-center gap-1">
            <button
              data-testid="new-chat"
              className="rounded-capsule p-1 text-text-muted hover:bg-[var(--color-hover-fill)] hover:text-text-primary"
              title="New chat"
              onClick={() => {
                setView("chat");
                void newChat();
              }}
            >
              <Plus size={14} />
            </button>
            <button
              data-testid="sessions-expand"
              className="rounded-capsule p-1 text-text-muted hover:bg-[var(--color-hover-fill)] hover:text-text-primary"
              title="All sessions"
              onClick={onExpand}
            >
              <ChevronUp size={14} />
            </button>
          </span>
        </div>
        <div className="space-y-0.5" data-testid="chat-list">
          {currentProjectSessions.slice(0, 5).map((session) => (
            <SessionRow
              key={session.id}
              session={session}
              active={currentSession?.id === session.id}
              running={currentSession?.id === session.id && agentStatus === "running"}
              onSelect={() => {
                setView("chat");
                void switchToSession(session);
              }}
            />
          ))}
          {currentProjectSessions.length === 0 ? (
            <div className="px-2.5 py-2 text-xs text-text-muted">No sessions yet.</div>
          ) : null}
        </div>
      </div>
    </div>
  );
}

/**
 * Expanded layer — fills the entire area below the brand title bar and
 * slides up to dock there. Rendered as `absolute inset-0` by the sidebar.
 */
export function SessionsExpandedOverlay({
  expanded,
  onCollapse,
}: {
  expanded: boolean;
  onCollapse: () => void;
}) {
  const { byNewest, currentSession, agentStatus, setView, projectName } = useSessionsData();

  const groups = new Map<string, SessionMeta[]>();
  for (const session of byNewest) {
    const key = projectName(session.projectId);
    groups.set(key, [...(groups.get(key) ?? []), session]);
  }

  return (
    <div
      className="absolute inset-0 z-10 flex flex-col px-2 pb-2"
      data-testid="sessions-expanded"
      inert={!expanded}
      aria-hidden={!expanded}
      style={{
        transition: `${PANEL_MOVE}, ${PANEL_FADE}`,
        transformOrigin: "bottom",
        transform: expanded ? "none" : "scale(0.94) translateY(52px)",
        opacity: expanded ? 1 : 0,
        pointerEvents: expanded ? "auto" : "none",
      }}
    >
      <div className="flex min-h-0 flex-1 flex-col rounded-2xl border border-border-subtle bg-surface-elevated p-2 shadow-elevated">
        <div className="flex items-center justify-between px-1.5 pb-1.5">
          <span
            className="text-xs font-semibold text-text-primary"
            style={{ fontStretch: "expanded" }}
          >
            All sessions
          </span>
          <button
            data-testid="sessions-collapse"
            className="rounded-capsule p-1 text-text-muted hover:bg-[var(--color-hover-fill)] hover:text-text-primary"
            onClick={onCollapse}
          >
            <ChevronDown size={14} />
          </button>
        </div>
        <div className="min-h-0 flex-1 space-y-2 overflow-y-auto">
          {[...groups.entries()].map(([group, groupSessions]) => (
            <div key={group}>
              <div className="px-2.5 pb-0.5 pt-1 text-[10px] font-semibold uppercase tracking-wider text-text-muted">
                {group}
              </div>
              <div className="space-y-0.5">
                {groupSessions.map((session) => (
                  <SessionRow
                    key={session.id}
                    session={session}
                    active={currentSession?.id === session.id}
                    running={currentSession?.id === session.id && agentStatus === "running"}
                    onSelect={() => {
                      setView("chat");
                      onCollapse();
                      void switchToSession(session);
                    }}
                  />
                ))}
              </div>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

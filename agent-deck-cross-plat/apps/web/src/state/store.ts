import type {
  CheckpointInfo,
  DiffFileEntry,
  KeybindingBinding,
  ProjectMeta,
  SessionMeta,
} from "@agent-deck/contracts";
import { emptyTranscript, type TranscriptState } from "@agent-deck/domain";
import { create } from "zustand";
import type { PendingReviewComment, ReviewCommentSide } from "../lib/reviewComments.ts";
import type { PendingElementContext } from "../lib/elementContext.ts";

/** A jump-to-diff request raised by a pending review-comment card (Slice 12). */
export interface DiffJumpRequest {
  path: string;
  side: ReviewCommentSide;
  line: number;
  /** Distinguishes repeat jumps to the same anchor. */
  token: number;
}

export type ConnectionStatus = "connecting" | "open" | "closed";

export type AppView =
  | "chat"
  | "agents"
  | "skills"
  | "projects"
  | "instructions"
  | "issues"
  | "git"
  | "loops"
  | "prompts"
  | "models"
  | "extensions"
  | "environment"
  | "providers"
  | "memory"
  | "mcp"
  | "doctor";

export type ToastKind = "success" | "error" | "info";

export interface Toast {
  id: string;
  message: string;
  kind: ToastKind;
}

/**
 * The tools that open as TABS in the right-side workspace pane (Slice L1). Each
 * is a singleton surface for the current session. "browser" is a deliberate
 * future extension point (a later slice): the whole tabs model — this union, the
 * strip, the pane width table, the "+" menu — is keyed on this type, so adding
 * "browser" is a purely additive change. The TERMINAL is intentionally NOT here:
 * it stays the bottom drawer (terminalOpen), never a tab.
 */
export type WorkspaceTabKind = "diff" | "files" | "preview" | "checkpoints";

/** One session's open workspace tabs, in strip order, plus the active one. */
export interface WorkspaceTabsState {
  /** Open tabs, left→right in the strip. Empty = the pane is not rendered. */
  tabs: WorkspaceTabKind[];
  /** The tab whose body is shown; null only when {@link tabs} is empty. */
  activeTab: WorkspaceTabKind | null;
}

/** Shared empty reference so selectors never return a fresh object per call. */
export const EMPTY_WORKSPACE_TABS: WorkspaceTabsState = { tabs: [], activeTab: null };

/** Remove `kind` from a session's tabs, falling the active selection back to the
 * neighbor (the tab that slides into its slot, else the new last) — the t3code
 * closeSurface fallback, adapted to our singleton-kind strip. */
function closeWorkspaceKind(
  current: WorkspaceTabsState,
  kind: WorkspaceTabKind,
): WorkspaceTabsState {
  const index = current.tabs.indexOf(kind);
  if (index < 0) return current;
  const tabs = current.tabs.filter((k) => k !== kind);
  if (current.activeTab !== kind) return { tabs, activeTab: current.activeTab };
  return { tabs, activeTab: tabs[Math.min(index, tabs.length - 1)] ?? null };
}

/** Apply `updater` to one session's tab state, pruning the map entry when a
 * session's strip empties (mirrors the pendingReviewComments delete-on-empty). */
function updateWorkspaceTabs(
  map: Record<string, WorkspaceTabsState>,
  sessionId: string,
  updater: (current: WorkspaceTabsState) => WorkspaceTabsState,
): Record<string, WorkspaceTabsState> {
  const current = map[sessionId] ?? EMPTY_WORKSPACE_TABS;
  const next = updater(current);
  if (next === current) return map;
  if (next.tabs.length === 0) {
    if (!(sessionId in map)) return map;
    const { [sessionId]: _removed, ...rest } = map;
    return rest;
  }
  return { ...map, [sessionId]: next };
}

export interface AppState {
  connection: ConnectionStatus;
  view: AppView;
  /**
   * Whether the sessions pull-up panel covers the sidebar nav (native
   * isCodingAgentPanelExpanded). One global boolean: it persists while you
   * switch sessions and only auto-collapses when you leave the chat view for
   * another nav section.
   */
  panelExpanded: boolean;
  /** Bumped by resources_changed pushes; resource screens refetch on change. */
  resourcesVersion: number;
  projects: ProjectMeta[];
  /** True once the initial /projects fetch has settled (avoids first-run flash). */
  projectsLoaded: boolean;
  /** null = no project selected ("All Projects" — native's aggregate view). */
  currentProjectId: string | null;
  /** null = the default "Pi Agent" session; a name = agent-backed session. */
  currentAgentName: string | null;
  session: SessionMeta | null;
  /** All known sessions (live + persisted), for the sidebar chat list. */
  sessions: SessionMeta[];
  /** A prompt to drop into the composer (e.g. seeded from a GitHub issue). */
  pendingComposerText: string | null;
  /**
   * Whether the per-session terminal drawer is open (Slice 8b). One global
   * boolean like panelExpanded: the drawer shows the CURRENT session's
   * terminal, and closing it keeps the terminal alive server-side.
   */
  terminalOpen: boolean;
  /**
   * Per-SESSION right-side workspace tabs (Slice L1). Keyed by session id
   * (mirrors pendingReviewComments): each session owns its own strip of open
   * tool tabs (diff / files / preview / checkpoints) plus the active one, so
   * switching sessions swaps the whole pane. Replaces the four global
   * diff/files/preview/checkpoints "panel open" booleans — the tools now open as
   * Chrome-style tabs in ONE right pane instead of four side-by-side asides. The
   * terminal drawer (terminalOpen) stays a separate bottom drawer. In-memory
   * only (no persistence this slice); a session's entry is dropped when it is
   * deleted or its strip empties.
   */
  workspaceTabs: Record<string, WorkspaceTabsState>;
  /**
   * The current session's captured checkpoints (Slice 18b), oldest capture
   * first — refreshed on subscribe + after each turn reaches idle + after a
   * rollback. Drives the header's "available checkpoints" indicator and the
   * panel's timeline. Empty for a session with no captures yet.
   */
  checkpoints: readonly CheckpointInfo[];
  /** Whether the current session's cwd is a git work tree (diff surface gate).
   * False until the first diff_files fetch answers — the toggle stays hidden
   * for non-repo sessions and while the answer is in flight. */
  diffRepo: boolean;
  /** The current session's changed-file set (server-refreshed per turn). */
  diffFiles: readonly DiffFileEntry[];
  /** True when the set was capped at the server's DIFF_MAX_FILES bound. */
  diffTruncated: boolean;
  /**
   * Pending review comments per SESSION id (Slice 12): captured on diff rows,
   * shown above the composer, serialized into the next outgoing prompt and
   * cleared by the send. Keyed by session so switching sessions keeps each
   * set separate; page reload drops them (deliberate — see lib/reviewComments).
   */
  pendingReviewComments: Record<string, readonly PendingReviewComment[]>;
  /**
   * Pending preview element contexts per SESSION id (Slice 16): captured by
   * pointing out an element in the S15 preview panel, shown above the composer,
   * serialized into the next outgoing prompt (a donor `<element_context>` block)
   * and cleared by the send. Keyed by session (mirrors pendingReviewComments):
   * sets stay separate across session switches and die with the page.
   */
  pendingElementContexts: Record<string, readonly PendingElementContext[]>;
  /** A jump-to-diff request from a pending card; consumed by the DiffPanel. */
  diffJumpRequest: DiffJumpRequest | null;
  /**
   * User keybinding overrides (Slice 14), layered over DEFAULT_KEYBINDINGS. The
   * global shortcut handler and the command palette both resolve chords from
   * this list, so a rebind applies live the moment it lands here. Seeded from
   * GET /settings on boot; the editor PATCHes /settings and updates this in the
   * same breath.
   */
  keybindings: KeybindingBinding[];
  /** Whether the command palette overlay is open (Ctrl/⌘+K). */
  commandPaletteOpen: boolean;
  /** Whether the keybindings editor sheet is open (from the palette). */
  keybindingsEditorOpen: boolean;
  transcript: TranscriptState;
  /** Last seq applied — sent on resubscribe so the server replays the gap. */
  lastSeq: number;
  error: string | null;
  /** Transient notifications (native toasts), newest last; auto-dismissed by the Toaster. */
  toasts: Toast[];
  setConnection(connection: ConnectionStatus): void;
  setView(view: AppView): void;
  setPanelExpanded(expanded: boolean): void;
  bumpResourcesVersion(): void;
  setProjects(projects: ProjectMeta[]): void;
  setCurrentProject(projectId: string | null): void;
  setCurrentAgent(agentName: string | null): void;
  setSession(session: SessionMeta | null): void;
  setSessions(sessions: SessionMeta[]): void;
  setPendingComposerText(text: string | null): void;
  setKeybindings(keybindings: KeybindingBinding[]): void;
  setCommandPaletteOpen(open: boolean): void;
  setKeybindingsEditorOpen(open: boolean): void;
  setTerminalOpen(open: boolean): void;
  /** Open `kind` as a tab for `sessionId` (add if absent) and make it active. */
  openWorkspaceTab(sessionId: string, kind: WorkspaceTabKind): void;
  /** Header/palette toggle: active tab → close; background tab → activate;
   * closed → open+activate. Keeps the header button's click-to-open,
   * click-again-to-close feel. */
  toggleWorkspaceTab(sessionId: string, kind: WorkspaceTabKind): void;
  /** Bring an already-open tab to the front (no-op if it isn't open). */
  activateWorkspaceTab(sessionId: string, kind: WorkspaceTabKind): void;
  /** Close one tab; the active selection falls back to the neighbor. */
  closeWorkspaceTab(sessionId: string, kind: WorkspaceTabKind): void;
  /** Context menu: keep only `kind`. */
  closeOtherWorkspaceTabs(sessionId: string, kind: WorkspaceTabKind): void;
  /** Context menu: close every tab to the right of `kind`. */
  closeWorkspaceTabsToRight(sessionId: string, kind: WorkspaceTabKind): void;
  /** Context menu: close the whole strip for the session. */
  closeAllWorkspaceTabs(sessionId: string): void;
  /** Replace the current session's checkpoint list (a checkpoints_list fetch). */
  setCheckpoints(checkpoints: readonly CheckpointInfo[]): void;
  /** Replace the changed-file set (a diff_push or a diff_files fetch). */
  setDiffState(state: { repo: boolean; files: readonly DiffFileEntry[]; truncated: boolean }): void;
  /** Drop the previous session's set on a session switch (panel stays open). */
  resetDiffState(): void;
  /** Add a captured review comment to a session's pending set (Slice 12). */
  addReviewComment(sessionId: string, comment: PendingReviewComment): void;
  /** Edit a pending comment's body in place (anchor + excerpt unchanged). */
  updateReviewComment(sessionId: string, commentId: string, text: string): void;
  /** Drop one pending comment (inline card / composer card dismiss). */
  removeReviewComment(sessionId: string, commentId: string): void;
  /** Clear a session's whole pending set (the send that delivered them). */
  clearReviewComments(sessionId: string): void;
  /** Add a captured preview element context to a session's pending set (Slice 16). */
  addElementContext(sessionId: string, context: PendingElementContext): void;
  /** Drop one pending element context (composer card dismiss). */
  removeElementContext(sessionId: string, contextId: string): void;
  /** Clear a session's whole pending element-context set (the send delivered them). */
  clearElementContexts(sessionId: string): void;
  /** Raise a jump-to-diff request from a pending card; the DiffPanel consumes it. */
  requestDiffJump(request: Omit<DiffJumpRequest, "token">): void;
  /** The DiffPanel drops the request once it has scrolled to the anchor. */
  clearDiffJump(): void;
  upsertSessionMeta(session: SessionMeta): void;
  removeSession(sessionId: string): void;
  setSnapshot(state: TranscriptState, seq: number): void;
  setTranscript(state: TranscriptState, seq: number): void;
  resetTranscript(): void;
  setError(error: string | null): void;
  /** Queue a transient toast; returns its id. */
  pushToast(toast: Omit<Toast, "id">): string;
  dismissToast(id: string): void;
}

const PANEL_KEY = "agentdeck-panel-expanded";

/** The panel opens the way you last left it (persisted); collapsed by default. */
function initialPanelExpanded(): boolean {
  try {
    return localStorage.getItem(PANEL_KEY) === "1";
  } catch {
    return false;
  }
}

export const useAppStore = create<AppState>((set) => ({
  connection: "connecting",
  view: "chat",
  panelExpanded: initialPanelExpanded(),
  resourcesVersion: 0,
  projects: [],
  projectsLoaded: false,
  currentProjectId: null,
  currentAgentName: null,
  session: null,
  sessions: [],
  pendingComposerText: null,
  terminalOpen: false,
  workspaceTabs: {},
  checkpoints: [],
  diffRepo: false,
  diffFiles: [],
  diffTruncated: false,
  pendingReviewComments: {},
  pendingElementContexts: {},
  diffJumpRequest: null,
  keybindings: [],
  commandPaletteOpen: false,
  keybindingsEditorOpen: false,
  transcript: emptyTranscript(),
  lastSeq: 0,
  error: null,
  toasts: [],
  setConnection: (connection) => set({ connection }),
  // Leaving chat for another nav section auto-collapses the panel (revealing the
  // nav it covers); staying in chat — e.g. selecting a session — leaves the
  // expansion untouched so it persists across session switches.
  setView: (view) => set(view === "chat" ? { view } : { view, panelExpanded: false }),
  // Explicit expand/collapse persists so the panel launches as you left it.
  // (setView's auto-collapse is transient and deliberately does not persist.)
  setPanelExpanded: (panelExpanded) => {
    try {
      localStorage.setItem(PANEL_KEY, panelExpanded ? "1" : "0");
    } catch {
      // Private-mode / storage-disabled: preference just isn't remembered.
    }
    set({ panelExpanded });
  },
  bumpResourcesVersion: () => set((state) => ({ resourcesVersion: state.resourcesVersion + 1 })),
  setProjects: (projects) => set({ projects, projectsLoaded: true }),
  setCurrentProject: (currentProjectId) => set({ currentProjectId }),
  setCurrentAgent: (currentAgentName) => set({ currentAgentName }),
  setSession: (session) => set({ session }),
  setSessions: (sessions) => set({ sessions }),
  setPendingComposerText: (pendingComposerText) => set({ pendingComposerText }),
  setKeybindings: (keybindings) => set({ keybindings }),
  setCommandPaletteOpen: (commandPaletteOpen) => set({ commandPaletteOpen }),
  setKeybindingsEditorOpen: (keybindingsEditorOpen) => set({ keybindingsEditorOpen }),
  setTerminalOpen: (terminalOpen) => set({ terminalOpen }),
  openWorkspaceTab: (sessionId, kind) =>
    set((state) => ({
      workspaceTabs: updateWorkspaceTabs(state.workspaceTabs, sessionId, (current) => ({
        tabs: current.tabs.includes(kind) ? current.tabs : [...current.tabs, kind],
        activeTab: kind,
      })),
    })),
  toggleWorkspaceTab: (sessionId, kind) =>
    set((state) => ({
      workspaceTabs: updateWorkspaceTabs(state.workspaceTabs, sessionId, (current) => {
        const isOpen = current.tabs.includes(kind);
        if (isOpen && current.activeTab === kind) return closeWorkspaceKind(current, kind);
        return {
          tabs: isOpen ? current.tabs : [...current.tabs, kind],
          activeTab: kind,
        };
      }),
    })),
  activateWorkspaceTab: (sessionId, kind) =>
    set((state) => ({
      workspaceTabs: updateWorkspaceTabs(state.workspaceTabs, sessionId, (current) =>
        current.tabs.includes(kind) && current.activeTab !== kind
          ? { ...current, activeTab: kind }
          : current,
      ),
    })),
  closeWorkspaceTab: (sessionId, kind) =>
    set((state) => ({
      workspaceTabs: updateWorkspaceTabs(state.workspaceTabs, sessionId, (current) =>
        closeWorkspaceKind(current, kind),
      ),
    })),
  closeOtherWorkspaceTabs: (sessionId, kind) =>
    set((state) => ({
      workspaceTabs: updateWorkspaceTabs(state.workspaceTabs, sessionId, (current) =>
        current.tabs.includes(kind) && current.tabs.length > 1
          ? { tabs: [kind], activeTab: kind }
          : current,
      ),
    })),
  closeWorkspaceTabsToRight: (sessionId, kind) =>
    set((state) => ({
      workspaceTabs: updateWorkspaceTabs(state.workspaceTabs, sessionId, (current) => {
        const index = current.tabs.indexOf(kind);
        if (index < 0 || index === current.tabs.length - 1) return current;
        const tabs = current.tabs.slice(0, index + 1);
        const activeTab =
          current.activeTab !== null && tabs.includes(current.activeTab) ? current.activeTab : kind;
        return { tabs, activeTab };
      }),
    })),
  closeAllWorkspaceTabs: (sessionId) =>
    set((state) => ({
      workspaceTabs: updateWorkspaceTabs(state.workspaceTabs, sessionId, (current) =>
        current.tabs.length === 0 ? current : EMPTY_WORKSPACE_TABS,
      ),
    })),
  setCheckpoints: (checkpoints) => set({ checkpoints }),
  setDiffState: ({ repo, files, truncated }) =>
    set({ diffRepo: repo, diffFiles: files, diffTruncated: truncated }),
  resetDiffState: () => set({ diffRepo: false, diffFiles: [], diffTruncated: false }),
  addReviewComment: (sessionId, comment) =>
    set((state) => ({
      pendingReviewComments: {
        ...state.pendingReviewComments,
        [sessionId]: [...(state.pendingReviewComments[sessionId] ?? []), comment],
      },
    })),
  updateReviewComment: (sessionId, commentId, text) =>
    set((state) => {
      const existing = state.pendingReviewComments[sessionId];
      if (existing === undefined) return {};
      return {
        pendingReviewComments: {
          ...state.pendingReviewComments,
          [sessionId]: existing.map((comment) =>
            comment.id === commentId ? { ...comment, text: text.trim() } : comment,
          ),
        },
      };
    }),
  removeReviewComment: (sessionId, commentId) =>
    set((state) => {
      const existing = state.pendingReviewComments[sessionId];
      if (existing === undefined) return {};
      return {
        pendingReviewComments: {
          ...state.pendingReviewComments,
          [sessionId]: existing.filter((comment) => comment.id !== commentId),
        },
      };
    }),
  clearReviewComments: (sessionId) =>
    set((state) => {
      if (!(sessionId in state.pendingReviewComments)) return {};
      const next = { ...state.pendingReviewComments };
      delete next[sessionId];
      return { pendingReviewComments: next };
    }),
  addElementContext: (sessionId, context) =>
    set((state) => ({
      pendingElementContexts: {
        ...state.pendingElementContexts,
        [sessionId]: [...(state.pendingElementContexts[sessionId] ?? []), context],
      },
    })),
  removeElementContext: (sessionId, contextId) =>
    set((state) => {
      const existing = state.pendingElementContexts[sessionId];
      if (existing === undefined) return {};
      return {
        pendingElementContexts: {
          ...state.pendingElementContexts,
          [sessionId]: existing.filter((context) => context.id !== contextId),
        },
      };
    }),
  clearElementContexts: (sessionId) =>
    set((state) => {
      if (!(sessionId in state.pendingElementContexts)) return {};
      const next = { ...state.pendingElementContexts };
      delete next[sessionId];
      return { pendingElementContexts: next };
    }),
  requestDiffJump: (request) =>
    set((state) => ({
      diffJumpRequest: { ...request, token: (state.diffJumpRequest?.token ?? 0) + 1 },
    })),
  clearDiffJump: () => set({ diffJumpRequest: null }),
  upsertSessionMeta: (session) =>
    set((state) => ({
      sessions: state.sessions.some((s) => s.id === session.id)
        ? state.sessions.map((s) => (s.id === session.id ? session : s))
        : [...state.sessions, session],
      session: state.session?.id === session.id ? session : state.session,
    })),
  removeSession: (sessionId) =>
    set((state) => {
      const pendingReviewComments =
        sessionId in state.pendingReviewComments
          ? Object.fromEntries(
              Object.entries(state.pendingReviewComments).filter(([id]) => id !== sessionId),
            )
          : state.pendingReviewComments;
      const pendingElementContexts =
        sessionId in state.pendingElementContexts
          ? Object.fromEntries(
              Object.entries(state.pendingElementContexts).filter(([id]) => id !== sessionId),
            )
          : state.pendingElementContexts;
      const workspaceTabs =
        sessionId in state.workspaceTabs
          ? Object.fromEntries(
              Object.entries(state.workspaceTabs).filter(([id]) => id !== sessionId),
            )
          : state.workspaceTabs;
      return {
        sessions: state.sessions.filter((s) => s.id !== sessionId),
        pendingReviewComments,
        pendingElementContexts,
        workspaceTabs,
      };
    }),
  setSnapshot: (transcript, lastSeq) => set({ transcript, lastSeq }),
  setTranscript: (transcript, lastSeq) => set({ transcript, lastSeq }),
  resetTranscript: () => set({ transcript: emptyTranscript(), lastSeq: 0 }),
  setError: (error) => set({ error }),
  pushToast: (toast) => {
    const id = `toast-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
    set((state) => ({ toasts: [...state.toasts, { ...toast, id }] }));
    return id;
  },
  dismissToast: (id) => set((state) => ({ toasts: state.toasts.filter((t) => t.id !== id) })),
}));

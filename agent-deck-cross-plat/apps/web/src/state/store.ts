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
   * Whether the changed-files / diff panel is open (Slice 10). Follows the
   * terminalOpen pattern: one global boolean, the panel always shows the
   * CURRENT session's changed-file set.
   */
  diffPanelOpen: boolean;
  /**
   * Whether the file-navigation panel is open (Slice 13b). Follows the
   * terminalOpen / diffPanelOpen pattern: one global boolean, the panel always
   * browses the CURRENT session's project tree. Ungated by repo (any session
   * has a cwd), so the toggle shows for every chat session.
   */
  filesPanelOpen: boolean;
  /**
   * Whether the dev-server preview panel is open (Slice 15b). Follows the
   * terminalOpen / filesPanelOpen pattern: one global boolean, the panel runs
   * the CURRENT session's package.json scripts and embeds the discovered
   * dev-server URL. Ungated (any session has a cwd + maybe scripts), so the
   * toggle shows for every chat session; renders null while closed (a session
   * that never opens it never spawns a dev server).
   */
  previewPanelOpen: boolean;
  /**
   * Whether the checkpoints/timeline panel is open (Slice 18b). Follows the
   * terminalOpen / diffPanelOpen pattern: one global boolean, the panel always
   * shows the CURRENT session's captured checkpoints and offers a destructive
   * rollback to a prior turn. Ungated (any session captures per turn).
   */
  checkpointsPanelOpen: boolean;
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
  setDiffPanelOpen(open: boolean): void;
  setFilesPanelOpen(open: boolean): void;
  setPreviewPanelOpen(open: boolean): void;
  setCheckpointsPanelOpen(open: boolean): void;
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
  diffPanelOpen: false,
  filesPanelOpen: false,
  previewPanelOpen: false,
  checkpointsPanelOpen: false,
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
  setDiffPanelOpen: (diffPanelOpen) => set({ diffPanelOpen }),
  setFilesPanelOpen: (filesPanelOpen) => set({ filesPanelOpen }),
  setPreviewPanelOpen: (previewPanelOpen) => set({ previewPanelOpen }),
  setCheckpointsPanelOpen: (checkpointsPanelOpen) => set({ checkpointsPanelOpen }),
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
      return {
        sessions: state.sessions.filter((s) => s.id !== sessionId),
        pendingReviewComments,
        pendingElementContexts,
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

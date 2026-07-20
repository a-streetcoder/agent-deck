import type { ProjectMeta, SessionMeta } from "@agent-deck/contracts";
import { emptyTranscript, type TranscriptState } from "@agent-deck/domain";
import { create } from "zustand";

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
  setTerminalOpen(open: boolean): void;
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
  setTerminalOpen: (terminalOpen) => set({ terminalOpen }),
  upsertSessionMeta: (session) =>
    set((state) => ({
      sessions: state.sessions.some((s) => s.id === session.id)
        ? state.sessions.map((s) => (s.id === session.id ? session : s))
        : [...state.sessions, session],
      session: state.session?.id === session.id ? session : state.session,
    })),
  removeSession: (sessionId) =>
    set((state) => ({ sessions: state.sessions.filter((s) => s.id !== sessionId) })),
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

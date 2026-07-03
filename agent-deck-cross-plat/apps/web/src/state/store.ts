import {
  emptyTranscript,
  type ProjectMeta,
  type SessionMeta,
  type TranscriptState,
} from "@agent-deck/domain";
import { create } from "zustand";

export type ConnectionStatus = "connecting" | "open" | "closed";

export type AppView = "chat" | "agents" | "skills";

export interface AppState {
  connection: ConnectionStatus;
  view: AppView;
  /** Bumped by resources_changed pushes; resource screens refetch on change. */
  resourcesVersion: number;
  projects: ProjectMeta[];
  /** null = the server's default cwd ("Default" workspace). */
  currentProjectId: string | null;
  /** null = the default "Pi Agent" session; a name = agent-backed session. */
  currentAgentName: string | null;
  session: SessionMeta | null;
  transcript: TranscriptState;
  /** Last seq applied — sent on resubscribe so the server replays the gap. */
  lastSeq: number;
  error: string | null;
  setConnection(connection: ConnectionStatus): void;
  setView(view: AppView): void;
  bumpResourcesVersion(): void;
  setProjects(projects: ProjectMeta[]): void;
  setCurrentProject(projectId: string | null): void;
  setCurrentAgent(agentName: string | null): void;
  setSession(session: SessionMeta | null): void;
  setSnapshot(state: TranscriptState, seq: number): void;
  setTranscript(state: TranscriptState, seq: number): void;
  resetTranscript(): void;
  setError(error: string | null): void;
}

export const useAppStore = create<AppState>((set) => ({
  connection: "connecting",
  view: "chat",
  resourcesVersion: 0,
  projects: [],
  currentProjectId: null,
  currentAgentName: null,
  session: null,
  transcript: emptyTranscript(),
  lastSeq: 0,
  error: null,
  setConnection: (connection) => set({ connection }),
  setView: (view) => set({ view }),
  bumpResourcesVersion: () => set((state) => ({ resourcesVersion: state.resourcesVersion + 1 })),
  setProjects: (projects) => set({ projects }),
  setCurrentProject: (currentProjectId) => set({ currentProjectId }),
  setCurrentAgent: (currentAgentName) => set({ currentAgentName }),
  setSession: (session) => set({ session }),
  setSnapshot: (transcript, lastSeq) => set({ transcript, lastSeq }),
  setTranscript: (transcript, lastSeq) => set({ transcript, lastSeq }),
  resetTranscript: () => set({ transcript: emptyTranscript(), lastSeq: 0 }),
  setError: (error) => set({ error }),
}));

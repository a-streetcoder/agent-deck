import {
  emptyTranscript,
  type ProjectMeta,
  type SessionMeta,
  type TranscriptState,
} from "@agent-deck/domain";
import { create } from "zustand";

export type ConnectionStatus = "connecting" | "open" | "closed";

export interface AppState {
  connection: ConnectionStatus;
  projects: ProjectMeta[];
  /** null = the server's default cwd ("Default" workspace). */
  currentProjectId: string | null;
  session: SessionMeta | null;
  transcript: TranscriptState;
  /** Last seq applied — sent on resubscribe so the server replays the gap. */
  lastSeq: number;
  error: string | null;
  setConnection(connection: ConnectionStatus): void;
  setProjects(projects: ProjectMeta[]): void;
  setCurrentProject(projectId: string | null): void;
  setSession(session: SessionMeta | null): void;
  setSnapshot(state: TranscriptState, seq: number): void;
  setTranscript(state: TranscriptState, seq: number): void;
  resetTranscript(): void;
  setError(error: string | null): void;
}

export const useAppStore = create<AppState>((set) => ({
  connection: "connecting",
  projects: [],
  currentProjectId: null,
  session: null,
  transcript: emptyTranscript(),
  lastSeq: 0,
  error: null,
  setConnection: (connection) => set({ connection }),
  setProjects: (projects) => set({ projects }),
  setCurrentProject: (currentProjectId) => set({ currentProjectId }),
  setSession: (session) => set({ session }),
  setSnapshot: (transcript, lastSeq) => set({ transcript, lastSeq }),
  setTranscript: (transcript, lastSeq) => set({ transcript, lastSeq }),
  resetTranscript: () => set({ transcript: emptyTranscript(), lastSeq: 0 }),
  setError: (error) => set({ error }),
}));

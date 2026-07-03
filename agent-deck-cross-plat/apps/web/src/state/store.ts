import { emptyTranscript, type SessionMeta, type TranscriptState } from "@agent-deck/domain";
import { create } from "zustand";

export type ConnectionStatus = "connecting" | "open" | "closed";

export interface AppState {
  connection: ConnectionStatus;
  session: SessionMeta | null;
  transcript: TranscriptState;
  /** Last seq applied — sent on resubscribe so the server replays the gap. */
  lastSeq: number;
  error: string | null;
  setConnection(connection: ConnectionStatus): void;
  setSession(session: SessionMeta): void;
  setSnapshot(state: TranscriptState, seq: number): void;
  setTranscript(state: TranscriptState, seq: number): void;
  setError(error: string | null): void;
}

export const useAppStore = create<AppState>((set) => ({
  connection: "connecting",
  session: null,
  transcript: emptyTranscript(),
  lastSeq: 0,
  error: null,
  setConnection: (connection) => set({ connection }),
  setSession: (session) => set({ session }),
  setSnapshot: (transcript, lastSeq) => set({ transcript, lastSeq }),
  setTranscript: (transcript, lastSeq) => set({ transcript, lastSeq }),
  setError: (error) => set({ error }),
}));

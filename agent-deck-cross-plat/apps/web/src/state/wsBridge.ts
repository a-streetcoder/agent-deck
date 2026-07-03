import {
  reduceTranscript,
  type ClientMessage,
  type ServerMessage,
  type SessionMeta,
} from "@agent-deck/domain";
import { useAppStore } from "./store.ts";

/**
 * The ONLY module that touches the WebSocket. Server messages mutate the
 * zustand store through the shared domain reducer; UI components send
 * commands exclusively through the exported functions below.
 */

let socket: WebSocket | null = null;
let reconnectDelayMs = 500;

function wsUrl(): string {
  const proto = location.protocol === "https:" ? "wss" : "ws";
  return `${proto}://${location.host}/ws`;
}

function send(message: ClientMessage): void {
  if (socket?.readyState === WebSocket.OPEN) {
    socket.send(JSON.stringify(message));
  }
}

function handleMessage(message: ServerMessage): void {
  const store = useAppStore.getState();
  switch (message.type) {
    case "snapshot":
      store.setSnapshot(message.state, message.seq);
      break;
    case "event": {
      const { transcript, lastSeq } = useAppStore.getState();
      if (message.seq <= lastSeq) return; // replay overlap — already applied
      store.setTranscript(reduceTranscript(transcript, message.event), message.seq);
      break;
    }
    case "error":
      store.setError(message.message);
      break;
    case "session_exit":
      store.setError(`pi exited (code ${message.code ?? "?"})`);
      break;
    case "hello_ok":
      break;
  }
}

function connect(sessionId: string): void {
  useAppStore.getState().setConnection("connecting");
  socket = new WebSocket(wsUrl());
  socket.onopen = () => {
    reconnectDelayMs = 500;
    useAppStore.getState().setConnection("open");
    const { lastSeq } = useAppStore.getState();
    send({
      type: "subscribe_session",
      sessionId,
      lastSeq: lastSeq > 0 ? lastSeq : undefined,
    });
  };
  socket.onmessage = (event) => {
    handleMessage(JSON.parse(event.data as string) as ServerMessage);
  };
  socket.onclose = () => {
    useAppStore.getState().setConnection("closed");
    setTimeout(() => connect(sessionId), reconnectDelayMs);
    reconnectDelayMs = Math.min(reconnectDelayMs * 2, 10_000);
  };
}

/** Reuse the server's existing session or create one, then open the socket. */
export async function connectAndBootstrap(): Promise<void> {
  try {
    const listResponse = await fetch("/sessions");
    const { sessions } = (await listResponse.json()) as { sessions: SessionMeta[] };
    let session = sessions.at(-1) ?? null;
    if (!session) {
      const createResponse = await fetch("/sessions", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({}),
      });
      if (!createResponse.ok) {
        throw new Error(`session create failed: ${await createResponse.text()}`);
      }
      session = ((await createResponse.json()) as { session: SessionMeta }).session;
    }
    useAppStore.getState().setSession(session);
    connect(session.id);
  } catch (error) {
    useAppStore.getState().setError(String(error));
  }
}

export function sendPrompt(message: string): void {
  const session = useAppStore.getState().session;
  if (session) send({ type: "prompt", sessionId: session.id, message });
}

export function sendAbort(): void {
  const session = useAppStore.getState().session;
  if (session) send({ type: "abort", sessionId: session.id });
}

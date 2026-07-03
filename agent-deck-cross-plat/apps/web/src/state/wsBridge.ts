import {
  reduceTranscript,
  type ClientMessage,
  type ProjectMeta,
  type ServerMessage,
  type SessionMeta,
} from "@agent-deck/domain";
import { useAppStore } from "./store.ts";

/**
 * The ONLY module that touches the WebSocket. Server messages mutate the
 * zustand store through the shared domain reducer; UI components send
 * commands exclusively through the exported functions below.
 *
 * One socket, one subscribed session at a time: switching project closes the
 * socket and reconnects subscribed to that project's session.
 */

let socket: WebSocket | null = null;
let reconnectDelayMs = 500;
let currentSessionId: string | null = null;
let generation = 0; // bumped on every deliberate switch to invalidate reconnects

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
      if (message.sessionId !== currentSessionId) return;
      store.setSnapshot(message.state, message.seq);
      break;
    case "event": {
      if (message.sessionId !== currentSessionId) return;
      const { transcript, lastSeq } = useAppStore.getState();
      if (message.seq <= lastSeq) return; // replay overlap — already applied
      store.setTranscript(reduceTranscript(transcript, message.event), message.seq);
      break;
    }
    case "error":
      store.setError(message.message);
      break;
    case "session_exit":
      if (message.sessionId !== currentSessionId) return;
      store.setError(`pi exited (code ${message.code ?? "?"})`);
      break;
    case "resources_changed":
      store.bumpResourcesVersion();
      break;
    case "hello_ok":
      break;
  }
}

function connect(sessionId: string): void {
  const myGeneration = ++generation;
  currentSessionId = sessionId;
  socket?.close();
  useAppStore.getState().setConnection("connecting");
  socket = new WebSocket(wsUrl());
  socket.onopen = () => {
    if (myGeneration !== generation) return;
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
    if (myGeneration !== generation) return;
    handleMessage(JSON.parse(event.data as string) as ServerMessage);
  };
  socket.onclose = () => {
    if (myGeneration !== generation) return;
    useAppStore.getState().setConnection("closed");
    setTimeout(() => {
      if (myGeneration === generation) connect(sessionId);
    }, reconnectDelayMs);
    reconnectDelayMs = Math.min(reconnectDelayMs * 2, 10_000);
  };
}

async function fetchJson<T>(input: string, init?: RequestInit): Promise<T> {
  const response = await fetch(input, init);
  if (!response.ok) throw new Error(`${input}: ${await response.text()}`);
  return (await response.json()) as T;
}

async function findOrCreateSession(
  projectId: string | null,
  agentName: string | null,
): Promise<SessionMeta> {
  const query = projectId ? `?projectId=${encodeURIComponent(projectId)}` : "";
  const { sessions } = await fetchJson<{ sessions: SessionMeta[] }>(`/sessions${query}`);
  const scoped = (projectId ? sessions : sessions.filter((s) => !s.projectId)).filter(
    (s) => (s.agentName ?? null) === agentName,
  );
  const existing = scoped.at(-1);
  if (existing) return existing;
  const { session } = await fetchJson<{ session: SessionMeta }>("/sessions", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      ...(projectId ? { projectId } : {}),
      ...(agentName ? { agentName } : {}),
    }),
  });
  return session;
}

export async function refreshProjects(): Promise<void> {
  const { projects } = await fetchJson<{ projects: ProjectMeta[] }>("/projects");
  useAppStore.getState().setProjects(projects);
}

let activationToken = 0;

async function activateSession(projectId: string | null, agentName: string | null): Promise<void> {
  // Guards rapid switching: if another activation starts while this one's REST
  // call is in flight, the stale result must never win.
  const token = ++activationToken;
  const store = useAppStore.getState();
  try {
    store.setError(null);
    store.setCurrentProject(projectId);
    store.setCurrentAgent(agentName);
    store.resetTranscript();
    store.setSession(null);
    const session = await findOrCreateSession(projectId, agentName);
    if (token !== activationToken) return;
    useAppStore.getState().setSession(session);
    connect(session.id);
  } catch (error) {
    if (token !== activationToken) return;
    useAppStore.getState().setError(String(error));
  }
}

export async function switchToProject(projectId: string | null): Promise<void> {
  // Changing project activates its default agent (or the plain Pi Agent).
  const project = projectId
    ? useAppStore.getState().projects.find((p) => p.id === projectId)
    : undefined;
  await activateSession(projectId, project?.defaultAgentName ?? null);
}

export async function updateProject(
  projectId: string,
  patch: { assignedSkills?: string[]; defaultAgentName?: string | null },
): Promise<void> {
  const store = useAppStore.getState();
  // Optimistic: controlled inputs (assignment checkboxes) must flip
  // immediately; refreshProjects reconciles (or rolls back on error).
  store.setProjects(
    store.projects.map((project) =>
      project.id === projectId
        ? {
            ...project,
            ...(patch.assignedSkills !== undefined ? { assignedSkills: patch.assignedSkills } : {}),
            ...(patch.defaultAgentName !== undefined
              ? { defaultAgentName: patch.defaultAgentName ?? undefined }
              : {}),
          }
        : project,
    ),
  );
  try {
    const response = await fetch(`/projects/${encodeURIComponent(projectId)}`, {
      method: "PATCH",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(patch),
    });
    if (!response.ok) throw new Error(await response.text());
  } catch (error) {
    useAppStore.getState().setError(String(error));
  } finally {
    await refreshProjects();
  }
}

export async function switchToAgent(agentName: string | null): Promise<void> {
  await activateSession(useAppStore.getState().currentProjectId, agentName);
}

export async function addProject(path: string): Promise<void> {
  const store = useAppStore.getState();
  try {
    const { project } = await fetchJson<{ project: ProjectMeta }>("/projects", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ path }),
    });
    await refreshProjects();
    await switchToProject(project.id);
  } catch (error) {
    store.setError(String(error));
  }
}

export async function connectAndBootstrap(): Promise<void> {
  try {
    await refreshProjects();
    await switchToProject(null);
  } catch (error) {
    useAppStore.getState().setError(String(error));
  }
}

export function sendPrompt(message: string): void {
  if (currentSessionId) send({ type: "prompt", sessionId: currentSessionId, message });
}

export function sendAbort(): void {
  if (currentSessionId) send({ type: "abort", sessionId: currentSessionId });
}

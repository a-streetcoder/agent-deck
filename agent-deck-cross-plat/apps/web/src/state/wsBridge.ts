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
    case "session_meta":
      store.upsertSessionMeta(message.session);
      break;
    case "session_removed":
      store.removeSession(message.sessionId);
      // If ANOTHER client deleted the session we're viewing, drop it and open
      // a fresh chat so we're not pointing at (or subscribed to) a dead id.
      if (useAppStore.getState().session?.id === message.sessionId) {
        void newChat();
      }
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

export async function refreshSessions(): Promise<void> {
  const { sessions } = await fetchJson<{ sessions: SessionMeta[] }>("/sessions");
  useAppStore.getState().setSessions(sessions);
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
    await refreshSessions();
  } catch (error) {
    if (token !== activationToken) return;
    useAppStore.getState().setError(String(error));
  }
}

/** Open a specific chat, resuming its pi session if it has ended. */
export async function switchToSession(target: SessionMeta): Promise<void> {
  const token = ++activationToken;
  const store = useAppStore.getState();
  try {
    store.setError(null);
    store.setCurrentProject(target.projectId ?? null);
    store.setCurrentAgent(target.agentName ?? null);
    store.resetTranscript();
    store.setSession(null);
    const { session } = await fetchJson<{ session: SessionMeta }>(
      `/sessions/${encodeURIComponent(target.id)}/resume`,
      { method: "POST" },
    );
    if (token !== activationToken) return;
    useAppStore.getState().setSession(session);
    connect(session.id);
    await refreshSessions();
  } catch (error) {
    if (token !== activationToken) return;
    useAppStore.getState().setError(String(error));
  }
}

/** Start a brand-new chat for the current project + agent. */
export async function newChat(): Promise<void> {
  const token = ++activationToken;
  const store = useAppStore.getState();
  const { currentProjectId, currentAgentName } = store;
  try {
    store.setError(null);
    store.resetTranscript();
    store.setSession(null);
    const { session } = await fetchJson<{ session: SessionMeta }>("/sessions", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        ...(currentProjectId ? { projectId: currentProjectId } : {}),
        ...(currentAgentName ? { agentName: currentAgentName } : {}),
      }),
    });
    if (token !== activationToken) return;
    useAppStore.getState().setSession(session);
    connect(session.id);
    await refreshSessions();
  } catch (error) {
    if (token !== activationToken) return;
    useAppStore.getState().setError(String(error));
  }
}

export async function renameSession(sessionId: string, title: string): Promise<void> {
  try {
    const response = await fetch(`/sessions/${encodeURIComponent(sessionId)}`, {
      method: "PATCH",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ title }),
    });
    if (!response.ok) throw new Error(await response.text());
    await refreshSessions();
  } catch (error) {
    useAppStore.getState().setError(String(error));
  }
}

export async function deleteSession(sessionId: string): Promise<void> {
  try {
    const response = await fetch(`/sessions/${encodeURIComponent(sessionId)}`, {
      method: "DELETE",
    });
    if (!response.ok) throw new Error(await response.text());
    // If the deleted session was open, fall back to a new chat.
    if (useAppStore.getState().session?.id === sessionId) {
      await newChat();
    }
    await refreshSessions();
  } catch (error) {
    useAppStore.getState().setError(String(error));
  }
}

export async function forkSession(sessionId: string): Promise<void> {
  try {
    const response = await fetch(`/sessions/${encodeURIComponent(sessionId)}/fork`, {
      method: "POST",
    });
    if (!response.ok) throw new Error(await response.text());
    const { session } = (await response.json()) as { session: SessionMeta };
    await refreshSessions();
    await switchToSession(session);
  } catch (error) {
    useAppStore.getState().setError(String(error));
  }
}

async function resourceAction(input: string, init: RequestInit): Promise<void> {
  try {
    const response = await fetch(input, init);
    if (!response.ok) throw new Error(await response.text());
  } catch (error) {
    useAppStore.getState().setError(String(error));
  }
}

export async function setAgentDisabled(
  scope: string,
  name: string,
  disabled: boolean,
): Promise<void> {
  const projectId = useAppStore.getState().currentProjectId ?? undefined;
  await resourceAction("/resources/agents/disabled", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ projectId, scope, name, disabled }),
  });
}

export async function deleteAgent(scope: string, name: string): Promise<void> {
  const projectId = useAppStore.getState().currentProjectId ?? undefined;
  await resourceAction("/resources/agents", {
    method: "DELETE",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ projectId, scope, name }),
  });
}

export async function setSkillDisabled(name: string, disabled: boolean): Promise<void> {
  await resourceAction("/settings", {
    method: "PATCH",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ setDisabledSkill: { name, disabled } }),
  });
}

export async function deleteSkill(scope: string, name: string): Promise<void> {
  const projectId = useAppStore.getState().currentProjectId ?? undefined;
  await resourceAction("/resources/skills", {
    method: "DELETE",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ projectId, scope, name }),
  });
}

/** Answer a question card. */
export function sendUiResponse(requestId: string, response: Record<string, unknown>): void {
  if (currentSessionId) {
    send({
      type: "ui_response",
      sessionId: currentSessionId,
      response: { type: "extension_ui_response", id: requestId, ...response },
    });
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
  patch: { assignedSkills?: string[]; defaultAgentName?: string | null; enabled?: boolean },
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
            ...(patch.enabled !== undefined ? { enabled: patch.enabled } : {}),
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

export function sendSetModel(provider: string, modelId: string): void {
  if (currentSessionId) {
    send({ type: "set_model", sessionId: currentSessionId, provider, modelId });
  }
}

export function sendSetThinking(
  level: "off" | "minimal" | "low" | "medium" | "high" | "xhigh",
): void {
  if (currentSessionId) send({ type: "set_thinking", sessionId: currentSessionId, level });
}

import type {
  ClientMessage,
  ProjectMeta,
  ServerMessage,
  SessionMeta,
  TerminalPush,
} from "@agent-deck/contracts";
import { reduceTranscript } from "@agent-deck/domain";
import type { TerminalOpenResult } from "@agent-deck/client-runtime";
import { RpcClientTransport, type ClientTransport, type TransportHost } from "./clientTransport.ts";
import { useAppStore } from "./store.ts";

/**
 * The ONLY module that touches the WebSocket. Server messages mutate the
 * zustand store through the shared domain reducer; UI components send
 * commands exclusively through the exported functions below.
 *
 * One socket, one subscribed session at a time: switching project closes the
 * socket and reconnects subscribed to that project's session.
 *
 * The socket mechanism itself lives behind a {@link ClientTransport} (see
 * clientTransport.ts): the Effect-RPC `/rpc` transport (the legacy `/ws` envelope
 * was retired in Slice 7c). This module owns the shared reducer/host; the
 * transport owns framing + reconnect.
 */

let currentSessionId: string | null = null;

const transportHost: TransportHost = {
  onServerMessage: (message) => handleMessage(message),
  setConnection: (status) => {
    // Terminals are owned by the server-side RPC connection: any drop kills
    // their PTYs, so every remembered terminal id dies with the socket.
    if (status !== "open") sessionTerminals.clear();
    useAppStore.getState().setConnection(status);
  },
  getLastSeq: () => useAppStore.getState().lastSeq,
  onTerminalPush: (message) => {
    for (const listener of terminalPushListeners) listener(message);
  },
  // Slice 10: a turn boundary refreshed the session's changed-file set. The
  // push is broadcast per connection and carries its sessionId — only the
  // subscribed session's set drives the store (same filter as event pushes).
  onDiffPush: (message) => {
    if (message.sessionId !== currentSessionId) return;
    useAppStore.getState().setDiffState(message);
  },
  // Fired after every (re)subscription settles: fetch the freshly-subscribed
  // session's set (a session switch dropped the old one; a reconnect may have
  // missed pushes while down).
  onSessionSubscribed: (sessionId) => {
    void refreshDiffFiles(sessionId);
  },
};

const transport: ClientTransport = new RpcClientTransport(transportHost);

// ---------------------------------------------------------------------------
// Terminal drawer surface (Slice 8b) — ported from t3code's terminal state
// wiring (MIT), re-expressed over our RPC transport: the drawer opens a
// terminal for the CURRENT session, the server remembers it per connection,
// and reopening the drawer reattaches by id to replay the scrollback.
// ---------------------------------------------------------------------------

/** Terminal ids the server allocated for this connection, per session. */
const sessionTerminals = new Map<string, string>();
/** In-flight opens, per session: a drawer close+reopen before the first open
 * resolves must JOIN it, not race a second terminal_open (last-writer-wins
 * would leave the first PTY streaming to a filtered-out listener). */
const pendingOpens = new Map<string, Promise<TerminalOpenResult & { sessionId: string }>>();
const terminalPushListeners = new Set<(message: TerminalPush) => void>();

/** Subscribe to terminal pushes (output/exit). Returns the unsubscriber. */
export function subscribeTerminalPush(listener: (message: TerminalPush) => void): () => void {
  terminalPushListeners.add(listener);
  return () => terminalPushListeners.delete(listener);
}

/**
 * Open the current session's terminal — reattaching to the one this connection
 * already opened (scrollback replays), or spawning a fresh PTY in the session's
 * cwd. A stale remembered id (e.g. the session exited and took its terminals
 * down) falls back to a fresh open.
 */
export async function openSessionTerminal(
  cols?: number,
  rows?: number,
): Promise<TerminalOpenResult & { sessionId: string }> {
  const sessionId = currentSessionId;
  if (!sessionId) throw new Error("no active session");
  const inFlight = pendingOpens.get(sessionId);
  if (inFlight) return await inFlight;
  const task = doOpenSessionTerminal(sessionId, cols, rows);
  pendingOpens.set(sessionId, task);
  try {
    return await task;
  } finally {
    pendingOpens.delete(sessionId);
  }
}

async function doOpenSessionTerminal(
  sessionId: string,
  cols?: number,
  rows?: number,
): Promise<TerminalOpenResult & { sessionId: string }> {
  const size = {
    ...(cols !== undefined ? { cols } : {}),
    ...(rows !== undefined ? { rows } : {}),
  };
  const known = sessionTerminals.get(sessionId);
  try {
    const result = await transport.openTerminal({
      sessionId,
      ...(known !== undefined ? { terminalId: known } : {}),
      ...size,
    });
    sessionTerminals.set(sessionId, result.terminalId);
    return { ...result, sessionId };
  } catch (error) {
    if (known === undefined) throw error;
    sessionTerminals.delete(sessionId);
    const result = await transport.openTerminal({ sessionId, ...size });
    sessionTerminals.set(sessionId, result.terminalId);
    return { ...result, sessionId };
  }
}

export function sendTerminalInput(terminalId: string, data: string): void {
  transport.sendTerminal({ type: "terminal_input", terminalId, data });
}

export function sendTerminalResize(terminalId: string, cols: number, rows: number): void {
  transport.sendTerminal({ type: "terminal_resize", terminalId, cols, rows });
}

/** Kill the current session's terminal (the PTY dies; the next open is fresh). */
export function closeSessionTerminal(sessionId: string): void {
  const terminalId = sessionTerminals.get(sessionId);
  if (terminalId === undefined) return;
  sessionTerminals.delete(sessionId);
  transport.sendTerminal({ type: "terminal_close", terminalId });
}

// ---------------------------------------------------------------------------
// Changed-files surface (Slice 10) — the session's diff set lives in the store
// and is kept fresh two ways: diff_push at turn boundaries (onDiffPush above)
// and an explicit fetch on every (re)subscription (onSessionSubscribed).
// ---------------------------------------------------------------------------

/** Fetch `sessionId`'s changed-file set into the store (if still current). */
async function refreshDiffFiles(sessionId: string): Promise<void> {
  try {
    const result = await transport.diffFiles(sessionId);
    if (sessionId !== currentSessionId) return; // switched away mid-flight
    useAppStore.getState().setDiffState(result);
  } catch {
    // Offline or a torn-down session: leave the (reset) state alone — the
    // next subscription refetches. Never worth the error banner.
  }
}

/** Fetch one changed file's unified diff for the CURRENT session. */
export async function fetchFileDiff(
  path: string,
): Promise<{ diff: string; truncated: boolean; binary: boolean } | null> {
  const sessionId = currentSessionId;
  if (!sessionId) return null;
  const result = await transport.diffFile(sessionId, path);
  return { diff: result.diff, truncated: result.truncated, binary: result.binary };
}

/** (Re)connect subscribed to `sessionId` — the single entry point that keeps
 * `currentSessionId` (which gates handleMessage's per-session filtering) in sync
 * with the transport's subscription. */
function connect(sessionId: string): void {
  currentSessionId = sessionId;
  // The old session's changed-file set must not bleed into the new one; the
  // fresh set arrives via onSessionSubscribed once the subscription settles.
  useAppStore.getState().resetDiffState();
  transport.connect(sessionId);
}

function send(message: ClientMessage): void {
  transport.send(message);
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
      // Its terminals died server-side with the session (rpcHandler teardown).
      sessionTerminals.delete(message.sessionId);
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

/** Rename a global/project agent; returns true on success (the caller closes
 *  the inline editor), false after surfacing the server error (409/404/…). */
export async function renameAgent(scope: string, name: string, newName: string): Promise<boolean> {
  const projectId = useAppStore.getState().currentProjectId ?? undefined;
  try {
    const response = await fetch("/resources/agents/rename", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ projectId, scope, name, newName }),
    });
    if (!response.ok) {
      const { error } = (await response.json().catch(() => ({}))) as { error?: string };
      throw new Error(error ?? "Couldn't rename the agent.");
    }
    return true;
  } catch (error) {
    useAppStore.getState().setError(String(error));
    return false;
  }
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

/** Rename a global/project skill; returns true on success (the caller closes
 *  the inline editor), false after surfacing the server error (409/404/…). */
export async function renameSkill(scope: string, name: string, newName: string): Promise<boolean> {
  const projectId = useAppStore.getState().currentProjectId ?? undefined;
  try {
    const response = await fetch("/resources/skills/rename", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ projectId, scope, name, newName }),
    });
    if (!response.ok) {
      const { error } = (await response.json().catch(() => ({}))) as { error?: string };
      throw new Error(error ?? "Couldn't rename the skill.");
    }
    return true;
  } catch (error) {
    useAppStore.getState().setError(String(error));
    return false;
  }
}

/** Answer a blocking supervisor-request card raised by a child subagent. */
export async function sendSupervisorAnswer(requestId: string, response: string): Promise<void> {
  await fetch(`/supervisor/${encodeURIComponent(requestId)}/answer`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ response }),
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
  patch: {
    assignedSkills?: string[];
    assignedPrompts?: string[];
    defaultAgentName?: string | null;
    enabled?: boolean;
  },
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
            ...(patch.assignedPrompts !== undefined
              ? { assignedPrompts: patch.assignedPrompts }
              : {}),
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

export interface ImageAttachment {
  type: "image";
  data: string;
  mimeType: string;
}

export function sendPrompt(message: string, images?: ImageAttachment[]): void {
  if (currentSessionId) {
    send({
      type: "prompt",
      sessionId: currentSessionId,
      message,
      ...(images && images.length > 0 ? { images } : {}),
    });
  }
}

export function sendAbort(): void {
  if (currentSessionId) send({ type: "abort", sessionId: currentSessionId });
}

/** Manually compact the current session's context (native "Compact context"). */
export function sendCompact(): void {
  if (currentSessionId) send({ type: "compact", sessionId: currentSessionId });
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

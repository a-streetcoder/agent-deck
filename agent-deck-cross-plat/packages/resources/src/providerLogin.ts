import { randomUUID } from "node:crypto";
import path from "node:path";
import { AuthStorage } from "@earendil-works/pi-coding-agent";
import { piAgentHome, type ResourceRoots } from "./paths.ts";

/**
 * Interactive provider OAuth login (native PiProviderLoginService). pi's
 * AuthStorage.login(providerId, callbacks) is a MULTI-STEP interactive flow —
 * it opens a browser URL / shows a device code, may prompt for input or a
 * choice, streams progress, and persists to auth.json on success. This manager
 * turns that push/pull protocol into a pollable session: callback notifications
 * become queued events, and an onPrompt/onSelect parks the flow until the client
 * responds. The AuthStorage.login call is injected so the relay is testable
 * without a real provider.
 */

export type LoginEvent =
  | { type: "auth_url"; url: string; instructions?: string }
  | { type: "device_code"; userCode: string; verificationUri: string; expiresInSeconds?: number }
  | { type: "prompt"; message: string; placeholder?: string }
  | { type: "select"; message: string; options: Array<{ id: string; label: string }> }
  | { type: "progress"; message: string }
  | { type: "done"; ok: boolean; error?: string };

export type LoginStatus = "running" | "done" | "error";

/** Mirrors pi's OAuthLoginCallbacks (pi-ai/compat isn't directly importable here). */
export interface ProviderLoginCallbacks {
  onAuth: (info: { url: string; instructions?: string }) => void;
  onDeviceCode: (info: {
    userCode: string;
    verificationUri: string;
    intervalSeconds?: number;
    expiresInSeconds?: number;
  }) => void;
  onPrompt: (prompt: {
    message: string;
    placeholder?: string;
    allowEmpty?: boolean;
  }) => Promise<string>;
  /** Fallback for callback-server providers: enter the code by hand. */
  onManualCodeInput?: () => Promise<string>;
  onProgress?: (message: string) => void;
  onSelect: (prompt: {
    message: string;
    options: Array<{ id: string; label: string }>;
  }) => Promise<string | undefined>;
  signal?: AbortSignal;
}

export type ProviderLoginFn = (
  authPath: string,
  providerId: string,
  callbacks: ProviderLoginCallbacks,
) => Promise<void>;

const realLoginFn: ProviderLoginFn = (authPath, providerId, callbacks) =>
  // The structural shape matches OAuthLoginCallbacks; the cast bridges the
  // un-importable pi-ai type without loosening our own surface.
  AuthStorage.create(authPath).login(providerId, callbacks as Parameters<AuthStorage["login"]>[1]);

interface LoginState {
  events: LoginEvent[];
  /** Resolver for the currently-awaited onPrompt/onSelect, else null. */
  pending: ((value: string | undefined) => void) | null;
  status: LoginStatus;
  abort: AbortController;
  finishedAt?: number;
}

const MAX_RETAINED = 20;
const TERMINAL_TTL_MS = 5 * 60_000;

export class ProviderLoginManager {
  private readonly sessions = new Map<string, LoginState>();
  private readonly loginFn: ProviderLoginFn;

  constructor(loginFn: ProviderLoginFn = realLoginFn) {
    this.loginFn = loginFn;
  }

  /** Begin a login; returns the id to poll/respond against. */
  start(roots: ResourceRoots, providerId: string): string {
    this.evictOld();
    const loginId = randomUUID();
    const abort = new AbortController();
    const state: LoginState = { events: [], pending: null, status: "running", abort };
    this.sessions.set(loginId, state);

    const callbacks: ProviderLoginCallbacks = {
      onAuth: (info) => {
        state.events.push({ type: "auth_url", url: info.url, instructions: info.instructions });
      },
      onDeviceCode: (info) => {
        state.events.push({
          type: "device_code",
          userCode: info.userCode,
          verificationUri: info.verificationUri,
          expiresInSeconds: info.expiresInSeconds,
        });
      },
      onProgress: (message) => {
        state.events.push({ type: "progress", message });
      },
      onManualCodeInput: () =>
        new Promise<string>((resolve) => {
          state.events.push({
            type: "prompt",
            message: "Paste the authorization code from your browser",
          });
          state.pending = (value) => resolve(value ?? "");
        }),
      onPrompt: (prompt) =>
        new Promise<string>((resolve) => {
          state.events.push({
            type: "prompt",
            message: prompt.message,
            placeholder: prompt.placeholder,
          });
          state.pending = (value) => resolve(value ?? "");
        }),
      onSelect: (prompt) =>
        new Promise<string | undefined>((resolve) => {
          state.events.push({
            type: "select",
            message: prompt.message,
            options: prompt.options.map((o) => ({ id: o.id, label: o.label })),
          });
          state.pending = (value) => resolve(value);
        }),
      signal: abort.signal,
    };

    const authPath = path.join(piAgentHome(roots), "auth.json");
    void this.loginFn(authPath, providerId, callbacks)
      .then(() => {
        state.status = "done";
        state.events.push({ type: "done", ok: true });
        state.finishedAt = Date.now();
      })
      .catch((error) => {
        state.status = "error";
        state.events.push({
          type: "done",
          ok: false,
          error: error instanceof Error ? error.message : String(error),
        });
        state.finishedAt = Date.now();
      });
    return loginId;
  }

  /** Events after `since` (a cursor), the current status, and the next cursor. */
  poll(
    loginId: string,
    since: number,
  ): { events: LoginEvent[]; status: LoginStatus; nextCursor: number } | undefined {
    const state = this.sessions.get(loginId);
    if (!state) return undefined;
    const from = Math.max(0, since);
    return {
      events: state.events.slice(from),
      status: state.status,
      nextCursor: state.events.length,
    };
  }

  /** Resolve the awaited prompt/select. Returns false if nothing is pending. */
  respond(loginId: string, value: string | undefined): boolean {
    const state = this.sessions.get(loginId);
    if (!state || !state.pending) return false;
    const resolve = state.pending;
    state.pending = null;
    resolve(value);
    return true;
  }

  /** Abort the flow (native cancel). Unblocks a pending prompt so login() unwinds. */
  cancel(loginId: string): void {
    const state = this.sessions.get(loginId);
    if (!state) return;
    state.abort.abort();
    if (state.pending) {
      const resolve = state.pending;
      state.pending = null;
      resolve(undefined);
    }
  }

  private evictOld(): void {
    const now = Date.now();
    for (const [id, state] of this.sessions) {
      if (state.finishedAt && now - state.finishedAt > TERMINAL_TTL_MS) this.sessions.delete(id);
    }
    if (this.sessions.size < MAX_RETAINED) return;
    for (const [id, state] of this.sessions) {
      if (this.sessions.size < MAX_RETAINED) break;
      if (state.status !== "running") this.sessions.delete(id);
    }
  }
}

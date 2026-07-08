import { useCallback, useEffect, useRef, useState } from "react";
import { LogIn, LogOut, Plus, RefreshCw, Server, Trash2 } from "lucide-react";
import { cn } from "@/lib/cn";
import { useAppStore } from "../state/store.ts";

/**
 * MCP screen (native Runtime → MCP): the configured MCP servers whose tools are
 * proxied into pi sessions over the bridge. Each row shows live connection
 * status + the tools that connected; add a stdio server, refresh, or remove it.
 * An http server behind OAuth also gets a Sign-in flow (native MCPOAuthService):
 * begin → open the authorization link → paste the redirect's code → connected.
 */

interface McpAuth {
  status: "none" | "unauthenticated" | "authorizing" | "authorized" | "error";
  authUrl?: string;
  error?: string;
}

interface McpServer {
  id: string;
  transport: "stdio" | "http";
  connected: boolean;
  toolNames: string[];
  error?: string;
  auth?: McpAuth;
}

/** In-progress sign-in: the server + the authorization URL to open, and the
 *  OAuth `state` parsed from it (echoed back on the callback for CSRF). */
interface LoginFlow {
  id: string;
  authUrl: string;
  state: string;
}

/** Extract the `code` (+ `state`) the user pastes back — either a bare code or
 *  the full redirect URL they landed on. Falls back to the flow's own state. */
function parseCallback(input: string, fallbackState: string): { code: string; state: string } {
  const trimmed = input.trim();
  try {
    const url = new URL(trimmed);
    return {
      code: url.searchParams.get("code") ?? "",
      state: url.searchParams.get("state") ?? fallbackState,
    };
  } catch {
    return { code: trimmed, state: fallbackState };
  }
}

export function McpScreen() {
  const setError = useAppStore((state) => state.setError);
  const pushToast = useAppStore((state) => state.pushToast);
  const resourcesVersion = useAppStore((state) => state.resourcesVersion);
  const [servers, setServers] = useState<McpServer[]>([]);
  const [adding, setAdding] = useState(false);
  const [name, setName] = useState("");
  const [command, setCommand] = useState("");
  const [login, setLogin] = useState<LoginFlow | null>(null);
  const [code, setCode] = useState("");
  const loadSeq = useRef(0);
  // Bumped whenever a sign-in flow starts, so a slow /login (or /callback) for one
  // server can't clobber a newer flow the user has since started for another.
  const loginSeq = useRef(0);

  const load = useCallback(async (): Promise<void> => {
    const seq = ++loadSeq.current;
    try {
      const response = await fetch("/mcp");
      if (!response.ok) throw new Error(await response.text());
      const data = (await response.json()) as { servers: McpServer[] };
      if (seq === loadSeq.current) setServers(data.servers);
    } catch (err) {
      if (seq === loadSeq.current) setError(String(err));
    }
  }, [setError]);

  useEffect(() => {
    void load();
  }, [load, resourcesVersion]);

  const add = async (): Promise<void> => {
    const trimmedName = name.trim();
    const parts = command.trim().split(/\s+/).filter(Boolean);
    if (!trimmedName || parts.length === 0) return;
    const [cmd, ...args] = parts;
    try {
      const response = await fetch("/mcp", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ name: trimmedName, command: cmd, args }),
      });
      if (!response.ok) throw new Error(await response.text());
      setName("");
      setCommand("");
      setAdding(false);
      await load();
    } catch (err) {
      setError(String(err));
    }
  };

  const refresh = async (id: string): Promise<void> => {
    try {
      const response = await fetch(`/mcp/${encodeURIComponent(id)}/refresh`, { method: "POST" });
      if (!response.ok) throw new Error(await response.text());
    } catch (err) {
      setError(String(err));
    }
    await load();
  };

  const remove = async (id: string): Promise<void> => {
    try {
      const response = await fetch(`/mcp/${encodeURIComponent(id)}`, { method: "DELETE" });
      if (!response.ok) throw new Error(await response.text());
    } catch (err) {
      setError(String(err));
    }
    await load();
  };

  // Begin OAuth: ask the server for the authorization URL, then show the
  // open-link + paste-code panel. The `state` is parsed from the URL and echoed
  // back on the callback for CSRF verification.
  const beginLogin = async (id: string): Promise<void> => {
    const seq = ++loginSeq.current;
    setCode("");
    try {
      const response = await fetch(`/mcp/${encodeURIComponent(id)}/login`, { method: "POST" });
      if (!response.ok) throw new Error(await response.text());
      const { auth } = (await response.json()) as { auth: McpAuth };
      if (!auth.authUrl) throw new Error("no authorization URL returned");
      const state = new URL(auth.authUrl).searchParams.get("state") ?? "";
      // Ignore a stale response if the user has since started another flow.
      if (seq === loginSeq.current) setLogin({ id, authUrl: auth.authUrl, state });
    } catch (err) {
      if (seq === loginSeq.current) setError(String(err));
    }
  };

  // Complete OAuth with the pasted code (or redirect URL) → the server exchanges
  // it and reconnects, so the server's tools register.
  const submitCode = async (): Promise<void> => {
    const flow = login;
    if (!flow) return;
    const seq = loginSeq.current;
    const { code: parsedCode, state } = parseCallback(code, flow.state);
    if (!parsedCode) return;
    try {
      const response = await fetch(`/mcp/${encodeURIComponent(flow.id)}/login/callback`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ code: parsedCode, state }),
      });
      if (!response.ok) throw new Error(await response.text());
      pushToast({ kind: "success", message: `Signed in to ${flow.id}` });
      // Only close/clear the panel if the user hasn't since started another flow.
      if (seq === loginSeq.current) {
        setLogin(null);
        setCode("");
      }
      await load();
    } catch (err) {
      setError(String(err));
    }
  };

  const logout = async (id: string): Promise<void> => {
    try {
      const response = await fetch(`/mcp/${encodeURIComponent(id)}/logout`, { method: "POST" });
      if (!response.ok) throw new Error(await response.text());
    } catch (err) {
      setError(String(err));
    }
    await load();
  };

  return (
    <div className="min-h-0 flex-1 overflow-y-auto px-6 py-5" data-testid="mcp-screen">
      <div className="mx-auto max-w-3xl">
        <div className="flex items-center justify-between pb-1">
          <div className="flex items-center gap-2">
            <Server size={16} className="text-text-secondary" aria-hidden />
            <h2
              className="text-base font-semibold text-text-primary"
              style={{ fontStretch: "expanded" }}
            >
              MCP servers
            </h2>
          </div>
          <button
            data-testid="mcp-add"
            className="flex items-center gap-1.5 rounded-capsule px-3 py-1 text-xs font-medium shadow-capsule"
            style={{
              background:
                "linear-gradient(180deg, var(--color-brand-accent-bright), var(--color-brand-accent))",
              color: "var(--color-accent-foreground)",
            }}
            onClick={() => setAdding((v) => !v)}
          >
            <Plus size={13} /> Add server
          </button>
        </div>
        <p className="pb-3 text-xs text-text-muted">
          Model Context Protocol servers whose tools are proxied into every session as{" "}
          <code className="font-mono">mcp__&lt;server&gt;__&lt;tool&gt;</code>. Stdio transport.
        </p>

        {adding ? (
          <div className="mb-3 flex flex-col gap-2" data-testid="mcp-add-form">
            <input
              autoFocus
              data-testid="mcp-name"
              className="rounded-lg border border-border-strong bg-surface px-2.5 py-1.5 text-sm text-text-primary outline-none focus:border-accent"
              placeholder="name (e.g. filesystem)"
              value={name}
              onChange={(e) => setName(e.target.value)}
            />
            <div className="flex gap-2">
              <input
                data-testid="mcp-command"
                className="min-w-0 flex-1 rounded-lg border border-border-strong bg-surface px-2.5 py-1.5 font-mono text-xs text-text-primary outline-none focus:border-accent"
                placeholder="command with args (e.g. npx -y @modelcontextprotocol/server-filesystem /tmp)"
                value={command}
                onChange={(e) => setCommand(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === "Enter") void add();
                  if (e.key === "Escape") setAdding(false);
                }}
              />
              <button
                data-testid="mcp-add-confirm"
                className="rounded-capsule px-3 py-1.5 text-xs font-medium shadow-capsule disabled:opacity-40"
                style={{
                  background:
                    "linear-gradient(180deg, var(--color-brand-accent-bright), var(--color-brand-accent))",
                  color: "var(--color-accent-foreground)",
                }}
                disabled={!name.trim() || !command.trim()}
                onClick={() => void add()}
              >
                Add
              </button>
            </div>
          </div>
        ) : null}

        <div className="space-y-1.5" data-testid="mcp-list">
          {servers.map((server) => (
            <div key={server.id}>
              <div
                data-testid={`mcp-${server.id}`}
                data-connected={server.connected ? "true" : "false"}
                className="flex items-center gap-3 rounded-[14px] border border-border-subtle bg-surface px-3.5 py-2.5"
              >
                <div className="min-w-0 flex-1">
                  <div className="flex items-center gap-2">
                    <span
                      className="truncate text-sm font-medium text-text-primary"
                      style={{ fontStretch: "expanded" }}
                    >
                      {server.id}
                    </span>
                    <span
                      data-testid={`mcp-status-${server.id}`}
                      className={cn(
                        "rounded-capsule border px-1.5 text-[10px]",
                        server.connected
                          ? "border-[var(--color-success)] text-[var(--color-success)]"
                          : "border-[var(--color-role-error)] text-[var(--color-role-error)]",
                      )}
                    >
                      {server.connected ? "connected" : "disconnected"}
                    </span>
                    <span className="rounded-capsule border border-border-subtle px-1.5 text-[10px] text-text-muted">
                      {server.transport}
                    </span>
                    {server.transport === "http" && server.auth && server.auth.status !== "none" ? (
                      <span
                        data-testid={`mcp-auth-${server.id}`}
                        data-auth={server.auth.status}
                        className={cn(
                          "rounded-capsule border px-1.5 text-[10px]",
                          server.auth.status === "authorized"
                            ? "border-[var(--color-success)] text-[var(--color-success)]"
                            : "border-border-subtle text-text-muted",
                        )}
                      >
                        {server.auth.status === "authorized" ? "signed in" : "sign-in required"}
                      </span>
                    ) : null}
                    <span className="text-[11px] text-text-muted">
                      {server.toolNames.length} tool{server.toolNames.length === 1 ? "" : "s"}
                    </span>
                  </div>
                  {server.error ? (
                    <div className="truncate text-[11px] text-[var(--color-role-error)]">
                      {server.error}
                    </div>
                  ) : server.toolNames.length > 0 ? (
                    <div className="truncate font-mono text-[11px] text-text-muted">
                      {server.toolNames.join(", ")}
                    </div>
                  ) : null}
                </div>
                {server.transport === "http" && server.auth && server.auth.status !== "none" ? (
                  server.auth.status === "authorized" ? (
                    <button
                      data-testid={`mcp-logout-${server.id}`}
                      className="rounded p-1 text-text-muted hover:text-[var(--color-role-error)]"
                      title="Sign out"
                      onClick={() => void logout(server.id)}
                    >
                      <LogOut size={13} />
                    </button>
                  ) : (
                    <button
                      data-testid={`mcp-login-${server.id}`}
                      className="flex items-center gap-1 rounded-capsule px-2 py-1 text-[11px] font-medium text-accent hover:bg-surface-hover"
                      title="Sign in"
                      onClick={() => void beginLogin(server.id)}
                    >
                      <LogIn size={12} /> Sign in
                    </button>
                  )
                ) : null}
                <button
                  data-testid={`mcp-refresh-${server.id}`}
                  className="rounded p-1 text-text-muted hover:text-accent"
                  title="Reconnect"
                  onClick={() => void refresh(server.id)}
                >
                  <RefreshCw size={13} />
                </button>
                <button
                  data-testid={`mcp-remove-${server.id}`}
                  className="rounded p-1 text-text-muted hover:text-[var(--color-role-error)]"
                  title="Remove"
                  onClick={() => {
                    if (
                      confirm(
                        `Remove MCP server "${server.id}"? This clears its project and agent assignments.`,
                      )
                    ) {
                      void remove(server.id);
                    }
                  }}
                >
                  <Trash2 size={13} />
                </button>
              </div>
              {login?.id === server.id ? (
                <div
                  data-testid={`mcp-login-panel-${server.id}`}
                  className="mt-1 flex flex-col gap-2 rounded-[14px] border border-border-subtle bg-surface-subtle px-3.5 py-3"
                >
                  <div className="text-[11px] text-text-muted">
                    1. Open the authorization page and approve access:
                  </div>
                  <a
                    data-testid={`mcp-login-url-${server.id}`}
                    href={login.authUrl}
                    target="_blank"
                    rel="noreferrer"
                    className="truncate font-mono text-[11px] text-accent underline"
                  >
                    {login.authUrl}
                  </a>
                  <div className="text-[11px] text-text-muted">
                    2. Paste the code you were shown (or the full redirect URL):
                  </div>
                  <div className="flex gap-2">
                    <input
                      autoFocus
                      data-testid={`mcp-login-code-${server.id}`}
                      className="min-w-0 flex-1 rounded-lg border border-border-strong bg-surface px-2.5 py-1.5 font-mono text-xs text-text-primary outline-none focus:border-accent"
                      placeholder="authorization code"
                      value={code}
                      onChange={(e) => setCode(e.target.value)}
                      onKeyDown={(e) => {
                        if (e.key === "Enter") void submitCode();
                        if (e.key === "Escape") setLogin(null);
                      }}
                    />
                    <button
                      data-testid={`mcp-login-submit-${server.id}`}
                      className="rounded-capsule px-3 py-1.5 text-xs font-medium shadow-capsule disabled:opacity-40"
                      style={{
                        background:
                          "linear-gradient(180deg, var(--color-brand-accent-bright), var(--color-brand-accent))",
                        color: "var(--color-accent-foreground)",
                      }}
                      disabled={!code.trim()}
                      onClick={() => void submitCode()}
                    >
                      Connect
                    </button>
                    <button
                      data-testid={`mcp-login-cancel-${server.id}`}
                      className="rounded-capsule px-2 py-1.5 text-xs text-text-muted hover:text-text-primary"
                      onClick={() => setLogin(null)}
                    >
                      Cancel
                    </button>
                  </div>
                </div>
              ) : null}
            </div>
          ))}
          {servers.length === 0 && !adding ? (
            <div className="py-8 text-center text-sm text-text-muted" data-testid="mcp-empty">
              No MCP servers. Add one to proxy its tools into your sessions.
            </div>
          ) : null}
        </div>
      </div>
    </div>
  );
}

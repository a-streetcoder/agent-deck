import { useCallback, useEffect, useRef, useState } from "react";
import { Plus, RefreshCw, Server, Trash2 } from "lucide-react";
import { cn } from "@/lib/cn";
import { useAppStore } from "../state/store.ts";

/**
 * MCP screen (native Runtime → MCP): the configured MCP servers whose tools are
 * proxied into pi sessions over the bridge. Each row shows live connection
 * status + the tools that connected; add a stdio server, refresh, or remove it.
 */

interface McpServer {
  id: string;
  transport: "stdio" | "http";
  connected: boolean;
  toolNames: string[];
  error?: string;
}

export function McpScreen() {
  const setError = useAppStore((state) => state.setError);
  const resourcesVersion = useAppStore((state) => state.resourcesVersion);
  const [servers, setServers] = useState<McpServer[]>([]);
  const [adding, setAdding] = useState(false);
  const [name, setName] = useState("");
  const [command, setCommand] = useState("");
  const loadSeq = useRef(0);

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
            <div
              key={server.id}
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

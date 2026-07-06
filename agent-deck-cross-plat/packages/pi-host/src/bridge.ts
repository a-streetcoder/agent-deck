import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

/**
 * The generated bridge extension: the shared substrate under the native
 * Memory, MCP-proxy, and subagent features. Each of those is, mechanically,
 * "expose an app-managed tool to pi and route its calls back to the app."
 *
 * pi's extension API runs a tool's execute() INSIDE the pi process, so a
 * generated extension can HTTP-POST every call back to our server on
 * 127.0.0.1 and return the response as the tool result. The endpoint URL and
 * a session id are baked into the generated file (exactly how the testkit
 * mock-provider extension bakes its provider baseUrl), and it loads under
 * --no-extensions via an explicit --extension, per the launch-flag contract.
 */

export interface BridgeToolSpec {
  /** Tool name the LLM calls, e.g. "agent_deck_memory_write". */
  name: string;
  /** Human-readable label for UI. */
  label: string;
  /** Description handed to the LLM. */
  description: string;
  /**
   * JSON-Schema object (`{ type: "object", properties, required }`) describing
   * the parameters. pi/typebox validate against the JSON-Schema shape, so a
   * plain object literal is sufficient — the extension needs no typebox import.
   */
  parameters: Record<string, unknown>;
  /** Optional one-line snippet for the system prompt's tool list. */
  promptSnippet?: string;
}

export interface BridgeExtensionOptions {
  /** URL each tool call POSTs to, e.g. "http://127.0.0.1:PORT/bridge". */
  endpoint: string;
  /** Opaque session id echoed to the app so it can correlate the call. */
  sessionId: string;
  /**
   * Per-session secret baked into the extension and sent with every call. The
   * app rejects calls whose token doesn't match the session's — so a local
   * caller can't invoke another session's (project/session-scoped) tools.
   */
  token: string;
  /** The app-managed tools this bridge exposes to pi. */
  tools: BridgeToolSpec[];
}

/** The request body the bridge endpoint receives for each tool call. */
export interface BridgeCallRequest {
  sessionId: string;
  /** The per-session secret; the app validates it before dispatching. */
  token: string;
  tool: string;
  toolCallId: string;
  params: Record<string, unknown>;
}

/** The response the bridge endpoint returns; mapped to the pi tool result. */
export interface BridgeCallResponse {
  /** Text content returned to the model. */
  content: string;
  /** Marks the result as an error to the model. */
  isError?: boolean;
  /** Arbitrary structured details for logs/UI (kept on the tool result). */
  details?: unknown;
}

/**
 * Write a pi extension that registers each spec'd tool and routes its calls to
 * `endpoint`. Returns the path to load with --extension. The generated file is
 * plain runtime JS (no type annotations) so pi's jiti loader runs it directly.
 */
export function writeBridgeExtension(opts: BridgeExtensionOptions): string {
  const dir = mkdtempSync(path.join(tmpdir(), "agent-deck-bridge-ext-"));
  const file = path.join(dir, "bridge.ts");
  const endpoint = JSON.stringify(opts.endpoint);
  const sessionId = JSON.stringify(opts.sessionId);
  const token = JSON.stringify(opts.token);
  const tools = JSON.stringify(
    opts.tools.map((t) => ({
      name: t.name,
      label: t.label,
      description: t.description,
      parameters: t.parameters,
      promptSnippet: t.promptSnippet,
    })),
  );
  writeFileSync(
    file,
    `export default function (pi) {
  const endpoint = ${endpoint};
  const sessionId = ${sessionId};
  const token = ${token};
  const tools = ${tools};
  // execute() has no way to set the error flag on its return, so a tool call
  // the app (or transport) reported as failed is recorded by id here and the
  // flag is flipped in the tool_result handler below — which preserves the
  // content and details the app returned (a plain throw would discard both).
  const errorCallIds = new Set();
  for (const t of tools) {
    pi.registerTool({
      name: t.name,
      label: t.label,
      description: t.description,
      promptSnippet: t.promptSnippet,
      parameters: t.parameters,
      execute: async (toolCallId, params, signal) => {
        let res;
        try {
          res = await fetch(endpoint, {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({ sessionId, token, tool: t.name, toolCallId, params }),
            signal,
          });
        } catch (err) {
          errorCallIds.add(toolCallId);
          return {
            content: [{ type: "text", text: "bridge unreachable: " + String(err) }],
            details: { bridgeError: true },
          };
        }
        if (!res.ok) {
          const text = await res.text().catch(() => res.statusText);
          errorCallIds.add(toolCallId);
          return {
            content: [{ type: "text", text: "bridge error " + res.status + ": " + text }],
            details: { bridgeError: true, status: res.status },
          };
        }
        const data = await res.json();
        if (data.isError) errorCallIds.add(toolCallId);
        return {
          content: [{ type: "text", text: String(data.content == null ? "" : data.content) }],
          details: data.details == null ? {} : data.details,
        };
      },
    });
  }
  pi.on("tool_result", (event) => {
    if (errorCallIds.has(event.toolCallId)) {
      errorCallIds.delete(event.toolCallId);
      return { isError: true };
    }
  });
}
`,
  );
  return file;
}

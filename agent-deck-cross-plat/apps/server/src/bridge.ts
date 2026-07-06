import type { BridgeCallRequest, BridgeCallResponse, BridgeToolSpec } from "@agent-deck/pi-host";

/**
 * The app side of the bridge substrate (see packages/pi-host/src/bridge.ts):
 * app-managed tools exposed to pi sessions. A tool registered here is
 * advertised to every session it's generated into, and each call the model
 * makes is dispatched to the registered handler. Memory, MCP-proxy, and the
 * native subagent bridges all register their tools here.
 */

export interface BridgeToolContext {
  /** The session that made the call (for project/session-scoped engines). */
  sessionId: string;
  /** pi's tool-call id, stable for the life of one call. */
  toolCallId: string;
}

export type BridgeToolHandler = (
  params: Record<string, unknown>,
  ctx: BridgeToolContext,
) => Promise<BridgeCallResponse> | BridgeCallResponse;

interface Registration {
  spec: BridgeToolSpec;
  handler: BridgeToolHandler;
}

export class BridgeRegistry {
  private readonly tools = new Map<string, Registration>();

  /** Register (or replace) an app-managed tool. */
  register(spec: BridgeToolSpec, handler: BridgeToolHandler): void {
    this.tools.set(spec.name, { spec, handler });
  }

  unregister(name: string): void {
    this.tools.delete(name);
  }

  /** Number of registered tools — zero means no bridge extension is generated. */
  get size(): number {
    return this.tools.size;
  }

  /** Tool specs baked into a session's generated bridge extension. */
  specs(): BridgeToolSpec[] {
    return [...this.tools.values()].map((registration) => registration.spec);
  }

  /** Dispatch one call from a session's bridge extension to its handler. */
  async dispatch(call: BridgeCallRequest): Promise<BridgeCallResponse> {
    const registration = this.tools.get(call.tool);
    if (!registration) {
      return { content: `unknown bridge tool: ${call.tool}`, isError: true };
    }
    try {
      return await registration.handler(call.params, {
        sessionId: call.sessionId,
        toolCallId: call.toolCallId,
      });
    } catch (error) {
      return {
        content: `bridge handler error: ${error instanceof Error ? error.message : String(error)}`,
        isError: true,
      };
    }
  }
}

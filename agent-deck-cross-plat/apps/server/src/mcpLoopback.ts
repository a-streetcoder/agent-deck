import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";

/**
 * A one-shot loopback HTTP server that captures an OAuth redirect (native
 * MCPLoopbackServer). It listens on a random 127.0.0.1 port, answers the
 * browser's redirect with a "you can close this" page, and delivers the
 * redirect's query params (code+state, or an error) to whoever awaits
 * waitForCallback — which resolves whether the callback lands before or after
 * the wait begins. This turns the MCP OAuth flow from "paste the code" into an
 * automatic capture; the manual paste stays as the fallback.
 */

export interface McpLoopbackResult {
  code?: string;
  state?: string;
  /** An OAuth `error` param (e.g. access_denied), if the provider sent one. */
  error?: string;
}

const RESULT_PAGE = (ok: boolean): string =>
  `<!doctype html><html><head><meta charset="utf-8"><title>Agent Deck</title></head>` +
  `<body style="font-family:system-ui;text-align:center;padding:3rem;color:#333">` +
  `<h2>${ok ? "Signed in" : "Sign-in failed"}</h2>` +
  `<p>You can close this tab and return to Agent Deck.</p></body></html>`;

export class McpLoopbackServer {
  private server?: Server;
  private port = 0;
  /** Resolver for an in-flight waitForCallback, else null. */
  private pending: ((result: McpLoopbackResult) => void) | null = null;
  /** A callback that arrived before waitForCallback was called. */
  private buffered?: McpLoopbackResult;
  /** One-shot: once a redirect is captured, later ones are answered but ignored. */
  private settled = false;

  /** Start listening; resolves with the bound loopback port. */
  async start(): Promise<number> {
    return new Promise<number>((resolve, reject) => {
      const server = createServer((req, res) => this.handle(req, res));
      server.once("error", reject);
      server.listen(0, "127.0.0.1", () => {
        this.port = (server.address() as AddressInfo).port;
        this.server = server;
        resolve(this.port);
      });
    });
  }

  /** The redirect URI to register with the provider and open in the browser. */
  get redirectUrl(): string {
    return `http://127.0.0.1:${this.port}/callback`;
  }

  private handle(req: IncomingMessage, res: ServerResponse): void {
    const url = new URL(req.url ?? "/", `http://127.0.0.1:${this.port}`);
    const code = url.searchParams.get("code") ?? undefined;
    const error = url.searchParams.get("error") ?? undefined;
    // Only the actual redirect carries a code or error — ignore stray requests
    // (favicon, etc.) so they can't resolve the wait with an empty result.
    if (!code && !error) {
      res.writeHead(404).end();
      return;
    }
    res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
    res.end(RESULT_PAGE(Boolean(code) && !error));
    this.deliver({ code, state: url.searchParams.get("state") ?? undefined, error });
  }

  private deliver(result: McpLoopbackResult): void {
    // One-shot: the first redirect wins; a later one is still answered with the
    // close-me page (in handle) but must not overwrite or re-deliver a result.
    if (this.settled) return;
    this.settled = true;
    if (this.pending) {
      const resolve = this.pending;
      this.pending = null;
      resolve(result);
    } else {
      this.buffered = result;
    }
  }

  /** Await the redirect's params; resolves with `{error}` on timeout. */
  waitForCallback(timeoutMs = 300_000): Promise<McpLoopbackResult> {
    if (this.buffered) {
      const result = this.buffered;
      this.buffered = undefined;
      return Promise.resolve(result);
    }
    return new Promise<McpLoopbackResult>((resolve) => {
      const timer = setTimeout(() => {
        this.pending = null;
        resolve({ error: "timed out waiting for the authorization redirect" });
      }, timeoutMs);
      timer.unref();
      this.pending = (result) => {
        clearTimeout(timer);
        resolve(result);
      };
    });
  }

  async close(): Promise<void> {
    const server = this.server;
    this.server = undefined;
    if (server) await new Promise<void>((resolve) => server.close(() => resolve()));
  }
}

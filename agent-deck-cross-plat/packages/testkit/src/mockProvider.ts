import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";

/**
 * A minimal OpenAI-Chat-Completions-compatible streaming server. Tests point a
 * REAL pi binary at it via a custom-provider extension (see extension.ts), so
 * protocol, framing, and streaming are exercised end-to-end with zero API keys
 * and deterministic tokens.
 *
 * Responses stream one SSE chunk per word with a small delay, guaranteeing pi
 * emits multiple distinct text_delta events for multi-word scripts.
 */

/** A tool call the model should emit instead of a text reply (bridge tests). */
export interface MockToolCall {
  /** Registered tool name, e.g. an agent_deck_* bridge tool. */
  name: string;
  /** Arguments object; serialized to the OpenAI tool_call arguments string. */
  arguments: Record<string, unknown>;
  /** Stable id; defaults to a per-response id. */
  id?: string;
}

export interface MockProviderOptions {
  /** Returns the assistant reply for the last user message. */
  reply?: (lastUserMessage: string, body: ChatCompletionRequest) => string;
  /**
   * Optional tool-call script. When it returns a tool call for a given request,
   * the response streams an OpenAI `tool_calls` delta (finish_reason
   * "tool_calls") instead of text — so a REAL pi drives a registered tool. Once
   * the tool result comes back on a follow-up request, return null to let the
   * model answer with text. Lets bridge tools be exercised end-to-end.
   */
  toolCall?: (lastUserMessage: string, body: ChatCompletionRequest) => MockToolCall | null;
  /** Delay between streamed chunks (ms). */
  chunkDelayMs?: number;
}

export interface ChatCompletionRequest {
  model: string;
  messages: Array<{ role: string; content: unknown }>;
  stream?: boolean;
  [key: string]: unknown;
}

export interface MockProviderServer {
  port: number;
  baseUrl: string;
  /** All request bodies received, in order (for asserting system prompts etc.). */
  requests: ChatCompletionRequest[];
  close(): Promise<void>;
}

function contentToString(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .map((part) =>
        typeof part === "object" && part !== null && "text" in part
          ? String((part as { text: unknown }).text)
          : "",
      )
      .join("");
  }
  return "";
}

const DEFAULT_REPLY = (lastUserMessage: string): string =>
  `You said: ${lastUserMessage}. Here is a deliberately multi-word streaming reply.`;

export async function startMockProvider(
  options: MockProviderOptions = {},
): Promise<MockProviderServer> {
  const reply = options.reply ?? DEFAULT_REPLY;
  const toolCall = options.toolCall;
  const chunkDelayMs = options.chunkDelayMs ?? 5;
  const requests: ChatCompletionRequest[] = [];

  const server: Server = createServer((req, res) => {
    if (req.method !== "POST" || !req.url?.endsWith("/chat/completions")) {
      res.writeHead(404).end();
      return;
    }
    let raw = "";
    req.on("data", (chunk) => (raw += chunk));
    req.on("end", () => {
      let body: ChatCompletionRequest;
      try {
        body = JSON.parse(raw) as ChatCompletionRequest;
      } catch {
        res.writeHead(400).end();
        return;
      }
      requests.push(body);
      const lastUser = [...body.messages].reverse().find((m) => m.role === "user");
      const lastUserText = contentToString(lastUser?.content ?? "");
      const id = `chatcmpl-mock-${requests.length}`;
      const created = 0;

      res.writeHead(200, {
        "content-type": "text/event-stream",
        "cache-control": "no-cache",
        connection: "keep-alive",
      });

      const chunk = (delta: object, finishReason: string | null): string =>
        `data: ${JSON.stringify({
          id,
          object: "chat.completion.chunk",
          created,
          model: body.model,
          choices: [{ index: 0, delta, finish_reason: finishReason }],
        })}\n\n`;

      // Tool-call turn: stream a single tool_calls delta, then finish. pi turns
      // this into a real tool invocation; the follow-up request (with the tool
      // result) falls through to the text branch below.
      const wantsTool = toolCall?.(lastUserText, body) ?? null;
      if (wantsTool) {
        res.write(chunk({ role: "assistant", content: null }, null));
        res.write(
          chunk(
            {
              tool_calls: [
                {
                  index: 0,
                  id: wantsTool.id ?? `call_mock_${requests.length}`,
                  type: "function",
                  function: {
                    name: wantsTool.name,
                    arguments: JSON.stringify(wantsTool.arguments),
                  },
                },
              ],
            },
            null,
          ),
        );
        res.write(chunk({}, "tool_calls"));
        res.write("data: [DONE]\n\n");
        res.end();
        return;
      }

      const text = reply(lastUserText, body);
      const words = text.split(" ").map((word, i) => (i === 0 ? word : ` ${word}`));
      let i = 0;
      res.write(chunk({ role: "assistant", content: "" }, null));
      const timer = setInterval(() => {
        if (i < words.length) {
          res.write(chunk({ content: words[i] }, null));
          i += 1;
          return;
        }
        clearInterval(timer);
        res.write(chunk({}, "stop"));
        res.write(
          `data: ${JSON.stringify({
            id,
            object: "chat.completion.chunk",
            created,
            model: body.model,
            choices: [],
            usage: {
              prompt_tokens: 1,
              completion_tokens: words.length,
              total_tokens: words.length + 1,
            },
          })}\n\n`,
        );
        res.write("data: [DONE]\n\n");
        res.end();
      }, chunkDelayMs);
    });
  });

  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = (server.address() as AddressInfo).port;

  return {
    port,
    baseUrl: `http://127.0.0.1:${port}`,
    requests,
    close: () =>
      new Promise<void>((resolve, reject) =>
        server.close((error) => (error ? reject(error) : resolve())),
      ),
  };
}

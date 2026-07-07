import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

export const MOCK_PROVIDER_ID = "mock";
export const MOCK_MODEL_ID = "mock-model";
/** A second, non-reasoning model so thinking-level gating is testable. */
export const MOCK_NOREASON_MODEL_ID = "basic-model";

/**
 * Write a pi custom-provider extension that registers the mock provider at the
 * given baseUrl. Loaded explicitly with --extension (still honored under
 * --no-extensions per the launch-flag contract).
 */
/**
 * Extension registering an /ask-test command that raises a real
 * extension_ui_request (confirm) — drives question-card e2e through pi itself.
 */
export function writeQuestionCommandExtension(): string {
  const dir = mkdtempSync(path.join(tmpdir(), "agent-deck-ask-ext-"));
  const file = path.join(dir, "ask-test.ts");
  writeFileSync(
    file,
    `export default function (pi) {
  pi.registerCommand("ask-test", {
    description: "Ask a test question",
    handler: async (_args, ctx) => {
      const ok = await ctx.ui.confirm("Test question", "Proceed with the mission?");
      ctx.ui.notify(ok ? "mission confirmed" : "mission declined", "info");
    },
  });
}
`,
  );
  return file;
}

/**
 * Extension registering /ask-input, /ask-select, /ask-editor — one command per
 * remaining ask-user card type, so the input/select/editor cards can be driven
 * through real pi extension_ui_requests.
 */
export function writeUiCardsExtension(): string {
  const dir = mkdtempSync(path.join(tmpdir(), "agent-deck-uicards-ext-"));
  const file = path.join(dir, "ui-cards.ts");
  writeFileSync(
    file,
    `export default function (pi) {
  pi.registerCommand("ask-input", {
    description: "Ask for a line of input",
    handler: async (_args, ctx) => {
      const v = await ctx.ui.input("Your handle", "type it");
      ctx.ui.notify("input:" + v, "info");
    },
  });
  pi.registerCommand("ask-select", {
    description: "Ask to pick one",
    handler: async (_args, ctx) => {
      const v = await ctx.ui.select("Pick a color", ["crimson", "viridian"]);
      ctx.ui.notify("select:" + v, "info");
    },
  });
  pi.registerCommand("ask-editor", {
    description: "Ask to edit multiline text",
    handler: async (_args, ctx) => {
      const v = await ctx.ui.editor("Edit the note", "hello from prefill");
      ctx.ui.notify("editor:" + v, "info");
    },
  });
}
`,
  );
  return file;
}

export function writeMockProviderExtension(baseUrl: string): string {
  const dir = mkdtempSync(path.join(tmpdir(), "agent-deck-mock-ext-"));
  const file = path.join(dir, "mock-provider.ts");
  writeFileSync(
    file,
    `export default function (pi) {
  pi.registerProvider(${JSON.stringify(MOCK_PROVIDER_ID)}, {
    name: "Mock Provider",
    baseUrl: ${JSON.stringify(baseUrl)},
    apiKey: "mock-key",
    api: "openai-completions",
    models: [
      {
        id: ${JSON.stringify(MOCK_MODEL_ID)},
        name: "Mock Model",
        // Reasoning-capable so thinking levels round-trip in tests.
        reasoning: true,
        input: ["text", "image"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        contextWindow: 128000,
        maxTokens: 4096,
      },
      {
        id: ${JSON.stringify(MOCK_NOREASON_MODEL_ID)},
        name: "Basic Model",
        // Non-reasoning: the thinking picker must restrict this to "off" only.
        reasoning: false,
        input: ["text"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        contextWindow: 64000,
        maxTokens: 2048,
      },
    ],
  });
}
`,
  );
  return file;
}

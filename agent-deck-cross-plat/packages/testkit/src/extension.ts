import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

export const MOCK_PROVIDER_ID = "mock";
export const MOCK_MODEL_ID = "mock-model";

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
        reasoning: false,
        input: ["text"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        contextWindow: 128000,
        maxTokens: 4096,
      },
    ],
  });
}
`,
  );
  return file;
}

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

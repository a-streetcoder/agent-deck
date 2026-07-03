import { defineConfig } from "vitest/config";

// Integration tests that spawn a REAL pi binary through the full HTTP+WS stack.
export default defineConfig({
  test: {
    include: ["test/**/*.pi.test.ts"],
    passWithNoTests: true,
    fileParallelism: false,
    testTimeout: 60_000,
    hookTimeout: 60_000,
  },
});

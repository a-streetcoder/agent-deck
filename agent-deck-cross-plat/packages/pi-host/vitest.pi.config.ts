import { defineConfig } from "vitest/config";

// Integration tests that spawn a REAL pi binary. Serial (one pi process at a time
// per file) and with generous timeouts — subprocess startup dominates.
export default defineConfig({
  test: {
    include: ["test/**/*.pi.test.ts"],
    passWithNoTests: true,
    fileParallelism: false,
    testTimeout: 60_000,
    hookTimeout: 60_000,
  },
});

import { defineConfig } from "vitest/config";

const ci = !!process.env.CI;

export default defineConfig({
  test: {
    include: ["test/**/*.test.ts"],
    exclude: ["test/**/*.pi.test.ts"],
    passWithNoTests: true,
    // The shared CI runners (macOS/Windows especially) are slow enough that the
    // timing-based correlation test occasionally exceeds the 5s default under
    // load — give it headroom and retry transient flakes there. Local runs keep
    // the tight default so a real regression still surfaces fast.
    testTimeout: ci ? 20_000 : 5_000,
    retry: ci ? 2 : 0,
  },
});

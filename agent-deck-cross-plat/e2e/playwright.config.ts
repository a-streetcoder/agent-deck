import { defineConfig } from "@playwright/test";

const ci = !!process.env.CI;

export default defineConfig({
  testDir: "./tests",
  timeout: 90_000,
  // One worker: each spec boots its own server + real pi; keep resource use sane.
  workers: 1,
  // The shared CI runner is slow enough that individual assertions occasionally
  // exceed the 5s default under load — give expectations more headroom there and
  // retry transient flakes so a single slow assertion doesn't fail the whole run.
  retries: ci ? 2 : 0,
  expect: { timeout: ci ? 15_000 : 5_000 },
  use: {
    trace: "retain-on-failure",
    actionTimeout: ci ? 15_000 : 0,
  },
});

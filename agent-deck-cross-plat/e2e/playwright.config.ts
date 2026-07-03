import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "./tests",
  timeout: 90_000,
  // One worker: each spec boots its own server + real pi; keep resource use sane.
  workers: 1,
  use: {
    trace: "retain-on-failure",
  },
});

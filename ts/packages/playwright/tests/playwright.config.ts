import { defineConfig } from "@playwright/test";
export default defineConfig({ testDir: ".", testMatch: "attached.spec.ts", workers: 1, retries: 0,
  timeout: 30_000, reporter: "list", use: { browserName: "chromium" } });

import { defineConfig, devices } from "@playwright/test";

const port = 4329;

export default defineConfig({
  testDir: "tests",
  fullyParallel: true,
  reporter: [["list"]],
  use: {
    baseURL: `http://127.0.0.1:${port}`,
  },
  projects: [
    { name: "light", use: { ...devices["Desktop Chrome"], colorScheme: "light" } },
    {
      name: "dark",
      use: { ...devices["Desktop Chrome"], colorScheme: "dark" },
      testMatch: /(smoke|a11y|scenes|icons|contrast)\.spec\.ts/,
    },
  ],
  webServer: {
    command: `pnpm exec astro preview --port ${port} --host 127.0.0.1 --ignore-lock`,
    url: `http://127.0.0.1:${port}`,
    reuseExistingServer: false,
    timeout: 60_000,
  },
});

import { fileURLToPath } from "node:url";
import { defineConfig } from "astro/config";

const repoRoot = fileURLToPath(new URL("..", import.meta.url));

export default defineConfig({
  site: process.env.SITE_URL,
  devToolbar: { enabled: false },
  vite: {
    server: { fs: { allow: [repoRoot] } },
  },
});

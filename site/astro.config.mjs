import { rename, rmdir } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import sitemap from "@astrojs/sitemap";
import { defineConfig } from "astro/config";
import { cropShots } from "./scripts/crop-shots.ts";

const repoRoot = fileURLToPath(new URL("..", import.meta.url));

const croppedShots = {
  name: "cropped-shots",
  hooks: {
    "astro:config:setup": () => cropShots(),
  },
};

const localizedNotFound = {
  name: "localized-404",
  hooks: {
    "astro:build:done": async ({ dir }) => {
      await rename(new URL("it/404/index.html", dir), new URL("it/404.html", dir));
      await rmdir(new URL("it/404/", dir));
    },
  },
};

export default defineConfig({
  site: process.env.SITE_URL,
  devToolbar: { enabled: false },
  integrations: [
    croppedShots,
    localizedNotFound,
    sitemap({
      filter: (page) => !/\/(og-card|404)/.test(new URL(page).pathname),
      i18n: { defaultLocale: "en", locales: { en: "en", it: "it" } },
    }),
  ],
  i18n: {
    locales: ["en", "it"],
    defaultLocale: "en",
    routing: { prefixDefaultLocale: false },
  },
  vite: {
    server: { fs: { allow: [repoRoot] } },
  },
});

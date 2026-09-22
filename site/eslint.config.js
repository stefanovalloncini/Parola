import js from "@eslint/js";
import astro from "eslint-plugin-astro";
import prettier from "eslint-config-prettier";
import { defineConfig } from "eslint/config";
import globals from "globals";
import tseslint from "typescript-eslint";

export default defineConfig(
  { ignores: ["dist", "node_modules", ".astro", "test-results", "playwright-report"] },
  js.configs.recommended,
  tseslint.configs.strict,
  astro.configs.recommended,
  prettier,
  {
    languageOptions: { globals: { ...globals.browser, ...globals.node } },
    rules: {
      "@typescript-eslint/consistent-type-imports": "error",
      "max-lines": ["error", { max: 250, skipBlankLines: true, skipComments: true }],
    },
  },
);

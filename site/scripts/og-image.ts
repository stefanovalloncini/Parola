import { chromium } from "@playwright/test";

const base = process.argv[2] ?? "http://127.0.0.1:4321";
const cards = [
  { path: "/og-card", file: "og.png" },
  { path: "/it/og-card", file: "og-it.png" },
];
const browser = await chromium.launch();
const page = await browser.newPage({
  viewport: { width: 1200, height: 630 },
  deviceScaleFactor: 1,
});
for (const card of cards) {
  await page.goto(`${base}${card.path}`);
  await page.waitForLoadState("networkidle");
  await page
    .locator(".card")
    .screenshot({ path: new URL(`../public/${card.file}`, import.meta.url).pathname });
  console.log(`Wrote public/${card.file}`);
}
await browser.close();

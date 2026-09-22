import { chromium } from "@playwright/test";

const base = process.argv[2] ?? "http://127.0.0.1:4321";
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1200, height: 630 }, deviceScaleFactor: 1 });
await page.goto(`${base}/og-card`);
await page.waitForLoadState("networkidle");
await page.locator(".card").screenshot({ path: new URL("../public/og.png", import.meta.url).pathname });
await browser.close();
console.log("Wrote public/og.png");

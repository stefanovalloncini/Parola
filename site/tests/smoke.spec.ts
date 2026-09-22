import { expect, test } from "@playwright/test";

const pages = ["/", "/privacy", "/404"];
const widths = [360, 390, 768, 1024, 1440];

for (const path of pages) {
  test(`${path} renders without console errors`, async ({ page }) => {
    const errors: string[] = [];
    page.on("console", (message) => {
      if (message.type() === "error") errors.push(message.text());
    });
    page.on("pageerror", (error) => errors.push(error.message));
    await page.goto(path);
    await expect(page.locator("h1")).toHaveCount(1);
    expect(errors).toEqual([]);
  });
}

for (const width of widths) {
  test(`home has no horizontal overflow at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 900 });
    await page.goto("/");
    const overflow = await page.evaluate(
      () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
    );
    expect(overflow).toBeLessThanOrEqual(0);
  });
}

test("the page loads nothing from other servers", async ({ page, baseURL }) => {
  const foreign: string[] = [];
  page.on("request", (request) => {
    const url = new URL(request.url());
    if (url.origin !== new URL(baseURL ?? "").origin && url.protocol.startsWith("http")) {
      foreign.push(request.url());
    }
  });
  await page.goto("/");
  await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight));
  await page.waitForLoadState("networkidle");
  expect(foreign).toEqual([]);
});

test("internal links resolve", async ({ page, request }) => {
  await page.goto("/");
  const hrefs = await page
    .locator("a[href^='/']")
    .evaluateAll((anchors) => anchors.map((a) => a.getAttribute("href") ?? ""));
  for (const href of new Set(hrefs.map((h) => h.split("#")[0] || "/"))) {
    const response = await request.get(href);
    expect(response.status(), href).toBe(200);
  }
});

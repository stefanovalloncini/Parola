import { expect, test } from "@playwright/test";

const pages = [
  { path: "/", lang: "en" },
  { path: "/privacy/", lang: "en" },
  { path: "/404", lang: "en" },
  { path: "/it/", lang: "it" },
  { path: "/it/privacy/", lang: "it" },
  { path: "/it/404.html", lang: "it" },
];
const homes = ["/", "/it/"];
const widths = [360, 390, 768, 1024, 1440];

for (const { path, lang } of pages) {
  test(`${path} renders without console errors`, async ({ page }) => {
    const errors: string[] = [];
    page.on("console", (message) => {
      if (message.type() === "error") errors.push(message.text());
    });
    page.on("pageerror", (error) => errors.push(error.message));
    await page.goto(path);
    await expect(page.locator("h1")).toHaveCount(1);
    await expect(page.locator("html")).toHaveAttribute("lang", lang);
    expect(errors).toEqual([]);
  });
}

for (const home of homes) {
  for (const width of widths) {
    test(`${home} has no horizontal overflow at ${width}px`, async ({ page }) => {
      await page.setViewportSize({ width, height: 900 });
      await page.goto(home);
      const worst = await page.evaluate(async () => {
        let max = 0;
        const step = window.innerHeight * 0.8;
        for (let y = 0; y < document.documentElement.scrollHeight; y += step) {
          window.scrollTo(0, y);
          await new Promise((resolve) => setTimeout(resolve, 60));
          max = Math.max(
            max,
            document.documentElement.scrollWidth - document.documentElement.clientWidth,
          );
        }
        return max;
      });
      expect(worst).toBeLessThanOrEqual(0);
    });
  }
}

test("the header keeps its blur in the production build", async ({ page }) => {
  await page.goto("/");
  await page.evaluate(() => window.scrollTo(0, 600));
  await expect(page.locator("[data-header]")).toHaveAttribute("data-scrolled", "");
  const filter = await page
    .locator("[data-header]")
    .evaluate((header) => getComputedStyle(header).backdropFilter);
  expect(filter).not.toBe("none");
});

test("the header only turns dark over the dark band", async ({ page }) => {
  await page.goto("/");
  for (const y of [0, 900, 1500, 2200]) {
    await page.evaluate((top) => window.scrollTo(0, top), y);
    await page.waitForTimeout(120);
    await expect(page.locator("[data-header]")).not.toHaveAttribute("data-over-dark", "");
  }
  await page
    .locator('[data-theme="dark"]')
    .first()
    .evaluate((band) => {
      window.scrollTo(0, band.getBoundingClientRect().top + window.scrollY + 200);
    });
  await expect(page.locator("[data-header]")).toHaveAttribute("data-over-dark", "");
});

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

for (const home of homes) {
  test(`internal links on ${home} resolve`, async ({ page, request }) => {
    await page.goto(home);
    const hrefs = await page
      .locator("a[href^='/']")
      .evaluateAll((anchors) => anchors.map((a) => a.getAttribute("href") ?? ""));
    for (const href of new Set(hrefs.map((h) => h.split("#")[0] || "/"))) {
      const response = await request.get(href);
      expect(response.status(), href).toBe(200);
    }
  });
}

test("the language link keeps the reader on the same page", async ({ page }) => {
  await page.goto("/privacy/");
  await page.getByRole("link", { name: "Italiano" }).click();
  await expect(page).toHaveURL(/\/it\/privacy\/$/);
  await page.getByRole("link", { name: "English" }).click();
  await expect(page).toHaveURL(/\/privacy\/$/);
  await expect(page.locator("html")).toHaveAttribute("lang", "en");
});

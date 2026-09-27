import { expect, test } from "@playwright/test";

const pages = ["/", "/privacy/", "/404", "/it/", "/it/privacy/", "/it/404.html"];

function channels(color: string): number[] {
  return (color.match(/[\d.]+/g) ?? []).slice(0, 3).map(Number);
}

function luminance(color: string): number {
  const [r = 0, g = 0, b = 0] = channels(color).map((value) => {
    const c = value / 255;
    return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
  });
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

function contrast(a: string, b: string): number {
  const [high = 0, low = 0] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (high + 0.05) / (low + 0.05);
}

test.describe("light scheme", () => {
  test.use({ colorScheme: "light" });

  for (const path of pages) {
    test(`${path} keeps the white page`, async ({ page }) => {
      await page.goto(path);
      const background = await page.evaluate(() => getComputedStyle(document.body).backgroundColor);
      expect(background).toBe("rgb(255, 255, 255)");
    });
  }

  test("an open page turns dark when the Mac does", async ({ page }) => {
    await page.goto("/");
    const background = () => page.evaluate(() => getComputedStyle(document.body).backgroundColor);
    expect(await background()).toBe("rgb(255, 255, 255)");
    await page.emulateMedia({ colorScheme: "dark" });
    await expect.poll(background).toBe("rgb(10, 17, 13)");
  });
});

test.describe("dark scheme", () => {
  test.use({ colorScheme: "dark" });

  for (const path of pages) {
    test(`${path} paints the night page`, async ({ page }) => {
      await page.goto(path);
      const background = await page.evaluate(() => getComputedStyle(document.body).backgroundColor);
      expect(background).toBe("rgb(10, 17, 13)");
    });
  }

  for (const path of ["/og-card/", "/it/og-card/"]) {
    test(`${path} keeps the light OG card`, async ({ page }) => {
      await page.goto(path);
      const h1 = await page.locator("h1").evaluate((element) => getComputedStyle(element).color);
      expect(h1).toBe("rgb(15, 26, 20)");
      const card = page.locator(".card");
      const dark = await card.evaluate((element) => getComputedStyle(element).backgroundImage);
      await page.emulateMedia({ colorScheme: "light" });
      const light = await card.evaluate((element) => getComputedStyle(element).backgroundImage);
      expect(dark).toBe(light);
    });
  }

  test("the skip link is readable when a keyboard reaches it", async ({ page }) => {
    await page.goto("/");
    await page.keyboard.press("Tab");
    const skip = page.locator(".skip");
    await expect(skip).toBeFocused();
    const [color, background] = await skip.evaluate((link) => {
      const style = getComputedStyle(link);
      return [style.color, style.backgroundColor];
    });
    expect(luminance(background ?? "")).toBeGreaterThan(0.5);
    expect(contrast(color ?? "", background ?? "")).toBeGreaterThanOrEqual(4.5);
  });

  test("the header stays dark from top to bottom", async ({ page }) => {
    await page.goto("/");
    const height = await page.evaluate(() => document.documentElement.scrollHeight);
    for (let y = 600; y < height; y += 1400) {
      await page.evaluate((top) => window.scrollTo({ top, behavior: "instant" }), y);
      await page.waitForTimeout(120);
      const background = await page
        .locator("[data-header]")
        .evaluate((header) => getComputedStyle(header).backgroundColor);
      expect(Math.max(...channels(background)), `header at ${y}px`).toBeLessThan(60);
    }
  });

  test("the stuck download card fades into the night page", async ({ page }) => {
    await page.setViewportSize({ width: 1440, height: 900 });
    await page.goto("/");
    const top = await page
      .locator("[data-stick-mark]")
      .evaluate((mark) => mark.getBoundingClientRect().top + window.scrollY);
    await page.evaluate((y) => window.scrollTo(0, y), top);
    await expect(page.locator("[data-stick-card]")).toHaveClass(/is-stuck/);
    const fade = await page
      .locator("[data-stick-card]")
      .evaluate((dock) => getComputedStyle(dock, "::after").backgroundImage);
    expect(fade).not.toContain("255, 255, 255");
    expect(fade).toContain("10, 17, 13");
  });

  test("a black-background mark tile carries the light ring", async ({ page }) => {
    await page.goto("/");
    const shadow = await page
      .locator("[data-edge]")
      .first()
      .evaluate((tile) => getComputedStyle(tile).boxShadow);
    expect(shadow).toContain("255, 255, 255");
  });
});

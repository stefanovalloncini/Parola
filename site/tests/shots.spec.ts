import { expect, test, type Locator, type Page } from "@playwright/test";

interface Sources {
  dark: string[];
  light: string[];
  current: string;
}

async function sourcesOf(picture: Locator): Promise<Sources> {
  return picture.evaluate((element) => {
    const urls = (dark: boolean) =>
      [...element.querySelectorAll("source")]
        .filter((source) => source.media.includes("prefers-color-scheme: dark") === dark)
        .flatMap((source) =>
          source.srcset
            .split(",")
            .map((part) => new URL(part.trim().split(" ")[0] ?? "", location.href).href),
        );
    const img = element.querySelector("img");
    return {
      dark: urls(true),
      light: [...urls(false), new URL(img?.getAttribute("src") ?? "", location.href).href],
      current: img?.currentSrc ?? "",
    };
  });
}

const themed = "picture:has(source[media*='prefers-color-scheme: dark'])";

async function visibleThemed(page: Page): Promise<Locator[]> {
  const hero = page.locator(`.scene-window ${themed}`);
  const drop = page.locator(`.drop [data-panel]:not([hidden]) ${themed}`);
  await drop.scrollIntoViewIfNeeded();
  await page.waitForTimeout(300);
  return [hero, drop];
}

test.describe("dark scheme", () => {
  test.use({ colorScheme: "dark" });

  test("every shot outside the band has a dark twin", async ({ page }) => {
    await page.goto("/");
    const count = await page.locator(themed).count();
    expect(count).toBe(8);
  });

  test("the visible shots are the dark captures", async ({ page }) => {
    await page.goto("/");
    for (const picture of await visibleThemed(page)) {
      const { dark, current } = await sourcesOf(picture);
      expect(dark).toContain(current);
    }
  });

  test("no light capture is downloaded", async ({ page }) => {
    const requested: string[] = [];
    page.on("request", (request) => requested.push(request.url()));
    await page.goto("/");
    await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight));
    await page.waitForLoadState("networkidle");
    const lightOnly = new Set<string>();
    for (const picture of await page.locator(themed).all()) {
      const { dark, light } = await sourcesOf(picture);
      light.filter((url) => !dark.includes(url)).forEach((url) => lightOnly.add(url));
    }
    expect(requested.filter((url) => lightOnly.has(url))).toEqual([]);
  });

  test("the hero LCP image is not double-fetched", async ({ page }) => {
    const requested: string[] = [];
    page.on("request", (request) => requested.push(request.url()));
    await page.goto("/");
    await page.waitForLoadState("networkidle");
    const hero = page.locator(`.scene-window ${themed}`);
    const { dark, light } = await sourcesOf(hero);
    const lightOnly = light.filter((url) => !dark.includes(url));
    expect(requested.filter((url) => lightOnly.includes(url))).toEqual([]);
    expect(requested.some((url) => dark.includes(url))).toBe(true);
  });

  test("phones get the dark narrow crop", async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await page.goto("/");
    const drop = page.locator(`.drop [data-panel]:not([hidden]) ${themed}`);
    await drop.scrollIntoViewIfNeeded();
    await page.waitForTimeout(300);
    const narrow = await drop.evaluate((element) => {
      const source = [...element.querySelectorAll("source")].find(
        (s) => s.media.includes("prefers-color-scheme: dark") && s.media.includes("max-width"),
      );
      return (source?.srcset ?? "")
        .split(",")
        .map((part) => new URL(part.trim().split(" ")[0] ?? "", location.href).href);
    });
    const { current } = await sourcesOf(drop);
    expect(narrow).toContain(current);
  });

  test("the Italian page uses the Italian captures", async ({ page }) => {
    await page.goto("/");
    const english = await sourcesOf(page.locator(`.drop [data-panel] ${themed}`).first());
    await page.goto("/it/");
    const italian = await sourcesOf(page.locator(`.drop [data-panel] ${themed}`).first());
    expect(italian.dark.filter((url) => english.dark.includes(url))).toEqual([]);
  });
});

test.describe("light scheme", () => {
  test.use({ colorScheme: "light" });

  test("the visible shots stay the light captures", async ({ page }) => {
    await page.goto("/");
    for (const picture of await visibleThemed(page)) {
      const { light, current } = await sourcesOf(picture);
      expect(light).toContain(current);
    }
  });

  test("the shots follow a switch to dark without a reload", async ({ page }) => {
    await page.goto("/");
    const hero = page.locator(`.scene-window ${themed}`);
    expect((await sourcesOf(hero)).light).toContain((await sourcesOf(hero)).current);
    await page.emulateMedia({ colorScheme: "dark" });
    await expect
      .poll(async () => {
        const { dark, current } = await sourcesOf(hero);
        return dark.includes(current);
      })
      .toBe(true);
  });
});

import { expect, test } from "@playwright/test";

test("the karaoke card lights words on its own when it is on screen", async ({ page }) => {
  await page.goto("/");
  const card = page.locator("[data-karaoke]");
  await card.scrollIntoViewIfNeeded();
  await expect.poll(() => card.locator(".is-spoken").count(), { timeout: 5000 }).toBeGreaterThan(3);
});

test("the story switches scenes as the beats scroll past", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto("/");
  const device = page.locator("[data-device]");
  await expect(device).toHaveAttribute("data-scene", "0");
  const seen = new Set<string>();
  for (let y = 0; y < 2400; y += 120) {
    await page.evaluate((top) => window.scrollTo(0, top), y);
    await page.waitForTimeout(40);
    seen.add((await device.getAttribute("data-scene")) ?? "");
  }
  expect([...seen].sort()).toEqual(["0", "1", "2", "3"]);
});

test("feature scenes run only while they are on screen", async ({ page }) => {
  await page.goto("/");
  const scene = page.locator(".meeting[data-scene-loop]");
  await expect(scene).toHaveAttribute("data-state", "alert");
  await scene.scrollIntoViewIfNeeded();
  await expect.poll(() => scene.getAttribute("data-state"), { timeout: 5000 }).toBe("recording");
});

test("the download card sticks without moving the list under it", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto("/");
  const line = await page
    .locator("[data-stick-card]")
    .evaluate((card) => parseFloat(getComputedStyle(card).top));
  const markTop = await page
    .locator("[data-stick-mark]")
    .evaluate((mark) => mark.getBoundingClientRect().top + window.scrollY);
  const listTop = async (offset: number) => {
    await page.evaluate((y) => window.scrollTo(0, y), markTop - line + offset);
    await page.waitForTimeout(200);
    return page
      .locator(".groups")
      .evaluate((list) => list.getBoundingClientRect().top + window.scrollY);
  };
  const before = await listTop(-2);
  const after = await listTop(40);
  await expect(page.locator("[data-stick-card]")).toHaveClass(/is-stuck/);
  expect(after).toBeCloseTo(before, 0);
});

test("tab screenshots fill their crop", async ({ page }) => {
  for (const width of [1440, 390]) {
    await page.setViewportSize({ width, height: 900 });
    await page.goto("/");
    const panels = page.locator("[data-panel]:not([hidden]) .crop");
    const count = await panels.count();
    expect(count).toBe(3);
    for (let i = 0; i < count; i++) {
      const crop = panels.nth(i);
      await crop.scrollIntoViewIfNeeded();
      const fit = await crop.evaluate((box) => {
        const img = box.querySelector("img");
        const outer = box.getBoundingClientRect();
        const inner = img?.getBoundingClientRect();
        if (!img || !inner) return "missing";
        const covers =
          inner.left <= outer.left + 1 &&
          inner.top <= outer.top + 1 &&
          inner.right >= outer.right - 1 &&
          inner.bottom >= outer.bottom - 1;
        return covers && outer.height > 100 ? "ok" : "gap";
      });
      expect(fit).toBe("ok");
    }
  }
});

test.describe("card scenes keep their parts apart", () => {
  test.use({ reducedMotion: "reduce" });

  for (const path of ["/", "/it/"]) {
    for (const width of [1440, 390, 360]) {
      test(`${path} MCP tool pill stays inside the card at ${width}px`, async ({ page }) => {
        await page.setViewportSize({ width, height: 900 });
        await page.goto(path);
        const fit = await page.locator(".mcp").evaluate((scene) => {
          const top = () => scene.querySelector(".you")?.getBoundingClientRect().top ?? 0;
          scene.dataset.state = "tool";
          const edge =
            scene.getBoundingClientRect().right - parseFloat(getComputedStyle(scene).paddingRight);
          const room =
            edge - (scene.querySelector(".tool")?.getBoundingClientRect().right ?? Infinity);
          const before = top();
          scene.dataset.state = "answer";
          return { room, shift: Math.abs(top() - before) };
        });
        expect(fit.room).toBeGreaterThan(-0.5);
        expect(fit.shift).toBeLessThan(0.5);
      });
    }

    for (const width of [1440, 390]) {
      test(`${path} meeting slide title clears the alert at ${width}px`, async ({ page }) => {
        await page.setViewportSize({ width, height: 900 });
        await page.goto(path);
        const gap = await page.locator(".meeting").evaluate((scene) => {
          scene.dataset.state = "alert";
          const title = scene.querySelector(".shared p");
          const range = document.createRange();
          range.selectNodeContents(title ?? scene);
          const alert = scene.querySelector(".alert")?.getBoundingClientRect();
          return (alert?.left ?? 0) - range.getBoundingClientRect().right;
        });
        expect(gap).toBeGreaterThan(4);
      });

      test(`${path} link sources never cover the link sheet at ${width}px`, async ({ page }) => {
        await page.setViewportSize({ width, height: 900 });
        await page.goto(path);
        const overlaps = await page.locator(".link").evaluate((scene) => {
          const hit = (a: DOMRect, b: DOMRect) => a.top < b.bottom && a.bottom > b.top;
          const sources = scene.querySelector(".sources");
          if (!sources || getComputedStyle(sources).display === "none") return [];
          return ["empty", "typing", "press", "fetching", "writing", "done"].filter((state) => {
            scene.dataset.state = state;
            const row = sources.getBoundingClientRect();
            return [".sheet", ".result"].some((part) => {
              const element = scene.querySelector(part);
              if (!element || getComputedStyle(element).opacity === "0") return false;
              return hit(row, element.getBoundingClientRect());
            });
          });
        });
        expect(overlaps).toEqual([]);
      });
    }
  }
});

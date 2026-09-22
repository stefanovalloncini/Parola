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

import { expect, test } from "@playwright/test";

test.use({ reducedMotion: "reduce" });

test("reduced motion keeps the story readable and tabs still", async ({ page }) => {
  await page.goto("/");
  await expect(page.locator("[data-beat]").first()).toBeVisible();
  const playing = await page.locator("[data-tabs][data-playing]").count();
  expect(playing).toBe(0);
});

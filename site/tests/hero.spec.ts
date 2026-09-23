import { expect, test } from "@playwright/test";

const screens = [
  { width: 1440, height: 900 },
  { width: 1280, height: 720 },
  { width: 1024, height: 768 },
  { width: 390, height: 844 },
  { width: 360, height: 740 },
];

for (const path of ["/", "/it/"]) {
  for (const screen of screens) {
    test(`${path} hero fits a ${screen.width}×${screen.height} screen`, async ({ page }) => {
      await page.setViewportSize(screen);
      await page.goto(path);
      const fit = await page.evaluate(() => {
        const header = document.querySelector("[data-header]")?.getBoundingClientRect().height ?? 0;
        const device = document.querySelector("[data-device]")?.getBoundingClientRect();
        const laptop = document.querySelector("[data-device] .laptop")?.getBoundingClientRect();
        const band = (device?.top ?? 0) - header;
        const tallest = Math.max(
          ...[...document.querySelectorAll("[data-beat]")].map(
            (b) => b.getBoundingClientRect().height,
          ),
        );
        return { band, tallest, laptopBottom: laptop?.bottom ?? Infinity };
      });
      expect(fit.tallest).toBeLessThanOrEqual(fit.band);
      expect(fit.laptopBottom).toBeLessThanOrEqual(screen.height);
    });
  }
}

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

const desktops = [
  { width: 1280, height: 800 },
  { width: 1366, height: 768 },
  { width: 1440, height: 900 },
  { width: 1536, height: 864 },
  { width: 1920, height: 1080 },
  { width: 1280, height: 1024 },
  { width: 1600, height: 1200 },
];

for (const path of ["/", "/it/"]) {
  for (const screen of desktops) {
    test(`${path} hero files stay clear of the laptop at ${screen.width}×${screen.height}`, async ({
      page,
    }) => {
      await page.setViewportSize(screen);
      await page.goto(path);
      await expect(page.locator("[data-device]")).toHaveAttribute("data-scene", "0");
      const misplaced = await page.evaluate(() => {
        const laptop = [".lid", ".base"].map(
          (part) =>
            document.querySelector(`[data-device] .laptop ${part}`)?.getBoundingClientRect() ??
            new DOMRect(),
        );
        const parts = [...document.querySelectorAll(".props .files .prop :is(.page, .name)")];
        return parts
          .filter((part) => {
            const box = part.getBoundingClientRect();
            const offScreen =
              box.top < 0 ||
              box.left < 0 ||
              box.bottom > window.innerHeight ||
              box.right > document.documentElement.clientWidth;
            const underLaptop = laptop.some(
              (l) =>
                box.left < l.right &&
                box.right > l.left &&
                box.top < l.bottom &&
                box.bottom > l.top,
            );
            return offScreen || underLaptop;
          })
          .map((part) => part.closest(".prop")?.textContent?.trim() ?? "");
      });
      expect(misplaced).toEqual([]);
    });
  }
}

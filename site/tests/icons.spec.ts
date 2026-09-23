import { expect, test } from "@playwright/test";
import sharp from "sharp";

async function changedShare(before: Buffer, after: Buffer): Promise<number> {
  const [a, b] = await Promise.all(
    [before, after].map((png) => sharp(png).raw().toBuffer({ resolveWithObject: true })),
  );
  if (!a || !b) return 0;
  const { channels, width, height } = a.info;
  let changed = 0;
  for (let i = 0; i < a.data.length; i += channels) {
    const diff = Math.max(
      Math.abs((a.data[i] ?? 0) - (b.data[i] ?? 0)),
      Math.abs((a.data[i + 1] ?? 0) - (b.data[i + 1] ?? 0)),
      Math.abs((a.data[i + 2] ?? 0) - (b.data[i + 2] ?? 0)),
    );
    if (diff > 40) changed++;
  }
  return changed / (width * height);
}

const marks = [
  "intelligence",
  "ollama",
  "openai",
  "anthropic",
  "groq",
  "cerebras",
  "zoom",
  "webex",
  "youtube",
  "vimeo",
  "soundcloud",
  "x",
  "tiktok",
  "claude",
];

for (const path of ["/", "/it/"]) {
  test(`${path} draws every icon tile and brand mark`, async ({ page }) => {
    await page.setViewportSize({ width: 1440, height: 900 });
    await page.goto(path);
    const tiles = await page.locator("[data-tile]").evaluateAll((elements) =>
      elements.map((tile) => {
        const svg = tile.querySelector<SVGSVGElement>(":scope > svg");
        const box = svg?.getBoundingClientRect();
        const drawn = svg?.getBBox();
        return {
          name: tile.getAttribute("data-tile") ?? "",
          box: (box?.width ?? 0) * (box?.height ?? 0),
          drawn: (drawn?.width ?? 0) * (drawn?.height ?? 0),
        };
      }),
    );
    expect(tiles.length).toBeGreaterThan(50);
    expect(marks.filter((mark) => !tiles.some((tile) => tile.name === mark))).toEqual([]);
    const blank = tiles.filter((tile) => tile.box === 0 || tile.drawn === 0);
    expect(blank.map((tile) => tile.name)).toEqual([]);
  });
}

test("every brand mark and every tile hue paints something", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto("/");
  const count = await page.evaluate((names) => {
    const tiles = [...document.querySelectorAll<HTMLElement>("[data-tile]")];
    const hues = new Map<string, HTMLElement>();
    for (const tile of tiles) {
      const top = tile.style.getPropertyValue("--top");
      if (top && !hues.has(top)) hues.set(top, tile);
    }
    const shelf = document.createElement("div");
    shelf.id = "paint-check";
    shelf.style.cssText =
      "position:fixed;top:0;left:0;z-index:2147483647;display:flex;gap:8px;padding:8px;background:#fff;--u:1px;--unit:1px";
    const picks = [
      ...names.map((name) => tiles.find((tile) => tile.dataset.tile === name)),
      ...hues.values(),
    ];
    for (const tile of picks) if (tile) shelf.append(tile.cloneNode(true));
    document.body.append(shelf);
    return shelf.children.length;
  }, marks);
  expect(count).toBe(marks.length + 7);
  const shelf = page.locator("#paint-check > [data-tile]");
  for (let i = 0; i < count; i++) {
    const tile = shelf.nth(i);
    const shown = await tile.screenshot();
    await tile.evaluate((element) => {
      const svg = element.querySelector<SVGSVGElement>(":scope > svg");
      if (svg) svg.style.visibility = "hidden";
    });
    const hidden = await tile.screenshot();
    const name = (await tile.getAttribute("data-tile")) ?? "";
    expect.soft(await changedShare(shown, hidden), name).toBeGreaterThan(0.02);
  }
});

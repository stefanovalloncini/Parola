import { expect, test } from "@playwright/test";

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

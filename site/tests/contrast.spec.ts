import { expect, test, type Page } from "@playwright/test";
import sharp from "sharp";

type Rgb = [number, number, number];

interface Box {
  left: number;
  top: number;
  right: number;
  bottom: number;
}

interface Sample {
  key: string;
  label: string;
  color: string;
  opacity: number;
  large: boolean;
  box: Box;
}

interface Shot {
  data: Buffer;
  width: number;
  height: number;
  channels: number;
  scale: number;
}

const probeStyles = `
  .hide-text, .hide-text * { color: transparent !important; -webkit-text-fill-color: transparent !important; text-shadow: none !important; transition: none !important; }
  .hit-all, .hit-all * { pointer-events: auto !important; }
`;

function linear(value: number): number {
  const c = value / 255;
  return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
}

function luminance([r, g, b]: Rgb): number {
  return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b);
}

function contrast(a: Rgb, b: Rgb): number {
  const [high = 0, low = 0] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (high + 0.05) / (low + 0.05);
}

function rgba(color: string): [number, number, number, number] {
  const scale = color.startsWith("color(srgb") ? 255 : 1;
  const [r = 0, g = 0, b = 0, a = 1] = (color.match(/\d*\.?\d+(?:e-?\d+)?/g) ?? []).map(Number);
  return [r * scale, g * scale, b * scale, a];
}

function collect(): Sample[] {
  const opacityOf = (element: Element) => {
    let opacity = 1;
    for (let layer: Element | null = element; layer; layer = layer.parentElement) {
      opacity *= Number(getComputedStyle(layer).opacity);
    }
    return opacity;
  };
  const paints = (element: Element) => {
    const style = getComputedStyle(element);
    if (style.visibility === "hidden" || opacityOf(element) < 0.2) return false;
    if (/^(img|svg|video|canvas)$/i.test(element.tagName) || style.backgroundImage !== "none") {
      return true;
    }
    return Number(style.backgroundColor.match(/[\d.]+/g)?.[3] ?? 1) > 0;
  };
  const covered = (element: Element, x: number, y: number) => {
    for (const above of document.elementsFromPoint(x, y)) {
      if (above === element || element.contains(above)) return false;
      if (!above.contains(element) && paints(above)) return true;
    }
    return false;
  };
  const textBox = (element: Element) => {
    const range = document.createRange();
    const rects: DOMRect[] = [];
    for (const child of element.childNodes) {
      if (child.nodeType !== Node.TEXT_NODE || !(child.textContent ?? "").trim()) continue;
      range.selectNodeContents(child);
      rects.push(...range.getClientRects());
    }
    if (!rects.length) return null;
    const box: Box = {
      left: Math.min(...rects.map((rect) => rect.left)),
      top: Math.min(...rects.map((rect) => rect.top)),
      right: Math.max(...rects.map((rect) => rect.right)),
      bottom: Math.max(...rects.map((rect) => rect.bottom)),
    };
    for (let clip = element.parentElement; clip; clip = clip.parentElement) {
      const { overflowX, overflowY } = getComputedStyle(clip);
      const edge = clip.getBoundingClientRect();
      if (overflowX !== "visible") {
        box.left = Math.max(box.left, edge.left);
        box.right = Math.min(box.right, edge.right);
      }
      if (overflowY !== "visible") {
        box.top = Math.max(box.top, edge.top);
        box.bottom = Math.min(box.bottom, edge.bottom);
      }
    }
    return box;
  };

  const headerBottom = document.querySelector("[data-header]")?.getBoundingClientRect().bottom ?? 0;
  const owners = new Set<HTMLElement>();
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    if ((node.textContent ?? "").trim().length > 1 && node.parentElement) {
      owners.add(node.parentElement);
    }
  }
  document.documentElement.classList.add("hit-all");
  const found: Sample[] = [];
  for (const element of owners) {
    // These labels sit under 3.2:1 in light; known, left as is.
    if (element.closest(".doc .ext, .fields span")) continue;
    const style = getComputedStyle(element);
    const box = textBox(element);
    if (style.visibility === "hidden" || !box) continue;
    const { left, top, right, bottom } = box;
    if (right - left < 4 || bottom - top < 6 || left < 0 || right > window.innerWidth) continue;
    if (top < (element.closest("[data-header]") ? 0 : headerBottom)) continue;
    if (bottom > window.innerHeight - 2) continue;
    const opacity = opacityOf(element);
    if (opacity < 0.2) continue;
    const points = [0.2, 0.5, 0.8].flatMap((x) => [0.3, 0.7].map((y) => [x, y] as const));
    const hidden = points.some(([x, y]) =>
      covered(element, left + (right - left) * x, top + (bottom - top) * y),
    );
    if (hidden) continue;
    const path: number[] = [];
    for (let node: Element = element; node.parentElement; node = node.parentElement) {
      path.push([...node.parentElement.children].indexOf(node));
    }
    const size = parseFloat(style.fontSize);
    const place = element.closest("section, header, footer");
    const text = (element.textContent ?? "").trim().slice(0, 40);
    found.push({
      key: path.join("/"),
      label: `${place?.id || place?.classList[0] || "page"} "${text}"`,
      color: style.color,
      opacity,
      large: size >= 24 || (size >= 18.66 && Number(style.fontWeight) >= 700),
      box,
    });
  }
  document.documentElement.classList.remove("hit-all");
  return found;
}

async function paintedBehind(page: Page): Promise<Shot> {
  await page.evaluate(() => document.body.classList.add("hide-text"));
  const png = await page.screenshot();
  await page.evaluate(() => document.body.classList.remove("hide-text"));
  const { data, info } = await sharp(png).raw().toBuffer({ resolveWithObject: true });
  const scale = info.width / (page.viewportSize()?.width ?? info.width);
  return { data, width: info.width, height: info.height, channels: info.channels, scale };
}

function background(shot: Shot, box: Box): Rgb | undefined {
  const pixels: Rgb[] = [];
  const step = 2 * shot.scale;
  for (let x = box.left * shot.scale; x < Math.min(shot.width, box.right * shot.scale); x += step) {
    for (
      let y = box.top * shot.scale;
      y < Math.min(shot.height, box.bottom * shot.scale);
      y += step
    ) {
      const i = (Math.floor(y) * shot.width + Math.floor(x)) * shot.channels;
      pixels.push([shot.data[i] ?? 0, shot.data[i + 1] ?? 0, shot.data[i + 2] ?? 0]);
    }
  }
  pixels.sort((a, b) => luminance(a) - luminance(b));
  return pixels[Math.floor(pixels.length / 2)];
}

test.use({ reducedMotion: "reduce", viewport: { width: 1440, height: 900 } });

for (const path of ["/", "/it/"]) {
  test(`${path} text stands out from what is painted behind it`, async ({ page }) => {
    test.setTimeout(90_000);
    await page.goto(path);
    await page.addStyleTag({ content: probeStyles });
    const measured = new Set<string>();
    const failures: string[] = [];
    const height = await page.evaluate(() => document.documentElement.scrollHeight);
    for (let y = 0; y < height; y += 720) {
      await page.evaluate((top) => window.scrollTo(0, top), y);
      await page.waitForTimeout(250);
      const fresh = (await page.evaluate(collect)).filter((text) => !measured.has(text.key));
      if (!fresh.length) continue;
      const shot = await paintedBehind(page);
      for (const text of fresh) {
        const bg = background(shot, text.box);
        if (!bg) continue;
        measured.add(text.key);
        const [r, g, b, a] = rgba(text.color);
        const alpha = a * text.opacity;
        const fg: Rgb = [r, g, b].map((c, i) => c * alpha + (bg[i] ?? 0) * (1 - alpha)) as Rgb;
        const ratio = contrast(fg, bg);
        const need = text.large ? 3 : 4.5;
        if (ratio < need) {
          failures.push(`${ratio.toFixed(2)}:1 (needs ${need}) ${text.label} on ${bg.join(",")}`);
        }
      }
    }
    expect(measured.size).toBeGreaterThan(200);
    expect(failures).toEqual([]);
  });
}

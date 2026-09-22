import { writeFile } from "node:fs/promises";
import sharp from "sharp";
import { brandBars } from "../src/data/brand.ts";

const bars = brandBars
  .map(
    (b) =>
      `<rect x="${b.x}" y="${b.y}" width="${b.width}" height="${b.height}" rx="${b.width / 2}"/>`,
  )
  .join("");

const mark = (corner: number) =>
  `<svg xmlns="http://www.w3.org/2000/svg" viewBox="100 100 824 824">` +
  `<rect x="100" y="100" width="824" height="824" rx="${corner}" fill="#6b8a6b"/>` +
  `<g fill="#fcf2e6">${bars}</g></svg>`;

await writeFile(new URL("../public/favicon.svg", import.meta.url), mark(181.3) + "\n");
await sharp(Buffer.from(mark(0)), { density: 300 })
  .resize(180, 180)
  .png()
  .toFile(new URL("../public/apple-touch-icon.png", import.meta.url).pathname);
console.log("Wrote public/favicon.svg and public/apple-touch-icon.png");

import { existsSync, mkdirSync, statSync } from "node:fs";
import { fileURLToPath } from "node:url";
import sharp from "sharp";
import { crops } from "../src/data/crops.ts";

const assets = new URL("../src/assets/", import.meta.url);
const recipe = new URL("../src/data/crops.ts", import.meta.url);

export async function cropShots(): Promise<void> {
  const recipeTime = statSync(recipe).mtimeMs;
  for (const folder of ["", "it/", "dark/", "it/dark/"]) {
    mkdirSync(new URL(`crops/${folder}`, assets), { recursive: true });
    for (const [name, crop] of Object.entries(crops)) {
      const source = fileURLToPath(new URL(`shots/${folder}${name}.png`, assets));
      if (folder.includes("dark/") && !existsSync(source)) continue;
      const newest = Math.max(statSync(source).mtimeMs, recipeTime);
      for (const [variant, [x, y, width, height]] of Object.entries({
        wide: crop.wide,
        narrow: crop.narrow,
      })) {
        const target = fileURLToPath(new URL(`crops/${folder}${name}-${variant}.png`, assets));
        if (existsSync(target) && statSync(target).mtimeMs >= newest) continue;
        await sharp(source)
          .extract({ left: x * 2, top: y * 2, width: width * 2, height: height * 2 })
          .toFile(target);
      }
    }
  }
}

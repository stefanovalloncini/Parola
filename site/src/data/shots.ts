import type { ImageMetadata } from "astro";
import type { Locale } from "../i18n";

const names = [
  "hero-window",
  "drop-zone",
  "interview",
  "memo",
  "lecture",
  "export",
  "dark-speakers",
  "dark-karaoke",
  "dark-translation",
  "ai-summary",
  "ai-chat",
  "ai-prompts",
] as const;

export type ShotName = (typeof names)[number];

const english = import.meta.glob<ImageMetadata>("../assets/shots/*.png", {
  eager: true,
  import: "default",
});
const italian = import.meta.glob<ImageMetadata>("../assets/shots/it/*.png", {
  eager: true,
  import: "default",
});

function pick(files: Record<string, ImageMetadata>, folder: string, name: ShotName) {
  const image = files[`../assets/shots/${folder}${name}.png`];
  if (!image) throw new Error(`Missing screenshot ${folder}${name}.png`);
  return image;
}

export function shotsFor(locale: Locale): Record<ShotName, ImageMetadata> {
  const files = locale === "it" ? italian : english;
  const folder = locale === "it" ? "it/" : "";
  return Object.fromEntries(names.map((name) => [name, pick(files, folder, name)])) as Record<
    ShotName,
    ImageMetadata
  >;
}

type Rect = readonly [x: number, y: number, width: number, height: number];

export type TabShot = Exclude<ShotName, "hero-window" | "drop-zone">;

export interface Crop {
  wide: Rect;
  narrow: Rect;
  fade?: "both";
}

const pane: Rect = [244, 50, 936, 632];

export const crops: Record<TabShot, Crop> = {
  interview: { wide: pane, narrow: [256, 88, 400, 340] },
  memo: { wide: pane, narrow: [248, 96, 400, 340] },
  lecture: { wide: pane, narrow: [256, 96, 400, 340] },
  export: { wide: [214, 124, 754, 509], narrow: [214, 170, 400, 340] },
  "dark-speakers": { wide: pane, narrow: [256, 88, 400, 340] },
  "dark-karaoke": { wide: pane, narrow: [256, 300, 400, 340] },
  "dark-translation": { wide: pane, narrow: [480, 140, 400, 340], fade: "both" },
  "ai-summary": { wide: pane, narrow: [248, 96, 400, 340] },
  "ai-chat": { wide: pane, narrow: [252, 96, 400, 340] },
  "ai-prompts": { wide: [244, 64, 936, 632], narrow: [476, 60, 400, 340] },
};

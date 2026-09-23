import type { ImageMetadata } from "astro";
import type { Locale } from "../i18n";
import type { TabShot } from "./crops";

const names = [
  "hero-window",
  "drop-zone",
  "interview",
  "memo",
  "lecture",
  "export",
  "dark-speakers",
  "dark-translation",
  "ai-summary",
  "ai-chat",
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

const englishCrops = import.meta.glob<ImageMetadata>("../assets/crops/*.png", {
  eager: true,
  import: "default",
});
const italianCrops = import.meta.glob<ImageMetadata>("../assets/crops/it/*.png", {
  eager: true,
  import: "default",
});

export interface TabImages {
  wide: ImageMetadata;
  narrow: ImageMetadata;
}

export function tabShotFor(locale: Locale, name: TabShot): TabImages {
  const files = locale === "it" ? italianCrops : englishCrops;
  const folder = locale === "it" ? "it/" : "";
  const find = (variant: string) => {
    const image = files[`../assets/crops/${folder}${name}-${variant}.png`];
    if (!image) throw new Error(`Missing crop ${folder}${name}-${variant}.png`);
    return image;
  };
  return { wide: find("wide"), narrow: find("narrow") };
}

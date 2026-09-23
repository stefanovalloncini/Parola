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

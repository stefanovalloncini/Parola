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

const themedNames = [
  "hero-window",
  "drop-zone",
  "interview",
  "memo",
  "lecture",
  "export",
  "ai-summary",
  "ai-chat",
] as const;

export type ThemedShot = (typeof themedNames)[number];

const english = import.meta.glob<ImageMetadata>("../assets/shots/*.png", {
  eager: true,
  import: "default",
});
const italian = import.meta.glob<ImageMetadata>("../assets/shots/it/*.png", {
  eager: true,
  import: "default",
});
const englishDark = import.meta.glob<ImageMetadata>("../assets/shots/dark/*.png", {
  eager: true,
  import: "default",
});
const italianDark = import.meta.glob<ImageMetadata>("../assets/shots/it/dark/*.png", {
  eager: true,
  import: "default",
});

function pick(files: Record<string, ImageMetadata>, folder: string, name: string) {
  const image = files[`../assets/shots/${folder}${name}.png`];
  if (!image) throw new Error(`Missing screenshot ${folder}${name}.png`);
  return image;
}

export function shotsFor(locale: Locale, scheme?: "light"): Record<ShotName, ImageMetadata>;
export function shotsFor(locale: Locale, scheme: "dark"): Record<ThemedShot, ImageMetadata>;
export function shotsFor(
  locale: Locale,
  scheme: "light" | "dark" = "light",
): Record<ShotName, ImageMetadata> | Record<ThemedShot, ImageMetadata> {
  const folder = locale === "it" ? "it/" : "";
  if (scheme === "dark") {
    const files = locale === "it" ? italianDark : englishDark;
    return Object.fromEntries(
      themedNames.map((name) => [name, pick(files, `${folder}dark/`, name)]),
    ) as Record<ThemedShot, ImageMetadata>;
  }
  const files = locale === "it" ? italian : english;
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
const englishDarkCrops = import.meta.glob<ImageMetadata>("../assets/crops/dark/*.png", {
  eager: true,
  import: "default",
});
const italianDarkCrops = import.meta.glob<ImageMetadata>("../assets/crops/it/dark/*.png", {
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

export function darkTabShotFor(locale: Locale, name: TabShot): TabImages | undefined {
  if (name === "dark-speakers" || name === "dark-translation") return undefined;
  const files = locale === "it" ? italianDarkCrops : englishDarkCrops;
  const folder = locale === "it" ? "it/" : "";
  const find = (variant: string) => {
    const image = files[`../assets/crops/${folder}dark/${name}-${variant}.png`];
    if (!image) throw new Error(`Missing crop ${folder}dark/${name}-${variant}.png`);
    return image;
  };
  return { wide: find("wide"), narrow: find("narrow") };
}

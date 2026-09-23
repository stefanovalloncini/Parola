export type Locale = "en" | "it";

export const locales: readonly Locale[] = ["en", "it"];

export function localeOf(value: string | undefined): Locale {
  return value === "it" ? "it" : "en";
}

/** Picks the copy for the page's locale; every string on the site is written in both languages side by side. */
export function translator(value: string | undefined) {
  const locale = localeOf(value);
  return <T>(copy: Record<Locale, T>): T => copy[locale];
}

/** The same page in another locale: `/privacy` ↔ `/it/privacy`, `/` ↔ `/it/`. */
export function switchPath(locale: Locale, path: string): string {
  const missing = pathFor("en", path).startsWith("/404");
  return pathFor(locale, missing ? "/" : path);
}

export function pathFor(locale: Locale, path: string): string {
  const bare = path.replace(/^\/it(?=\/|$)/, "") || "/";
  return locale === "it" ? `/it${bare === "/" ? "/" : bare}` : bare;
}

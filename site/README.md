# Parola website

The marketing site for Parola. Astro, TypeScript and plain CSS, built to static files.

## Work on it

```sh
pnpm install
pnpm dev
```

`pnpm gate` runs everything a commit needs: type check, lint, formatting, the copy check,
the build and the Playwright tests.

## Assets

- `src/assets/shots/` holds captures of the real app, 1180 × 760 pt at 2x. `src/assets/shots/it/`
  has the same set with the app running in Italian. The build cuts the tab shots into
  `src/assets/crops/` (ignored by git) using the rectangles in `src/data/crops.ts`: a wide one and a
  phone close-up for each, in points.
- The karaoke card reads the app's own demo clip from
  `ParolaApp/ParolaApp/Resources/Introduction/`, so a new recording there shows up here too.
- `pnpm brand` redraws `public/favicon.svg` and `public/apple-touch-icon.png` from the icon's bar
  geometry in `src/data/brand.ts`.
- `pnpm og` renders `public/og.png` and `public/og-it.png` from `/og-card` and `/it/og-card`
  while `pnpm dev` is running.

## Languages

English is served at `/` and Italian at `/it/`. Components pick their strings with
`translator(Astro.currentLocale)` from `src/i18n`, so both languages sit next to each other in
the same file. The build moves the Italian 404 page to `it/404.html`, where Cloudflare looks for it.

## Deploy

The build in `dist/` is plain static files. `wrangler.jsonc` serves it from Cloudflare:

```sh
SITE_URL=https://example.com pnpm build
pnpm dlx wrangler deploy
```

Set `SITE_URL` to the real domain so canonical links and the social card use absolute URLs. The sitemap and
the `Sitemap:` line in `robots.txt` are only generated when it is set.

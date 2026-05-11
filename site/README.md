# porter.md — site

Marketing site for MediaPorter. Astro 5, static output, deployed to Cloudflare Pages.

## Stack

- **Astro 5** — static site generator. No JS shipped by default.
- **Cloudflare Pages** — host. `wrangler.toml` is in this folder.
- **Design tokens** live in `../brand/tokens.css` (imported by `src/styles/global.css`). Edit them there, not here.

## Develop

```bash
cd site
npm install
npm run dev          # http://localhost:4321
```

## Build & deploy

```bash
npm run build        # → dist/
npm run preview      # local preview of the built site
npm run deploy       # build + wrangler pages deploy dist --project-name=porter-md
```

The first deploy needs:
1. `npx wrangler login` (one-time).
2. A Pages project named `porter-md` (the deploy command creates it if missing).
3. Custom domain `porter.md` attached in the Cloudflare dashboard, pointing CNAME at the Pages project.

## Structure

```
site/
  astro.config.mjs       # site: https://porter.md, static output
  wrangler.toml          # Cloudflare Pages config
  package.json
  tsconfig.json
  public/
    favicon.svg          # mark, accent pink
  src/
    layouts/
      Base.astro         # <html>, head, header, footer slot
    components/
      Header.astro       # sticky vibrancy header with wordmark + .md TLD nod
      Footer.astro
      MarkAnimated.astro # hero mark with stroke-dasharray draw-in
    pages/
      index.astro        # landing: hero, features, how-it-works, download
      privacy.astro      # required for App Store
      support.astro      # required for App Store
      changelog.astro    # release notes (static for now; auto-gen later)
    styles/
      global.css         # resets, layout primitives, .md decorative styles
```

## Design notes

The site leans into the `.md` TLD: code-style accents (`## heading`, `# comments`, mono tags), monospace
for technical labels, syntax-coloured code strip in the hero. The structure stays macOS-native: vibrancy
header, dark surfaces, accent pink (`#EC4899`), SF Pro / SF Pro Rounded / SF Mono stack.

All visual tokens come from `../brand/`. Do not hard-code colours or fonts in components — extend
`brand/tokens.css` and re-import.

## What's intentionally not here

- **No tracking, no analytics.** The privacy page promises it; the site reflects it.
- **No webfont downloads.** macOS/iOS visitors get the real SF stack; others get system rounded/mono.
- **No JS framework.** Astro outputs static HTML. If a future feature needs an island (compare-view, e.g.),
  add it then — not preemptively.

## Notes for future updates

- When the App Store build ships, drop the email-capture form and replace it with a real download link
  (and a Mac App Store badge).
- Once `CHANGELOG.md` at repo root stabilizes a format, convert `pages/changelog.astro` to a content
  collection that reads from it directly.
- App icon master needs to be re-cut in a vector tool from `designideas/grok.jpg` before App Store
  submission — see `../brand/appstore/README.md`.

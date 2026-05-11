# MediaPorter Brand

Single source of truth for visual identity. The site (`/site/`) and MacApp consume this — do not duplicate values, reference these files.

## Concept

**Name:** MediaPorter
**Domain:** porter.md
**Tagline (primary):** Media, ported.
**Tagline (secondary):** Deep on your devices.
**Voice:** concrete, technical, low-marketing. We say what the tool does, not how it makes you feel.

The `.md` TLD is a happy accident we lean into: the site treats Markdown as a **decorative language** — code-style accents (`# heading`, `**bold**`, `>` blockquotes, syntax-highlighted code blocks) layered over a macOS-native dark UI. Not a full retro-terminal theme; just subtle nods that say "made by people who live in editors."

## Mark concept

Integrated handoff: a film card (source) whose strip extrudes into a stylized **M** path, terminating in an iPad silhouette with a play triangle "docked" at the screen corner. One continuous gesture: media → port → device.

Authoritative references in `designideas/` (gemini.jpg, grok.jpg, gpt.png). The SVGs in `logo/` are working approximations — final 1024pt App Store master must be re-cut in a vector tool with proper bezier curves before submission.

## Color

| Token            | Hex       | Use                                              |
| ---------------- | --------- | ------------------------------------------------ |
| `--accent`       | `#EC4899` | Wordmark "Porter", CTAs, mark fill, link hover   |
| `--accent-soft`  | `#F9A8D4` | Hover halos, subtle gradients                    |
| `--accent-deep`  | `#BE185D` | Pressed state, dark-on-pink text                 |
| `--bg`           | `#0A0A0C` | App background (near-black, slight cool cast)    |
| `--surface`      | `#141418` | Cards, elevated panels                           |
| `--surface-2`    | `#1C1C22` | Hover/elevated state                             |
| `--border`       | `#2A2A33` | Hairlines, dividers                              |
| `--text`         | `#F5F5F7` | Primary text (macOS label)                       |
| `--text-2`       | `#A1A1AA` | Secondary text                                   |
| `--text-3`       | `#71717A` | Tertiary / captions                              |
| `--code-bg`      | `#16161B` | Code blocks, .md accents                         |
| `--code-comment` | `#6B7280` | Comments in code samples                         |
| `--ok`           | `#34D399` | Success / "synced" badge                         |
| `--warn`         | `#F59E0B` | Warnings                                         |
| `--err`          | `#F87171` | Errors                                           |

Light mode is **not** a priority for v1 — the app is dark-only and the site follows.

## Typography

- **SF Pro Display / Text** — primary UI, body. Web fallback: `-apple-system, BlinkMacSystemFont, "SF Pro Display", "Inter", sans-serif`.
- **SF Pro Rounded** — wordmark, large display headings (h1/hero). Web fallback: `-apple-system-rounded, "SF Pro Rounded", "Nunito", sans-serif`.
- **SF Mono** — code blocks, `.md` decorative accents, version numbers, technical labels. Web fallback: `ui-monospace, "SF Mono", "JetBrains Mono", monospace`.

We do **not** self-host webfonts in v1. macOS/iOS visitors get the real SF stack; others get system rounded/mono. Acceptable trade-off for porter.md's likely audience.

Scale (rem, base 16):
- `h1` 3.5 (display) — SF Pro Rounded, weight 700, tracking -0.02em
- `h2` 2.25 — Rounded, 600
- `h3` 1.5 — SF Pro, 600
- `body` 1.0625 — SF Pro, 400, line-height 1.65
- `caption` 0.875 — SF Pro, 500
- `code` 0.9375 — SF Mono, 400

## Iconography

- **App icon family** — squircle, glossy dark gradient base (matches macOS Big Sur+ icon language), pink mark centered. Sizes per Apple HIG: 16/32/64/128/256/512/1024 @1x and @2x.
- **Inline UI icons** — prefer SF Symbols where the MacApp uses them; for web, use [Lucide](https://lucide.dev) with stroke `1.75`, color `currentColor`. Don't mix icon sets.
- **Monochrome mark** — required for menu bar template (`16x16` @1x, `32x32` @2x), tinted/dark/light/system-blue variants per the mockup. Stored in `logo/mark-mono-*.svg`.

## Motion

- Default easing: `cubic-bezier(0.32, 0.72, 0, 1)` (Apple-ish snappy).
- Default duration: 200ms for micro-interactions, 400ms for hero/state transitions.
- **Mark animation:** on hero load, the film-strip-to-iPad path draws via `stroke-dasharray` over 900ms, then the play triangle fades in. Once. No idle loop — looping logos are nervous.
- Respect `prefers-reduced-motion: reduce` — disable the draw-in entirely.

## Spacing & radius

Spacing scale: `4, 8, 12, 16, 24, 32, 48, 64, 96, 128` (px). Use the scale; don't invent in-between values.

Radius:
- `--r-sm` 6px — inputs, small buttons
- `--r-md` 10px — cards
- `--r-lg` 16px — hero panels
- `--r-xl` 22.37% — App icon squircle ratio (Apple HIG)

## Files

```
brand/
  README.md              # this file
  tokens.json            # machine-readable design tokens
  tokens.css             # CSS custom properties (imported by site/)
  logo/
    wordmark.svg         # "MediaPorter" lockup, dark bg
    wordmark-light.svg   # for light backgrounds
    mark.svg             # full-color mark, transparent bg
    mark-mono.svg        # single-color, currentColor
    icon-mask.svg        # squircle mask for app icon generation
  appstore/
    README.md            # asset checklist + delivery spec
    copy.md              # marketing copy drafts (subtitle, description, keywords)
    screenshots/         # placeholders — real shots produced from MacApp
```

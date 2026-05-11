# App Store Submission Pack

Checklist of assets required for Mac App Store + iOS/iPadOS submission. Apple Developer Program application is in flight (submitted 2026-05-11); collect these in parallel.

## Required URLs (set in App Store Connect → App Information)

- **Marketing URL:** `https://porter.md`
- **Support URL:** `https://porter.md/support`
- **Privacy Policy URL:** `https://porter.md/privacy`

All three live in `site/` and are part of the v1 launch scope.

## App Icon

Apple now accepts a single **1024×1024 PNG** (or layered Xcode asset) and renders all variants. Provide:

- `icon-1024.png` — sRGB, no alpha, no rounded corners (Apple applies the mask).
- `icon-1024@dark.png` — optional dark variant (iOS 18+).
- `icon-1024@tinted.png` — optional tinted variant (iOS 18+).
- macOS additionally wants: 16, 32, 64, 128, 256, 512, 1024 @1x and @2x — generate from `1024` master.

**Current status:** master needs to be cut from `designideas/grok.jpg` reference in a vector tool (Affinity / Figma / Sketch) — the working SVG in `../logo/mark.svg` is a usable approximation for the site but the App Store master must be hand-tuned with proper bezier curves, gloss gradient, and inner highlight to match the rendered mockups.

## Screenshots

### iPhone (if shipping a viewer/companion later)
- 6.9" (iPhone 16 Pro Max): 1320 × 2868 px
- 6.5" (iPhone 11 Pro Max): 1242 × 2688 px (legacy, only if 6.9" not provided)

### iPad
- 13" (iPad Pro M4): 2064 × 2752 px

### Mac
- 1280 × 800, 1440 × 900, 2560 × 1600, or 2880 × 1800 px (one set, pick highest available)

**Plan:** 5–8 shots per platform showing: device picker, drag-drop, transcoding plan preview, sync progress, completed library on iPad TV app. Templates land in `screenshots/templates/` (Figma frames with bezel + caption slots) once the MacApp UI is feature-frozen.

## Marketing copy

Drafts live in `copy.md`. Required fields:

- **App name** (30 chars): `MediaPorter`
- **Subtitle** (30 chars): see `copy.md`
- **Promotional text** (170 chars, editable post-launch): see `copy.md`
- **Description** (4000 chars): see `copy.md`
- **Keywords** (100 chars, comma-separated): see `copy.md`
- **What's New** (4000 chars per release): pulled from `CHANGELOG.md`

## Categories

- **Primary:** Utilities
- **Secondary:** Photo & Video

## Age rating

4+ (no objectionable content; user-supplied media).

## App Privacy (Data Collected)

We do **not** collect data. Configure as: "Data Not Collected" across all categories. The app talks only to:

- The user's local iOS/iPadOS device over USB/Wi-Fi (Apple Mobile Device tunnel).
- TheMovieDB (TMDb) for metadata enrichment — TMDb requests carry no user PII; document this in `site/privacy`.

## Export compliance

The app uses standard HTTPS to TMDb only — qualifies for the **exempt** category. File `ITSAppUsesNonExemptEncryption = false` in Info.plist.

## Code signing & notarization

Once Apple Developer Program is approved:

1. Generate Developer ID Application + Mac App Distribution certificates in Keychain.
2. Update `MacApp/.../Info.plist` with team-prefixed bundle ID (e.g. `md.porter.MediaPorter`).
3. Add `--sign` + `--entitlements` to the build pipeline.
4. Notarize via `notarytool submit --apple-id … --team-id … --keychain-profile`.
5. Staple: `xcrun stapler staple MediaPorter.app`.

Build pipeline scripting will live in `MacApp/` — not in `brand/`.

## Files in this folder

```
appstore/
  README.md           # this checklist
  copy.md             # marketing copy drafts
  screenshots/        # platform-grouped screenshot assets (added later)
    templates/        # Figma/Affinity bezel templates
    mac/
    ipad/
    iphone/
```

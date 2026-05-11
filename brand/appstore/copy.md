# App Store Marketing Copy — Drafts

All copy targets the app's actual capabilities. No invented features. Tone: concrete, technical, low-fluff.

## App name (30 chars max)

```
MediaPorter
```
*11 chars.*

## Subtitle (30 chars max) — candidates

```
1. Sync video to the TV app
2. Media, ported. Anywhere.
3. Drop. Transcode. Watch.
4. Native sync for iPad TV
```
**Recommended:** #1 — names the actual job; will rank for "TV app sync."

## Promotional text (170 chars, editable anytime)

```
Drag a folder of movies and shows onto MediaPorter. It transcodes the smart way,
fixes audio, fills in metadata, and syncs straight into the iPad TV app — no iTunes, no cables required.
```

## Description (4000 chars)

```
MediaPorter ports your video library onto iPhone and iPad — straight into the
built-in TV app, with full metadata, posters, and proper episode order.

No iCloud round-trip. No browser uploader. No "watch on the laptop" workaround.
The app talks directly to your device over USB or Wi-Fi using the same protocol
Apple's own sync uses.


WHY IT EXISTS

The iPad TV app is the best video player Apple ships — chapters, AirPlay,
gesture scrubbing, sleep timers, all of it. But getting your own files in there
has been a closed door since iTunes was retired. MediaPorter opens it.


WHAT IT DOES

• Smart transcoding. Only re-encodes what your device can't play natively.
  HEVC stays HEVC (with the right tags). AAC and EAC3 are passed through.
  AC3 is converted to AAC because the iPad TV app silently drops AC3 tracks
  from its audio switcher — we noticed, so you don't have to.

• Metadata that actually shows up. Posters, season/episode numbers, sort
  titles, TV show artwork. Episodes group correctly. No "0." prefix bug.

• Anime-aware. Detects sequential episodes, handles burned-in episode numbers,
  and matches against AniDB / TMDb.

• Pipelined sync. Files appear in the TV app as they finish uploading,
  not after a 30-minute "finalizing…" wall at the end.

• Native macOS app. Built in Swift, dark by default, vibrancy where Apple
  uses vibrancy. Quits cleanly. Doesn't sit in the menu bar unless you ask.


WHAT IT DOES NOT DO

• It does not collect data. Not telemetry, not crash logs, not "anonymous
  usage." See porter.md/privacy.

• It does not stream. Files land on your device and play offline.

• It does not modify your source library. Originals are untouched.


REQUIREMENTS

• macOS 14 or later
• An iPhone, iPad, or iPod touch running iOS / iPadOS 15 or later
• A USB-C or Lightning cable (Wi-Fi sync supported after first USB pairing)


Questions, bug reports, feature requests: porter.md/support
```

## Keywords (100 chars max, comma-separated, no spaces after commas)

Candidates (pick to fit budget):

```
tv app,sync,ipad,video,transcode,mkv,mp4,mp3,airdrop,handbrake,vlc,infuse,plex,m4v,subtitles,4k,hevc
```

**Recommended cut (98 chars):**

```
tv app,sync,ipad,video,transcode,mkv,mp4,handbrake,infuse,plex,m4v,subtitles,hevc,4k,offline
```

Avoid using competitor names verbatim where Apple flags them (Plex, Infuse). Final list to be A/B tested after launch.

## What's New (per release)

Pulled from `CHANGELOG.md`. Format:

```
• [user-facing change] — one line
• [next change] — one line
```

Keep under ~8 bullets per release; collapse internal refactors.

# iPad TV App Audio Language Switcher — The Real Rule

**Date:** 2026-04-13
**Status:** Confirmed experimentally on iPad Pro 12.9" (3rd gen), iPadOS 17+
**Supersedes:** CLAUDE.md finding #15 (2026-04-06), which claimed mixed audio codecs break the switcher. That was wrong — the real rule is codec-specific.

## The rule

> **AAC and EAC3 audio tracks are listed in the iPad TV app's audio-language selector. AC3 tracks are silently excluded from the list but still decode and play.**
>
> Additional constraints:
> - The switcher appears only if **≥2 listable** (non-AC3) tracks are present.
> - **Exactly one** track must carry the `default` disposition. Multiple defaults break the switcher entirely.
> - The MP4 muxer (`ffmpeg -f mp4`) **always** forces at least one audio track to be default, so "zero defaults" is not achievable.
> - Duplicate languages and duplicate titles across tracks are fine; the switcher does not deduplicate them.

## Why this matters

The previous assumption ("mixed codecs break the switcher, normalize to a common codec") forced mediaporter to re-encode **every** audio track of a mixed-codec file. Real-world rips typically mix one AC3 dub with an EAC3 original, so the old rule cost a full re-encode of both tracks even though the correct fix is to re-encode only the AC3.

The correct rule maps to a much cheaper transcode plan:
- `aac` → copy
- `eac3` → copy
- `ac3` → transcode to AAC (stereo 192k / 5.1 384k)
- anything else → transcode to AAC

It also explains a long-running confusion: "sometimes the switcher works with mixed codecs, sometimes it doesn't." The files where it worked had no AC3 track; the files where it didn't had AC3 among the audio streams.

## Evidence

**Source:** `The.Luckiest.Man.in.America.2024.AMZN.WEB-DL.1080p.mkv` — 4 audio tracks: `rus ac3 2ch`, `rus ac3 2ch` (different dub, same language), `ukr aac 2ch`, `eng eac3 5.1`. Each test is a 90-second clip at the same timestamp, remuxed with the variation below. Test harness: `scripts/test_audio_switcher.py`. Synced to iPad and observed in the TV app.

| # | Audio layout | Dispositions | Switcher shows | Outcome |
|---|---|---|---|---|
| A | 4× copy (ac3, ac3, aac, eac3) | **all 4 default** | nothing | "all default" breaks switcher entirely |
| B | 4× copy (ac3, ac3, aac, eac3) | one default | **aac + eac3 only** (both ac3 dropped) | ac3 silently filtered from list |
| C | as B + distinct titles per track | one default | same as B | titles/labels irrelevant to the filter |
| D | 4× aac (all normalized) | one default | **all 4** (correctly labelled) | control — confirms uniform codec works |
| E | ac3 + eac3 only | one default | nothing | ac3 dropped → 1 track left → no switcher |
| F | **ac3→aac transcode + aac+eac3 copy** (4 total: 3× aac + 1× eac3) | one default | **all 4** | **the fix** — only AC3s re-encoded |
| G | ac3→eac3 transcode + aac+eac3 copy (3× eac3 + 1× aac) | one default | all 4 | EAC3 also valid as transcode target |
| H | aac + eac3 only (no ac3 at all) | one default | both tracks | non-AC3 mixed codecs work fine |
| I | 4× copy, tried to clear all defaults | mp4 muxer forced a:0 default → same as B | aac + eac3 only | mp4 muxer always forces one default |
| J | 2× ac3 only (both Russian) | one default | nothing | 0 listable tracks → no switcher |
| K | ac3 + aac + eac3 (1 of each, 3 languages) | one default | aac + eac3 only | ac3 dropped; other two listed |

Every observation is consistent with **"AAC and EAC3 are listable, AC3 is not, need ≥2 listable tracks, exactly one default."** No other single-rule explanation fits all 11 cases.

## Mechanism (likely)

This matches AVFoundation's `AVMediaSelectionGroup` behavior for `AVMediaCharacteristicAudible`. AC3 is playable on iOS but is not included in the audible media-selection group by default. Apple's TN2429 describes the authoring path for mixed Dolby + AAC files: each non-AAC track must carry a `tref 'fall'` fallback reference to an AAC fallback track, and all audio tracks must be members of the same alternate group. ffmpeg does not produce `tref fall` associations, so the only reliable way to get an AC3 track into the selector from ffmpeg is to replace it with AAC or EAC3.

EAC3 appears to be granted the same selectable status as AAC (confirmed by variants F, G, H, and the B/C results where the single EAC3 5.1 track was listed).

## Fix applied in mediaporter

Committed in 0.3.2:
- `compat.py`: `ac3` removed from `COMPATIBLE_AUDIO_CODECS`. AC3 streams now evaluate as "transcode".
- `audio.py`: `classify_audio_stream` transcodes AC3 (and everything non-AAC/EAC3/ALAC/MP3) to AAC at matching channels. `pick_normalization_codec` and `target_bitrate_for` deleted — they exist to work around the now-disproven mixed-codec rule.
- `transcode.py`: always emits `-disposition:a:0 default -disposition:a:N 0` for remaining audio outputs, guaranteeing exactly one default regardless of source state. The old `norm_codec` branch is gone.
- `pipeline.py::_partition_jobs`: no longer force-remuxes on mixed codecs. A file with AC3 will still partition to `needs_transcode` because `compat.evaluate_compatibility` marks it so.
- `progress.py`: stream-action display stops consulting `pick_normalization_codec` and just reads from `decision.stream_actions`.

## References

- Apple Technical Note TN2429 — *Creating media files for Apple TV that contain a Dolby Digital (AC-3) and/or Dolby Digital Plus (Enhanced AC-3) audio track*: describes the fallback track / alternate-group authoring path ffmpeg cannot produce.
- `scripts/test_audio_switcher.py` — reproducible test harness, 11 variants A–K with labeled covers.
- `test_fixtures/audio_switcher/` — the synthesized clips (gitignored).

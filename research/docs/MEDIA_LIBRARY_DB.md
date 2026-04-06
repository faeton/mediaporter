# MediaLibrary.sqlitedb Schema Analysis

## Overview

The iOS media library database at `/var/mobile/Media/iTunes_Control/iTunes/MediaLibrary.sqlitedb` (accessible via AFC) stores all media items visible in the TV, Music, and Podcasts apps.

**Source:** Dumped from iPad8,7 running iOS 26.3.1 on 2026-04-01.

**Key Finding:** Direct modification of this database does NOT work on modern iOS. `medialibraryd` daemon detects unauthorized changes and reverts them within seconds. Media must be synced through the `com.apple.atc` (AirTrafficControl) service instead.

## Database Files

| File | Purpose |
|------|---------|
| `MediaLibrary.sqlitedb` | Main SQLite database |
| `MediaLibrary.sqlitedb-wal` | Write-Ahead Log (contains most recent data) |
| `MediaLibrary.sqlitedb-shm` | Shared memory file |
| `iTunesCDB` | Binary iTunesDB (`mhbd` format, legacy) |
| `IC-Info.sidf` | Integrity/signing data (384 bytes) |
| `IC-Info.sidv` | Integrity/verification data (1140 bytes) |

## Key Tables

### `item` — Core media entry

| Column | Type | Description |
|--------|------|-------------|
| `item_pid` | INTEGER PK | Unique ID (large random int, ~18 digits) |
| `media_type` | INTEGER | 2048 = video |
| `title_order` | INTEGER | Sort key from `sort_map` table |
| `title_order_section` | INTEGER | Alphabetical section (A=0, B=1...) |
| `series_name_order` | INTEGER | Sort key for TV show grouping |
| `album_pid` | INTEGER | FK to `album` table |
| `base_location_id` | INTEGER | FK to `base_location` (which F-directory) |
| `in_my_library` | INTEGER | 1 = visible in Library. **Set by trigger on item_store** |
| `date_added` | INTEGER | Apple epoch timestamp (seconds since 2001-01-01) |
| `keep_local` | INTEGER | 1 = keep on device |
| `keep_local_status` | INTEGER | 2 = kept |

### `item_extra` — Extended metadata

| Column | Type | Description |
|--------|------|-------------|
| `item_pid` | INTEGER PK | FK to item |
| `title` | TEXT | Display title |
| `sort_title` | TEXT | Title for sorting |
| `total_time_ms` | REAL | Duration in milliseconds |
| `year` | INTEGER | Release year |
| `location` | TEXT | Filename only (e.g., "PTHW.mp4") |
| `file_size` | INTEGER | Bytes |
| `media_kind` | INTEGER | **2 = Movie, 32 = TV Show** |
| `description` | TEXT | Short plot (≤255 chars) |
| `description_long` | TEXT | Full plot |
| `location_kind_id` | INTEGER | 4 = local synced file |

### `item_video` — Video-specific metadata

| Column | Type | Description |
|--------|------|-------------|
| `item_pid` | INTEGER PK | FK to item |
| `video_quality` | INTEGER | 0=SD, 1=720p, 2=1080p, 3=4K |
| `season_number` | INTEGER | TV show season |
| `episode_id` | TEXT | "S01E01" format |
| `network_name` | TEXT | "AMC", "HBO", etc. |
| `extended_content_rating` | TEXT | "mpaa\|R\|400" format |
| `movie_info` | TEXT | XML plist with cast/directors |
| `has_subtitles` | INTEGER | Boolean |
| `has_alternate_audio` | INTEGER | Boolean |

### `item_store` — Sync/purchase metadata

| Column | Type | Description |
|--------|------|-------------|
| `item_pid` | INTEGER PK | FK to item |
| `sync_id` | INTEGER | Unique sync identifier (large random) |
| `sync_in_my_library` | INTEGER | 1 = synced and in library |
| `sync_redownload_params` | TEXT | Empty for local, "redownload" for cloud |
| `purchase_history_id` | INTEGER | 0 for sideloaded content |
| `store_item_id` | INTEGER | 0 for sideloaded content |

**Critical:** SQL triggers on `item_store` automatically set `item.in_my_library` based on `sync_id` and `sync_in_my_library` values.

### `base_location` — Directory mapping

| Column | Type | Description |
|--------|------|-------------|
| `base_location_id` | INTEGER PK | ID (3840=F00, 3841=F01, etc.) |
| `path` | TEXT | "iTunes_Control/Music/F00" etc. |

### `album` — Album/show container

| Column | Type | Description |
|--------|------|-------------|
| `album_pid` | INTEGER PK | Unique ID |
| `album` | TEXT | Album name (often empty for movies) |
| `season_number` | INTEGER | TV season number |
| `album_year` | INTEGER | Year |
| `representative_item_pid` | INTEGER | First item in album |

### `sort_map` — Title sorting

| Column | Type | Description |
|--------|------|-------------|
| `name` | TEXT UNIQUE | Title text |
| `name_order` | INTEGER UNIQUE | Sort position (large increments) |
| `name_section` | INTEGER | Alphabet section (A=0..Z=25, #=27) |
| `sort_key` | BLOB | Binary sort key |

## Example: ATC-Synced Movie Entry

```sql
-- item
item_pid=611924357551419737, media_type=2048, base_location_id=3880,
in_my_library=1, date_added=796733478, keep_local=1, keep_local_status=2

-- item_extra
title="Good Luck Have Fun Dont Die", location="PTHW.mp4",
media_kind=2, file_size=7563049541, total_time_ms=8067104.0, year=2025,
location_kind_id=4

-- item_video
video_quality=1, movie_info="<plist>...<cast>Sam Rockwell...</cast></plist>"
extended_content_rating="mpaa|R|400"

-- item_store
sync_id=1140955219063971701, sync_in_my_library=1,
purchase_history_id=0, store_item_id=0

-- base_location (id=3880)
path="iTunes_Control/Music/F40"
```

## File Naming Convention

- Files in `iTunes_Control/Music/F00-F49/`
- 4-character uppercase filenames: `PTHW.mp4`, `VZIX.mp4`, `AHZD.m4v`
- Extension: `.mp4` or `.m4v`
- F-directory distribution: seemingly random/hashed

## Apple Epoch

Timestamps are seconds since **2001-01-01 00:00:00 UTC** (Apple/Core Data epoch).

```python
import time
apple_timestamp = int(time.time() - 978307200)
```

## What Didn't Work

1. **Direct SQL injection** — medialibraryd reverts unauthorized changes within seconds
2. **Pushing modified DB + empty WAL** — Device rebuilds DB from scratch, losing ALL data
3. **Notification-triggered reload** — syncWillStart/syncDidFinish notifications alone don't make medialibraryd accept foreign DB entries

## Finder Sync Entry (Reference)

A video synced via Finder (through ATC protocol) on iOS 26.3.1 looks like:

```
item.media_type            = 8192        (NOT 2048 — this is "Home Video" type)
item.base_location_id      = 3859        (→ iTunes_Control/Music/F19)
item.exclude_from_shuffle  = 1
item.keep_local            = 1
item.keep_local_status     = 2
item.in_my_library         = 1           (set by trigger on item_store)
item.disc_number           = 1

item_extra.title           = "test_everything"
item_extra.location        = "TFKA.m4v"  (4-char random name)
item_extra.file_size       = 2473890
item_extra.total_time_ms   = 4999.0
item_extra.media_kind      = 1024        (NOT 2 — "Home Video" kind)
item_extra.location_kind_id = 4
item_extra.integrity       = 57-byte blob (Grappa-signed file hash)

item_video.has_subtitles   = 1

item_store.sync_id         = <random 64-bit>
item_store.sync_in_my_library = 1

album.sync_id              = <random 64-bit>
album.keep_local_status    = 2
```

### Key Differences: Finder vs mediaporter Sync

| Field | Finder sync | mediaporter sync |
|-------|-------------|------------------|
| `media_type` | 8192 | 2048 |
| `media_kind` | 1024 | 2 |
| `integrity` | 57-byte signed hash | 10-byte blob |
| Classification | "Home Video" | "Movie" |

### The `integrity` Field

57 bytes, starts with `0x0400`. NOT a simple file hash (SHA-256/SHA-1/MD5 don't match). Likely a **Grappa-signed hash** computed during the ATC sync session. This may be what medialibraryd checks to validate entries.

## What Works

The `com.apple.atc` service is the only supported path. See `ATC_PROTOCOL.md`.

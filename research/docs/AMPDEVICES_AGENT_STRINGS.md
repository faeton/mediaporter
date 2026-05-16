# AMPDevicesAgent string-table mining — 2026-05-16

Source: `strings -a /System/Library/PrivateFrameworks/AMPDevices.framework/Versions/A/Support/AMPDevicesAgent`
(macOS 25.4.0 / Darwin, 37909 lines). Note: AMPDevicesAgent is the **macOS**-side
daemon; symbol names there describe the wire dictionaries it builds/consumes.
The wire vocabulary is symmetric so iOS-side `atc` accepts the same keys.

## Operation names (complete list)

```
insert_track   update_track   delete_track   upload_track
insert_album   update_album   delete_album
insert_artist  update_artist  delete_artist
insert_playlist update_playlist delete_playlist
update_db_info
delete_after_upload
```

`upload_track` is new to us — likely the bare artwork-upload op (no
insert_track payload). Worth probing.

## insert_album dict — REAL wire keys

From the literal SQL the daemon executes (line 23125):
```sql
INSERT INTO album (pid, kind, artwork_status, artwork_item_pid,
                   all_compilations, user_rating, name_order, season_number)
VALUES (...)
```

Plus the key cluster immediately after the `InsertAlbum` marker (line 24038):
- `artwork_item_pid` ← canonical "which item provides album artwork"
- `all_compilations`
- `store_link_url`

**Findings:**
1. **`representative_item_pid` does NOT exist as a wire key.** It's a DB
   column (`album.representative_item_pid`) and a CamelCase host-internal
   API name (`AlbumRepresentativePersistentID`), but the wire key that fills
   that column is `artwork_item_pid`. Our current code sends both —
   `representative_item_pid` is silently dropped, `artwork_item_pid` is the
   one that actually binds (we observed this in T2/T3).
2. **`artwork_cache_id` is NOT a valid wire key on `insert_album`.** It's
   only a track-level key (item table column). The Codex/CigGenerator
   string-table extract listed it adjacent to album keys but did not assert
   it was an album key. Album-level artwork MUST flow through
   `artwork_item_pid` → an item that owns the JPEG.
3. **`artwork_status`** — new candidate album-level key. The SQL insert
   includes it; values unknown. Worth probing.
4. **No "direct artwork blob" path on insert_album.** Apple's pipeline has
   no `album_artwork_path`, `artwork_blob`, `artwork_relative_path`, etc.
   Album artwork ALWAYS routes through an item via `artwork_item_pid`. This
   matches the libgpod legacy model.

## insert_artist dict — REAL wire keys

SQL insert (line 23127):
```sql
INSERT INTO artist (pid, kind, artwork_status, artwork_album_pid, name_order)
VALUES (...)
```

We're already wiring `artwork_album_pid` — confirmed correct.

## insert_track dict — REAL wire keys (item table)

Literal SQL (line 23132) gives ALL wire-controlled item columns:
```sql
INSERT INTO item (pid, media_kind, is_song, is_audio_book, is_music_video,
                  is_movie, is_tv_show, is_home_video, is_ringtone,
                  is_voice_memo, is_podcast, is_itunes_u, is_rental,
                  is_digital_booklet, is_book, date_modified, year,
                  content_rating, is_compilation, is_user_disabled,
                  remember_bookmark, exclude_from_shuffle,
                  part_of_gapless_album, chosen_by_auto_fill,
                  artwork_status, artwork_cache_id, start_time_ms,
                  stop_time_ms, total_time_ms, track_number, track_count,
                  disc_number, disc_count, bpm, relative_volume, genius_id)
VALUES (...)
```

**Hiding-candidates surfaced:**
- `is_user_disabled` — wire-controllable column.
- `exclude_from_shuffle` — wire-controllable.
- `chosen_by_auto_fill` — wire-controllable.

**`is_hidden` is NOT a valid wire key for `insert_track`.** It appears
exclusively in the playlist op cluster (line 24024, after the
`InsertPlaylist` marker) and in `INSERT INTO container` SQL (line 23177).
Trying `is_hidden=true` on a track would be silently dropped.

## TV.app episode-list filter — `ItemSeries` partial index

From the on-device DB:
```sql
CREATE INDEX ItemSeries ON item
  (series_name_order, album_order, episode_sort_id, title_order,
   media_type, in_my_library ASC)
WHERE in_my_library
```

**`in_my_library` is the only filter.** Setting `in_my_library = 0` on the
phantom hides it from the episode list.

## How `item.in_my_library` is set — trigger from item_store

```sql
CREATE TRIGGER on_insert_item_setInMyLibraryColumn AFTER INSERT ON item_store
BEGIN
  UPDATE item SET in_my_library = (CASE
    WHEN new.home_sharing_id
      OR (new.store_saga_id AND new.cloud_in_my_library)
      OR new.purchase_history_id
      OR (new.sync_id AND new.sync_in_my_library)
      OR new.is_ota_purchased
    THEN 1 ELSE 0 END)
  WHERE item_pid = new.item_pid;
END
```

For our use case, `sync_id` is always set (medialibraryd writes the wire pid
into `item_store.sync_id`). So:
- `in_my_library = 1` iff `sync_in_my_library = 1`.
- To hide phantom: need `sync_in_my_library = 0`.

**Open question:** what wire key maps to `item_store.sync_in_my_library`?
No string surfaced for it in AMPDevicesAgent. Two hypotheses:
1. medialibraryd sets `sync_in_my_library = 1` by default on every
   insert_track — no wire override possible.
2. There's an undocumented wire key (perhaps in another framework's strings —
   MobileDeviceUpdater, MobileDevice itself).

**Mitigation paths if we can't flip sync_in_my_library:**
- T7a: `is_user_disabled = true` on phantom. Maybe TV.app's episode-list
  query also filters `AND NOT is_user_disabled` (the partial index only
  covers `in_my_library`, but TV.app's WHERE clause could be tighter).
- T7b: phantom with non-TV media_kind (e.g. `is_song=true` or
  `is_home_video=true`). Phantom still attached to album via `album_pid`,
  artwork_item_pid still resolves, but episode list filter on
  `media_type=2048` excludes the row. Risk: medialibraryd's album
  re-derivation logic may skip non-TV items as artwork donors.

## Disconfirmations

- **`libts` is NOT an Apple iOS service** — zero strings match in
  AMPDevicesAgent or MobileDevice. Confirms Codex's finding that
  TSAppManagerImpl/TSCSqlite3 are Tenorshare/iCareFone vendor symbols,
  irrelevant to our reverse engineering.
- **No `representative_item_persistent_id` wire key** (research doc #1
  hypothesis). The actual wire key is `artwork_item_pid` (Int64 wire pid
  resolved at sync time, NOT a kebab-case persistent ID hex string).

## What CamelCase keys mean

`AlbumRepresentativePersistentID`, `ArtistRepresentativePersistentID`,
`RepresentativePersistentID` are the host-side framework's CFDictionary
keys used INTERNALLY between AMPDevicesAgent and its callers (Music.app,
TV.app, Finder sidebar). They are NOT the wire keys sent over ATC. They
map onto the snake_case wire keys at the dictionary-builder layer.

## Files

- Full strings dumps: `/tmp/atc-strings/AirTrafficHost.strings`,
  `AMPDevicesAgent.strings`, `MobileDevice.strings`.
- AirTrafficHost.framework strings have NO business-logic — just the C API
  surface (ATHostConnectionSend*, message names like SyncAllowed /
  AssetManifest / SyncFinished). Wire vocabulary lives entirely in
  AMPDevicesAgent.

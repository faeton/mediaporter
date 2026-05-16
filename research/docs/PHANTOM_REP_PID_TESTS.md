# Phantom show-poster rep_pid binding — test matrix

Branch: `phantom-portrait-two-phase-delete`

Goal: discover how `album.representative_item_pid` is actually controlled so the
TV.app show-detail header shows a portrait JPEG (not a squashed landscape still).

## Observed state after commit 4494462 (two-phase delete in same plist)

- Album row created with `representative_item_pid = 0` (wire field discarded).
- `album.sync_id` = our wire-pid (so wire-pid maps to sync_id, not album_pid).
- `album_pid` is renumbered by medialibraryd.
- `artwork_token` row exists for the album with our random `artwork_cache_id`
  but `fetchable_artwork_source_type = 0`.
- Real episode lands correctly. (Earlier "MISSING" reading was a manual
  delete-from-TV-app by the user, not a GC sweep.)
- TV.app: landscape still in both the episode tile and the show-detail header.

## Test matrix

Each test uses one fresh show (not currently on device) and one episode.
After each sync: pull `MediaLibrary.sqlitedb*` via AFC, run queries below, fix
findings. Delete the show from TV.app between tests so albums don't fuse.

| #   | Phantom synthesized | insert_artist+insert_album | delete_track | Hypothesis tested |
|-----|---------------------|----------------------------|--------------|-------------------|
| T1  | no                  | no                          | no           | What does medialibraryd auto-derive on its own? Baseline. |
| T2  | no                  | yes (rep_pid = real episode wire pid) | no | Is `insert_album.representative_item_pid` ever honored at all? |
| T3  | yes                 | yes (rep_pid = phantom wire pid) | no       | Does phantom-as-rep work without two-phase delete? (Cosmetic: phantom visible in episode list.) |
| T4  | yes                 | yes (rep_pid = phantom wire pid) | yes (in same plist) | Two-phase delete (commit 4494462) — current code. |
| T5  | yes (sess 1)        | yes (sess 1)                | yes, in sess 2 | Two-session approach: insert in sess 1, hide via separate sync. |

## DB queries (run after each test)

```sql
-- Album row + key fields
SELECT album_pid, album, representative_item_pid, season_number, sync_id,
       album_artist_pid, cloud_status
FROM album WHERE album LIKE '%<SHOW>%';

-- Items in that album
SELECT i.item_pid, i.media_type, i.album_pid, i.in_my_library, i.episode_sort_id,
       ie.title, ie.location, ie.media_kind
FROM item i LEFT JOIN item_extra ie ON ie.item_pid = i.item_pid
WHERE i.album_pid = <album_pid_from_above>;

-- artwork_token rows for the album + items
SELECT entity_pid, entity_type, artwork_source_type, artwork_type, artwork_token
FROM artwork_token WHERE entity_pid IN (<album_pid>, <each item_pid>);

-- best_artwork_token rows
SELECT * FROM best_artwork_token WHERE entity_pid IN (<album_pid>, <each item_pid>);

-- item_artist for the show
SELECT * FROM item_artist WHERE series_name LIKE '%<SHOW>%';
```

## Visual verification

For each test, on device after sync:
- TV.app → Library → show tile: portrait or landscape?
- TV.app → show-detail header (big image at top): portrait or landscape?
- Episode list: how many rows? Any blank/phantom rows visible?

---

## Test results

(filled in as we go)

### T1 — Baseline (no phantom, no explicit album ops)

- **Show used:** The Mandalorian S01E01 Chapter 1 (1080p)
- **Code:** commit 291a107, `ATCSession.phantomTestMode = .baseline`
- **Wire log highlights:**
  - `pipeline.phantomTestMode: runPipelined start with mode=baseline`
  - `atc.phantomTestMode: baseline`
  - Only one item in plist: `asset=229204802901709888 path=/iTunes_Control/Music/F05/BXKT.mp4 title=Chapter 1: The Mandalorian show=The Mandalorian s=1 e=1 ep_sort=1`
  - No phantom synthesized, no insert_artist/insert_album, no delete_track ✓
- **DB state:**
  ```
  album: album_pid=82301815  album="The Mandalorian"  representative_item_pid=15315606
         season_number=1  sync_id=235831802339963836  album_artist_pid=122618968
  item:  item_pid=15315606  album_pid=82301815  in_my_library=1
         episode_sort_id=1  title="Chapter 1: The Mandalorian"  location=...BXKT.mp4
  item_artist: pid=39967888  series_name="The Mandalorian"  representative_item_pid=15315606
  artwork_token (item):  entity_pid=15315606  entity_type=0  artwork_type=1  source_type=300  token='5153'
  artwork_token (album): entity_pid=82301815  entity_type=4  artwork_type=6  source_type=300  token='5153'
  best_artwork_token:    entity_pid=82301815  entity_type=4  artwork_type=6  fetchable_source_type=0
  ```
- **TV.app visual:** Landscape still in show tile AND show-detail header AND episode row. No portrait shown anywhere.
- **Verdict:** **CRITICAL findings.**
  1. medialibraryd auto-derives `album.representative_item_pid` to the only inserted item's DB item_pid (15315606), even without our explicit insert_album op.
  2. `album.sync_id` reused from prior T4 sync (235831802339963836) → album row matched by sync_id even after TV.app delete. **album rows persist with 0 items but rebind on re-sync.**
  3. **Our wire pid (229204802901709888) was renumbered to item_pid=15315606**. So wire pid → DB item_pid mapping happens internally.
  4. **`item` table has NO `sync_id` column** (only `album`, `item_artist` do). So `representative_item_pid` value MUST be a DB item_pid — wire pids cannot be resolved for items. This explains T4's rep_pid=0: we sent the phantom's wire pid as rep_pid, medialibraryd had no item.sync_id to look up, defaulted to 0.
  5. Artwork token "5153" bound at BOTH item level (entity_type=0, artwork_type=1) and album level (entity_type=4, artwork_type=6) using the SAME random `artwork_cache_id` we sent. So artwork DOES bind, but to landscape (the JPEG was the ep still).
  6. `fetchable_artwork_source_type=0` is normal — it means "not cloud-fetchable, local AFC artwork".
  7. **Portrait isn't shown because the ONLY uploaded JPEG was landscape** (episode still). medialibraryd doesn't have access to the portrait at all in this mode.

  **Implication for T2/T3/T4/T5:** rep_pid is never settable to a wire pid — it must resolve to a DB item_pid. Phantom strategy only works if phantom survives in `item` table (so rep_pid points at it AFTER medialibraryd renumbers). Two-phase delete is doomed because it removes the only DB-resolvable target.

### T2 — Explicit album, rep_pid = real episode wire pid

- **Show used:** The Mandalorian S01E01 (resync after T1, TV.app delete in between)
- **Code:** ATCSession.phantomTestMode = .explicitAlbumOnly
- **Wire log highlights:**
  - `pipeline.phantomTestMode: ... mode=explicitAlbumOnly`
  - `atc.phantomTestMode: explicitAlbumOnly`
  - `atc.insert_artist: pid=871110665214019246 show="The Mandalorian" artwork_album_pid=235831802339963836`
  - `atc.insert_album: pid=235831802339963836 show="The Mandalorian" season=1 rep_pid=331097629881534024` ← rep_pid = real episode's wire pid
  - `atc.plist.identity: asset=331097629881534024 ... show=The Mandalorian s=1 e=1 ep_sort=1`
  - No delete_track ✓
- **DB state:**
  ```
  album: album_pid=82301815 (SAME as T1 — reused via sync_id match)
         representative_item_pid=7581646  sync_id=235831802339963836
  item:  item_pid=7581646  album_pid=82301815  location=...GIYU.mp4
  artwork_token (item):  entity_pid=7581646  entity_type=0  artwork_type=1  source_type=300  token='492'
  artwork_token (album): entity_pid=82301815  entity_type=4  artwork_type=6  source_type=300  token='492'
  ```
- **TV.app visual:** Landscape still in show tile and show-detail header. Episode list **initially blank** when opening show; appeared after TV.app restart (1 episode visible). Likely TV.app cache staleness from the reused album_pid (album existed pre-sync with 0 items → cached as empty → new item not in cache until restart).
- **Verdict:** **MASSIVE insight — medialibraryd resolves wire pids to DB item_pids for items inserted in the SAME sync batch.**
  - We sent `rep_pid = 331097629881534024` (wire pid).
  - DB stored `representative_item_pid = 7581646` (the actual DB item_pid that medialibraryd auto-assigned to this episode's item row).
  - So medialibraryd maintains a session-level wire_pid → DB_item_pid map during sync; explicit `insert_album.representative_item_pid` IS honored, just translated through that map.
  - Once sync ends, the map is discarded (no `item.sync_id` column).

  **Reinterpretation of T4 (commit 4494462) failure:** medialibraryd DID resolve our `rep_pid = phantom_wire_pid` to phantom's DB item_pid initially. Then the `delete_track phantom` op in the same plist deleted that item row. Either:
  - (a) medialibraryd processed the delete BEFORE finalizing the album rep_pid binding, leaving rep_pid=0; OR
  - (b) the delete fired AFTER rep_pid was set, but a trigger or post-delete sweep cleared the dangling FK to 0.

  **Strategic conclusion:** T3 will likely work if it 1) inserts phantom alongside real (phantom survives in item table), 2) sends explicit rep_pid = phantom_wire_pid, 3) skips delete_track. The cosmetic issue of phantom visible in episode list becomes the only remaining problem — solvable via `in_my_library=0` wire-key search (already in progress, see [[reference_itemseries_index]]) or by exploiting whatever flag flips a track out of the partial index.

### T3 — Phantom + explicit album, NO delete_track

- **Show used:** The Mandalorian S01E01 (resync after T2)
- **Code:** ATCSession.phantomTestMode = .phantomNoDelete
- **Wire log highlights:**
  - `pipeline.phantom: synthesized asset=331522825354602469 ... poster_bytes=129772` (correct Mandalorian portrait 500x750 JPEG, verified by AFC pull + Read)
  - `atc.insert_album: pid=235831802339963836 ... rep_pid=331522825354602469` (rep_pid = phantom wire pid)
  - No delete_track ✓
- **DB state:**
  ```
  album: album_pid=82301815  representative_item_pid=16294403  ← PHANTOM's DB item_pid ✓
  item (phantom): item_pid=16294403  album_pid=82301815  in_my_library=1  episode_sort_id=99999  file_size=1477
  item (real):    item_pid=16294404  album_pid=82301815  in_my_library=1  episode_sort_id=1     file_size=6638308
  item_artist:    pid=39967888  series_name="The Mandalorian"  representative_item_pid=16294403  ← PHANTOM ✓
  artwork_token:
    entity_pid=16294403 (phantom) entity_type=0 artwork_type=1 token='1338'  ← portrait JPEG
    entity_pid=16294404 (real)    entity_type=0 artwork_type=1 token='7200'  ← landscape ep still
    entity_pid=82301815 (album)   entity_type=4 artwork_type=6 token='7200'  ← REAL EP's token, NOT phantom's
  artwork (token → path):
    '1338' → f8/81b44b0c8b0ace5bc97cf6066fda86c2af6e18  (Mandalorian portrait, verified on disk)
    '7200' → 85/146e3d99ceaf1282f5eeb5999356aef12f7e37
  ```
- **TV.app visual:** show-detail header shows the REAL EPISODE's landscape still letterboxed inside a portrait-shaped slot. Episode list shows 2 rows (real ep + "99,999." phantom row, both with landscape thumbs).
- **Verdict:** **Major progress + new puzzle.**
  - rep_pid binding WORKS — `album.representative_item_pid` and `item_artist.representative_item_pid` both correctly point at phantom's DB item_pid (16294403). Confirms T2's wire→DB pid resolution finding.
  - BUT TV.app show-detail header does NOT read from rep_item's artwork. It reads from `album`-level `artwork_token` (entity_pid=album_pid, entity_type=4, artwork_type=6), which medialibraryd populated with the REAL EPISODE's token ('7200'), NOT the phantom's ('1338').
  - Album-level artwork binding rule appears to be **lowest-episode_sort_id wins**: real ep at sort_id=1 beat phantom at sort_id=99999. (Other candidate rules: last-inserted wins, but real was inserted second; first-FileComplete'd wins, but phantom was first. The lowest-sort_id theory fits.)
  - Phantom's `artwork_cache_id` did create an artwork_token at item-level (good for phantom-row thumbnail in episode list, though landscape-letterboxed by TV.app's expected aspect ratio for item artwork_type=1). But it did NOT propagate to the album row's artwork.

  **Next sub-tests on this branch:**
  - **T3b**: set phantom's `episode_sort_id = 0` or `-1` (lower than real) — does album artwork now bind to phantom?
  - **T3c**: don't set `artwork_cache_id` on real episodes (only on phantom) — does album fall back to phantom's artwork?
  - **T3d**: reverse insert order (real first in plist, phantom last) — does last-wins?
  - **T3e**: insert phantom track but with `media_type != 2048` or `is_tv_show=false` — does excluding it from "episodes" still let it act as artwork donor?
  - **T3f** *(from external research)*: set `artwork_cache_id` **directly on the `albumOp` dict** in insert_album (not just on tracks). Research suggests album-level artwork_cache_id may propagate independently of track tokens.
  - **T3g** *(from external research)*: upload portrait JPEG to `/Airlock/Media/Artwork/<wire_album_pid>` (i.e. the wire pid that maps to album.sync_id) in addition to phantom path. Tests whether medialibraryd ingests album-keyed artwork from a separate AFC path.
  - **T3h**: insert_track for phantom WITHOUT `album_pid` set — orphan phantom from album, see if album-level artwork falls through to phantom's artwork as the only candidate.

  **Re-interpretation of T4 failure (incorporating external research):** the same-plist `insert_track` + `delete_track` for phantom likely zeroed `representative_item_pid` because medialibraryd queues ops, sees the delete in the queue, and skips the wire→DB pid resolution for phantom (since it will be deleted anyway). T2's resolution mechanism requires the item to SURVIVE the sync. This is consistent with "two-phase delete in same plist" being fundamentally broken.

### T3b — Phantom + explicit album, NO delete, phantom episode_sort_id=0

- **Show used:** The Mandalorian S01E01 (resync after T3)
- **Code:** commit bad092a, `ATCSession.phantomTestMode = .phantomNoDelete`
  with phantom's `episode_sort_id = 0` (down from 99999 in T3).
- **TV.app visual:** **Show-detail header now shows the Mandalorian PORTRAIT.**
  Episode list has 2 rows: phantom "0." with portrait thumbnail (1-second clip)
  + real "1." with landscape episode still. Portrait poster also appears on the
  episode-row thumbnail of the phantom row.
- **Verdict:** **Hypothesis confirmed — lowest `episode_sort_id` wins album-level
  artwork.** Moving phantom to sort_id=0 made medialibraryd bind the album's
  `artwork_token` (entity_type=4, artwork_type=6) to the phantom's token instead
  of the real episode's. Show-detail portrait now resolves correctly.
  - Caveat: phantom is still visible as a ghost "0." episode in the list. Not
    shippable as-is. Needs hiding via either (a) deleting phantom item row in a
    separate session after artwork commits (T5), (b) flipping `in_my_library=0`
    via some wire key, or (c) the route the user is most interested in: not
    using a phantom at all, binding artwork directly on the album row (TBD).

### T4 — Current code (two-phase delete in same plist)

- **Show used:** The Mandalorian S01E01
- **Code:** commit 4494462 as-is
- **Wire log highlights:**
  - `pipeline.phantom synthesized asset=331522825354602469 ... poster_bytes=75286`
  - `atc.insert_album pid=235831802339963836 ... rep_pid=331522825354602469`
  - `atc.delete_track phantom asset=331522825354602469 (two-phase hide)`
  - Both phantom + real uploaded, SyncFinished in 0s
- **DB state:**
  - `album: album_pid=82301815, representative_item_pid=0, sync_id=235831802339963836`
  - `artwork_token: entity_pid=82301815, entity_type=4, artwork_token='9180'`
  - `best_artwork_token: fetchable_artwork_source_type=0`
  - `item: 0 rows for the phantom wire pid; real episode row present`.
    (Earlier "real episode swept by GC" reading was misdiagnosed — the missing
    `/iTunes_Control/Music/F27/UCUC.mp4` file came from the user deleting the
    show from TV.app between sync and DB pull, not from medialibraryd GC.)
- **TV.app visual:** Landscape still in show tile and show-detail header.
  Portrait not shown. Real episode visible normally (no nuked item).
- **Verdict:** Two-phase delete in the same plist zeroes `representative_item_pid`
  but does NOT corrupt the real episode. The portrait fails because the same-plist
  delete prevents `representative_item_pid = phantom_wire_pid` from resolving to a
  DB pid (T2's wire→DB resolution map needs the item to survive the batch).

### T5 — Two-session approach: phantom in session 1, delete in session 2

- **Show used:** The Mandalorian S01E01 + Breaking Bad S01E01 (two shows in
  same pipeline run for redundancy)
- **Code:** commit 22beb33, `ATCSession.phantomTestMode = .phantomSeparateDelete`.
  Main session identical to T3b (phantom inserted with `episode_sort_id=0`,
  real episode inserted, no delete_track in main plist). After the main
  `RegisterSession.finish()`, a fresh ATC session opens (`openDeleteOnly`)
  and emits a delete-only plist with `delete_track` for each phantom asset_id.
- **Wire log highlights:**
  ```
  23:41:16 atc.MetadataSyncFinished anchor=76     ← main session
  23:41:24 pipeline.phantomSeparateDelete: starting cleanup session for 2 phantom(s)
  23:41:26 atc.delete_track: phantom asset=660299919217739395 (separate-session cleanup)
  23:41:26 atc.delete_track: phantom asset=331522825354602469 (separate-session cleanup)
  23:41:26 atc.MetadataSyncFinished anchor=77     ← cleanup session
  23:41:27 ERROR pipeline.phantomSeparateDelete: cleanup session failed:
           No AssetManifest received from device
  ```
  Host gave up after 0.8 s waiting for AssetManifest. **But the device
  still applied the delete** — see DB state.
- **DB state:** (after pulling MediaLibrary.sqlitedb via AFC)
  ```
  album.Mandalorian:   album_pid=82301815, rep_pid=15289281, sync_id=235831802339963836
  album.BreakingBad:   album_pid=83358639, rep_pid=15289280, sync_id=264873087669939139
  artwork_token (Mandalorian album): entity=82301815, type=4, token='3344'
                                     '3344' → cf/b6ae10b1173fb416789fbcc1b3d5ada01222b8
                                     = real ep token (landscape)
  artwork_token (BreakingBad album): entity=83358639, type=4, token='6142'
                                     '6142' → 90/f632e60316064300f67d38b337c4ae5b46adb1
                                     = real ep token (landscape)
  item rows with phantom sync_ids 331522825354602469 / 660299919217739395:  0 rows
  ```
  Bonus orphan: `Breaking Bad, Season 1` (album_pid=82795155, season=0,
  sync_id=0, rep_pid=0, artwork_token='639') — stale shell from prior runs,
  unrelated to T5.
- **TV.app visual:** No portrait header (landscape thumb), phantom episode
  GONE from list. Cleanup happened — but the artwork token followed.
- **Verdict:** **T5 fails. `PRAGMA foreign_keys=0` was the wrong model.**
  medialibraryd has its own rebind logic at the daemon layer: when an item
  referenced by `album.representative_item_pid` is deleted, it re-derives
  rep_pid to the next-best surviving item AND rewrites the album's
  `artwork_token` row to that item's token. The phantom's portrait token
  becomes unreferenced and gets swept.

  **Implication for the whole phantom approach:** any strategy that involves
  the phantom item disappearing after its artwork has bound CANNOT keep that
  artwork on the album row. The phantom would have to live indefinitely.
  Combined with T3b (phantom visible as "0." row in episode list), this
  rules out phantom-then-hide entirely. Need a path that doesn't rely on an
  item row at all.

  **Newly relevant evidence (Codex 2026-05-16):** the `CigGenerator.exe`
  binary in iFunBox / iTools (extracted by Hybrid Analysis) contains exact
  literal strings: `insert_album`, `insert_track`, `delete_track`,
  `artwork_cache_id`, `artwork_item_pid`, `album_pid`,
  `/iTunes_Control/Sync/Media/Sync_%.8d.plist[.cig]`. So `artwork_item_pid`
  and `artwork_cache_id` on `insert_album` are REAL wire keys, not guesses.
  T6 (album-direct artwork via these keys, no phantom item) becomes the
  primary path forward.

### T6 — Album-direct artwork, no phantom (NEXT)

- **Plan:** drop the phantom synthesis entirely. On `insert_album`, attach
  portrait artwork via the wire keys discovered in CigGenerator.exe:
  - `insert_album.artwork_cache_id` → integer token referenced by an
    AFC-uploaded JPEG at `/Airlock/Media/Artwork/<asset_id>`.
  - Either re-use a wire pid we already track (e.g. derive an `album_artwork`
    asset_id deterministically per `(show, season)`) and upload the portrait
    there, then point `artwork_cache_id` at it; or
  - Use `artwork_item_pid` to point album at an existing item's artwork
    token — but that's just the phantom approach with a different name.
- **First variant to test:** upload portrait JPEG to
  `/Airlock/Media/Artwork/<wire_album_pid>` (where `wire_album_pid` is what
  we send as `insert_album.pid` and medialibraryd maps to `album.sync_id`).
  This relies on medialibraryd's wire→DB resolution map handling album-keyed
  Airlock paths the same way it handles item-keyed ones.
- **Risk:** unknown whether medialibraryd ingests artwork from a path keyed
  by an album sync_id at all — Airlock convention so far has been per-item.
  If this fails, fall back to a dedicated "artwork asset" wire pid that we
  declare via the manifest but never reference from a track.

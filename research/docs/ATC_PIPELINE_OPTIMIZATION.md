# ATC Pipeline Optimization Punch-List

This note compares MediaPorter's current ATC/AFC upload pipeline against external open-source implementations where source code or repository documentation could be inspected. The strongest external evidence is AFC transport behavior from pymobiledevice3 and libimobiledevice; ATC media-sync evidence remains thinner because most public projects either cover generic AFC/app install or Grappa authorization rather than TV.app media sync.

## Handshake

1. **Avoid unconditional pre-handshake sleeps where possible.**
   - External impl + reference: IpaInstall, `client/aid2` ATC authorization flow as summarized in `research/docs/IPAINSTALL_ANALYSIS.md` Phase 3, reads `SyncAllowed`, sends `RequestingSync`, then reads until `ReadyForSync`; no fixed pre-handshake settle is described. AltStore/AltServer release notes mention fixing wired stalls, but not an ATC-ready signal.
   - MediaPorter now: `SyncEngine.swift::registerUploadedFiles` sleeps 3 s then 8 s on retry; `RegisterSession.open` sleeps 2 s then 6 s before creating a fresh `ATCSession` (`SyncEngine.swift` lines ~80-85, ~156-168).
   - Why their approach may be better: fixed sleeps add dead time to every batch even when the device is already ready. A first attempt with no or shorter settle, followed by the existing longer retry only on `ReadyForSync` failure, should improve small-batch latency without changing the protocol.
   - Action: **EVALUATE**. Benchmark `0/6`, `1/6`, and current `2/6` in `RegisterSession.open`; keep retry behavior tied to actual handshake failure.

2. **Keep using `SyncAllowed`/`ReadyForSync`, not a guessed "ready" message.**
   - External impl + reference: IpaInstall, `client/aid2` ATC sync loop in `IPAINSTALL_ANALYSIS.md` Phase 3; uses the same `SyncAllowed -> RequestingSync -> ReadyForSync` shape. No inspected external source showed a separate `ReadyForSync`-prelude or `ReadyForSync` substitute.
   - MediaPorter now: `ATCSession.handshake` sends HostInfo, waits for `SyncAllowed`, sends `RequestingSync` with Grappa, and waits for `ReadyForSync` (`ATCSession.swift` lines ~107-141).
   - Why their approach is better: this is the protocol-level gate the device actually exposes; waiting for another signal would likely become a silent timeout.
   - Action: **CONFIRMED**. Do not add another handshake gate unless a trace proves it exists.

## AFC Upload

1. **Do not assume 4-8 MB chunks are externally proven faster.**
   - External impl + reference: libimobiledevice `src/afc.c::afc_file_write` in the cgit 1.0.3 snapshot uses `MAXIMUM_WRITE_SIZE = 1 << 15` and writes/acks each segment; current cgit `src/afc.c` still shows segmented `afc_dispatch_packet` calls around `afc_file_write`. pymobiledevice3 mirror `pymobiledevice3/services/afc.py::AfcService.fwrite` defines `MAXIMUM_WRITE_SIZE = 1 << 30` but still dispatches one AFC `WRITE` and waits for `_receive_data()` per chunk.
   - MediaPorter now: `AFCClient.writeFileStreaming` uses a 1 MB buffer and one `AFCFileRefWrite` per read (`AFC.swift` lines ~23-25, ~99-114).
   - Why their approach is better: the inspected libraries optimize for correctness and request/response framing, not necessarily giant writes. Larger chunks may reduce host-side call count, but they may also increase memory pressure or hit private MobileDevice/framework limits.
   - Action: **EVALUATE**. Add a local throughput benchmark behind a debug flag for 256 KB, 1 MB, 4 MB, and 8 MB. Do not change the default until measured across Lightning, USB-C, and Wi-Fi-paired devices.

2. **AFC operation batching is not supported by the inspected implementations.**
   - External impl + reference: libimobiledevice DeepWiki `src/afc.c::afc_dispatch_packet` describes one AFC request followed by one response; for file write, packet data is the handle and payload is the file bytes. The cgit 1.0.3 source comments explain two segments inside one AFC packet for write payload, not multiple AFC operations in one usbmuxd packet.
   - MediaPorter now: one `AFCFileRefWrite` call per media chunk, plus separate AFC calls for mkdir, plist, CIG, artwork, and close (`AFC.swift` lines ~44-69, ~75-118).
   - Why their approach is better: explicit request/response framing avoids packet-number and ACK ambiguity. Trying to bundle multiple AFC operations would be protocol risk with little supporting evidence.
   - Action: **CONFIRMED**. Do not attempt multi-op AFC batching; focus on chunk-size benchmarking and reducing unnecessary operations.

3. **Verify post-upload size before `FileComplete`.**
   - External impl + reference: libimobiledevice exposes `afc_get_file_info` / `afc_get_file_info_plist` for `st_size` (`src/afc.c::afc_get_file_info`, DeepWiki File Information section); pymobiledevice3 `AfcService.stat` parses `st_size`; libimobiledevice `tools/afcclient.c::put_single_file` checks `bytes_written` from each `afc_file_write` call.
   - MediaPorter now: upload logs `sent == expected`, and `AFCClient.fileSize` exists, but `AFCUploader.upload` does not stat the remote path after close (`AFC.swift` lines ~116-117, ~174-197; `SyncEngine.swift` lines ~47-60).
   - Why their approach is better: a remote `st_size` check catches truncation, late AFC write failures, or disk-full edge cases before ATC `FileComplete` makes medialibraryd try to bind a broken asset.
   - Action: **CONFIRMED**. After `writeFileStreaming` returns and the file handle is closed, call `fileSize(remotePath)` and compare to local file size before `completeFile`.

4. **ATC `FileProgress` is already throttled enough.**
   - External impl + reference: IpaInstall authorization flow has no video upload progress phase; libimobiledevice/pymobiledevice3 AFC layers report file-transfer progress at the AFC layer, not ATC. No inspected external implementation sent ATC `FileProgress` per AFC chunk for media.
   - MediaPorter now: although `AFCClient.writeFileStreaming` calls UI progress per 1 MB chunk, `PipelineController.runPipelined` only sends ATC `FileProgress` every 5 seconds or 10 percentage points, plus final 100% in `completeFile` (`PipelineController.swift` lines ~2012-2031; `ATCSession.swift` lines ~642-647, ~668-683).
   - Why their approach is better: throttling keeps medialibraryd's asset slot alive without flooding ATC during large uploads.
   - Action: **CONFIRMED**. Keep the current 5 s / 10% ATC throttle; the "per 1 MB FileProgress" concern is stale relative to current Swift.

## ATC Plist

1. **Keep plist+CIG before `MetadataSyncFinished`.**
   - External impl + reference: go-tunes, `proto.go::deviceGrapa` and `cig.cpp::cigCalc` are the source named in existing MediaPorter research for the Grappa/CIG flow; IpaInstall Phase 5 writes its authorization response files before `ATHostConnectionSendMetadataSyncFinished`. Current GitHub source for `Mbsync/go-tunes` could not be re-fetched through the local proxy, so this is cross-referenced through `ATC_SYNC_FLOW.md` and `IPAINSTALL_ANALYSIS.md`.
   - MediaPorter now: `ATCSession.prepareSync` writes `/iTunes_Control/Sync/Media/Sync_%08d.plist` and `.cig`, then sends `SendPowerAssertion` and `MetadataSyncFinished` (`ATCSession.swift` lines ~527-544).
   - Why their approach is better: the device scans the binary plist only after metadata completion; sending completion first risks `AssetManifest` failure.
   - Action: **CONFIRMED**. Preserve this ordering.

2. **The full batch must remain known before `MetadataSyncFinished`.**
   - External impl + reference: go-tunes CIG/sync-plist model writes a complete signed plist before the ATC file phase, as recorded in `ATC_SYNC_FLOW.md`; libimobiledevice/pymobiledevice3 do not provide any dynamic ATC media insert path.
   - MediaPorter now: `PipelineController.runPipelined` pre-allocates asset IDs and device paths for every eligible file before opening `RegisterSession`; `RegisterSession.open` builds a full plist up front (`PipelineController.swift` lines ~1793-1825; `SyncEngine.swift` lines ~127-134, ~156-181).
   - Why their approach is better: CIG signs the complete plist bytes. Dynamic insertion after `MetadataSyncFinished` would require a new signed plist and probably a new sync revision.
   - Action: **CONFIRMED**. Keep full-batch preallocation.

## Keepalive

1. **Ping/Pong should stay event-driven, not timer-driven.**
   - External impl + reference: IpaInstall's ATC flow waits on device messages through `ReadyForSync` / `SyncFinished`; no inspected external code showed host-initiated `SessionAlive`, `Heartbeat`, or timer pings for ATC. AltStore release notes mention wired connection stall fixes but do not identify an ATC heartbeat message.
   - MediaPorter now: `ATCSession.startDrainer` blocks in `ATH.readMessage`, immediately responds to every `Ping` with `Pong`, and stores other message names for `finishSync` (`ATCSession.swift` lines ~772-807).
   - Why their approach is better: responding to device-driven pings avoids inventing unsupported wire messages and keeps the single ATC reader from racing.
   - Action: **CONFIRMED**. Keep event-driven Pong responses; do not add `SessionAlive` unless a trace or binary string reference proves it.

2. **The drainer architecture is correct for long uploads.**
   - External impl + reference: libimobiledevice AFC and pymobiledevice3 AFC operations are synchronous request/response; they do not address the separate ATC control channel. MediaPorter's ATC drainer fills that gap.
   - MediaPorter now: upload runs over one AFC connection while ATC has a background reader for Ping and terminal messages (`SyncEngine.swift` lines ~127-134; `ATCSession.swift` lines ~509-513, ~774-807).
   - Why their approach is better: without a live ATC reader, a multi-GB AFC upload can starve Ping/Pong and drop the ATC session even if AFC succeeds.
   - Action: **CONFIRMED**. Keep the drainer and avoid foreground `readMsg` races while it is active.

## Batching

1. **Parallel AFC media uploads are unproven and may fight device-side serialization.**
   - External impl + reference: libimobiledevice AFC clients guard operations with a per-client mutex and packet number (`src/afc.c`, DeepWiki Thread Safety and Packet Dispatch sections); usbmuxd multiplexes multiple connections, but the inspected AFC clients still treat each AFC connection as a synchronous stream.
   - MediaPorter now: one `AFCUploader` uploads media bytes serially, and `RegisterSession` owns a separate AFC connection for plist/artwork (`SyncEngine.swift` lines ~39-63, ~127-139; `PipelineController.swift` lines ~1964-1967).
   - Why their approach is better: serial media upload avoids cross-asset binding and disk-pressure races. Multiple AFC connections could help only if USB/usbmuxd and afcd allow true parallel writes to media storage.
   - Action: **CHECK**. Do not parallelize media uploads by default. If tested, limit to a debug experiment with two AFC media connections and verify row binding, throughput, and device free-space behavior.

2. **Current transcode lookahead is the safer batching win.**
   - External impl + reference: AltStore's public README describes installs/refreshes over Wi-Fi but does not show a comparable media batching model. AFC libraries focus on file I/O, not pipeline scheduling.
   - MediaPorter now: `PipelineController.runPipelined` starts transcodes ahead with a small concurrency cap while serializing upload/register (`PipelineController.swift` lines ~1868-1889, ~1964-1967).
   - Why their approach is better: it overlaps CPU/GPU work with I/O without increasing AFC/ATC protocol concurrency.
   - Action: **CONFIRMED**. Keep optimizing around lookahead and queue readiness before attempting parallel AFC.

## Artwork

1. **Keep artwork upload after `FileBegin` and before `FileComplete`.**
   - External impl + reference: pymobiledevice3 `AfcService.set_file_contents` and libimobiledevice `afc_file_write` show ordinary AFC writes are the right primitive for arbitrary device paths; no inspected external repo exposed a richer ATC artwork API for TV.app.
   - MediaPorter now: `ATCSession.completeFile` writes `/Airlock/Media/Artwork/<assetID>` and optional `<assetID>_show`, then sends final `FileProgress` and `FileComplete` (`ATCSession.swift` lines ~623-655).
   - Why their approach is better: uploading before `FileComplete` gives medialibraryd a chance to find artwork while binding the asset. Moving artwork after `FileComplete` risks a row without artwork until a later rescan.
   - Action: **CONFIRMED**. Keep ordering; only optimize by skipping duplicate `makedirs` calls when already created.

2. **No external evidence supports a separate album/show artwork sync path.**
   - External impl + reference: pymobiledevice3/libimobiledevice expose AFC primitives only; inspected AltStore/IpaInstall materials do not cover TV.app artwork. AMPDevicesAgent local strings in `AMPDEVICES_AGENT_STRINGS.md` identify valid item/album keys, but that is not an external open-source implementation.
   - MediaPorter now: track item uses `artwork_cache_id`; optional secondary artwork is uploaded through the same Airlock artwork mechanism and mapped via item fields (`ATCSession.swift` lines ~194-200, ~631-639).
   - Why their approach is better: sticking to item-coupled artwork avoids unsupported album-level side channels.
   - Action: **CHECK**. Do not pursue alternate album-artwork paths here; only revisit if a new external media-sync implementation exposes a real album artwork operation.

## Shutdown

1. **Hard cancel should try a short graceful finish after abandoning assets.**
   - External impl + reference: IpaInstall Phase 5 sends `MetadataSyncFinished` and waits for `SyncFinished` in its authorization flow; libimobiledevice AFC closes file handles and waits for AFC status on close (`src/afc.c::afc_file_close`, DeepWiki File Operations).
   - MediaPorter now: on upload failure or cancel, `PipelineController.runPipelined` calls `abandonAsset` for remaining assets, then `registerSession.close()` invalidates/releases ATC without waiting for `SyncFinished` (`PipelineController.swift` lines ~2070-2106; `SyncEngine.swift` lines ~230-236; `ATCSession.swift` lines ~838-846).
   - Why their approach is better: after all missing assets are cleared with `FileError(0)`, a short wait for `SyncFinished` may let the device close the revision cleanly and reduce next-session settle delays.
   - Action: **EVALUATE**. On user cancel, after abandoning remaining assets, call a bounded `finishSync(timeout: 10-15s)` variant before invalidate. On transport errors, keep immediate close.

2. **Normal successful shutdown is already correct.**
   - External impl + reference: libimobiledevice's AFC close path sends `AFC_OP_FILE_CLOSE` and receives status; IpaInstall waits for terminal sync completion in Phase 5.
   - MediaPorter now: `RegisterSession.finish` waits in `finishSync`, closes AFC, then invalidates/releases ATC (`SyncEngine.swift` lines ~224-228; `ATCSession.swift` lines ~720-760, ~838-846).
   - Why their approach is better: terminal ATC wait preserves the device's commit semantics and then releases handles.
   - Action: **CONFIRMED**. Keep successful shutdown as-is.

## Integrity

1. **Remote size verification is the highest-value integrity gap.**
   - External impl + reference: libimobiledevice `afc_get_file_info` returns metadata including `st_size`; pymobiledevice3 `AfcService.stat` parses `st_size`; libimobiledevice `afc_file_write` reports `bytes_written`.
   - MediaPorter now: local read count is logged as OK/TRUNCATED, but remote `st_size` is not checked in the upload path (`AFC.swift` lines ~116-117, ~174-197; `SyncEngine.swift` lines ~47-60).
   - Why their approach is better: it catches corruption before ATC commit and gives the user a deterministic retry path.
   - Action: **CONFIRMED**. Add remote stat validation after upload and before `completeFile`.

2. **Current Grappa/CIG strategy remains acceptable; no fresher public replacement found.**
   - External impl + reference: go-tunes `proto.go::deviceGrapa` / `cig.cpp::cigCalc` are the known public source of the replay blob and CIG engine in existing MediaPorter research; IpaInstall `Handle.cpp::AirFairSyncGrappaCreate` demonstrates dynamic Grappa generation through iTunes/AirTrafficHost internals for DRM authorization, not media upload.
   - MediaPorter now: `ATCSession.handshake` loads the replayed `SyncAuthSeed`, extracts device Grappa from `ReadyForSync`, and `computeCIG` signs the binary plist via bundled `libcig.dylib` (`ATCSession.swift` lines ~120-154, ~332-350; `CLAUDE.md` lines ~10, ~49-51).
   - Why their approach is better: replayed Grappa avoids private entitlement and iTunes-DLL offset fragility; dynamic Grappa adds complexity without a demonstrated media-sync benefit.
   - Action: **CHECK**. Track go-tunes/IpaInstall changes occasionally, but do not replace replayed Grappa unless static replay stops working on new iOS.

## Top-3 Priority List

1. **CONFIRMED: Add remote AFC `st_size` verification after every media upload.** Highest robustness gain: catches truncation before `FileComplete` and turns silent unplayable rows into explicit retryable upload errors.

2. **EVALUATE: Short graceful cancel finalization after `FileError(0)` for abandoned assets.** Likely reduces stale device state and may allow shortening future handshake settle sleeps.

3. **EVALUATE: Benchmark AFC chunk sizes under a debug flag.** The current 1 MB default is reasonable, but measured data is needed before trying 4-8 MB; external implementations do not prove larger chunks are safe or faster.

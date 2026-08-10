// ATC (AirTrafficHost) sync protocol implementation.
// Port of Python src/mediaporter/sync/atc.py

import Foundation

// MARK: - Data types

struct SyncItem {
    let fileURL: URL
    let title: String
    let sortName: String
    let durationMs: Int
    let fileSize: Int
    var isMovie: Bool = true
    var isTVShow: Bool = false
    var tvShowName: String?
    var sortTVShowName: String?
    var seasonNumber: Int?
    var episodeNumber: Int?
    var episodeSortID: Int?
    var artist: String?
    var sortArtist: String?
    var album: String?
    var sortAlbum: String?
    var albumArtist: String?
    var sortAlbumArtist: String?
    var isHD: Bool = false
    var channels: Int = 2
    /// True when the muxed output has more than one audio stream — needed
    /// so TV.app surfaces the audio track switcher. Without it, only the
    /// default track is exposed regardless of how many we shipped in the
    /// mp4. Drives `video_info.has_alternate_audio` in the insert_track
    /// plist.
    var hasAlternateAudio: Bool = false
    /// True when at least one subtitle stream is in the output. Drives
    /// `video_info.has_subtitles` so the sub picker appears.
    var hasSubtitles: Bool = false
    var posterData: Data?
    /// Show portrait JPEG for TV episodes. Uploaded as a second Airlock
    /// file at `/Airlock/Media/Artwork/<assetID>_show` and surfaced in
    /// the insert_track plist via `album_artwork_cache_id`. medialibraryd
    /// picks it up for the album row's poster slot — the Library list
    /// shows the portrait instead of the rep episode's still.
    /// (TV.app's show-detail hero is hardcoded 16:9 and still pulls an
    /// episode still; that slot is not driven by this field.)
    var showPosterData: Data?
}

struct SyncFileInfo {
    let item: SyncItem
    let assetID: Int
    let devicePath: String
    let slot: String
}

enum SyncError: LocalizedError {
    case handshakeFailed(String)
    /// The handshake missed on every retry — the cold-start signature. The
    /// device is reachable (AFC connected) but its ATC/medialibraryd service
    /// isn't answering the sync handshake yet, typically because it's still
    /// waking up or finishing its initial media scan right after being
    /// connected/unlocked. Distinct from `handshakeFailed` so the UI can
    /// explain the likely cause instead of dumping the raw protocol reason.
    case deviceNotReady(attempts: Int)
    case noManifest
    case cigFailed
    case rejected
    case connectionLost(String)
    case protocolError(String)

    var errorDescription: String? {
        switch self {
        case .handshakeFailed(let msg): return "ATC handshake failed: \(msg)"
        case .deviceNotReady(let attempts):
            return "The device didn't answer the sync handshake (tried \(attempts) times). "
                + "This usually means it's still waking up or indexing media right after "
                + "being connected or unlocked. Unlock the device, wait a few seconds, then Send again."
        case .noManifest: return "No AssetManifest received from device"
        case .cigFailed: return "CIG computation failed"
        case .rejected: return "Device rejected sync"
        case .connectionLost(let at): return "ATC connection lost during \(at)"
        case .protocolError(let msg): return "ATC protocol error: \(msg)"
        }
    }
}

// MARK: - ATC Session

class ATCSession {
    private var conn: UnsafeMutableRawPointer?
    private let device: DeviceInfo
    private let verbose: Bool
    private var deviceGrappa: Data?

    // Streaming-register state. nil outside a prepareSync/finishSync window.
    private var streamingAFC: AFCClient?
    private var drainerThread: Thread?
    private var drainerStop = false
    private let inboxLock = NSLock()
    /// Set by the drainer when its blocking read returns nil for an UNEXPECTED
    /// reason (transport error / peer death — not our own stopDrainer). This is
    /// the authoritative liveness signal: a send's return code is NOT (telemetry
    /// proved must-ack sends return wild nonzero rc on perfectly good syncs).
    /// Guarded by inboxLock. checkOrThrow consults it so a dead mid-sync
    /// connection aborts at the next must-ack send instead of the 120s deadline.
    private var connectionDead = false
    /// Names of non-Ping ATC messages the drainer has read but the foreground
    /// flow hasn't consumed yet. finishSync polls for SyncFinished here.
    private var inbox: [String] = []
    private var ourAssetIDs: Set<String> = []

    /// When the device's AssetManifest arrived — the moment the announced
    /// assets' delivery window starts ticking (CLAUDE.md #16). Every FileBegin
    /// logs its age against this so a regression that re-introduces a stall
    /// between the manifest and the first upload is visible in the log instead
    /// of only in a broken TV.app library days later.
    private(set) var manifestReceivedAt: Date?

    /// Seconds since the AssetManifest, or nil outside a prepared session.
    var secondsSinceManifest: TimeInterval? {
        manifestReceivedAt.map { Date().timeIntervalSince($0) }
    }

    /// Whether the Ping drainer is still running and the transport is intact.
    /// A dead drainer means no Pongs are going out, so the device will drop
    /// the session (CLAUDE.md #9) — worth knowing before a multi-GB upload.
    var isDrainerAlive: Bool {
        inboxLock.lock()
        defer { inboxLock.unlock() }
        guard let t = drainerThread else { return false }
        return t.isExecuting && !connectionDead
    }

    /// IDLE — not absolute age — after which the device stops sending
    /// `SyncFinished`. Measured 2026-08-05 (`idle-test`, one fixture, only the
    /// post-manifest idle varies): 25 s still acks, 30 s does not. Rows still
    /// BIND past this point, so the run looks successful — but without the
    /// terminal ack our own asset stays pending on the device and blocks
    /// `SyncFinished` for every later sync.
    ///
    /// The clock measures SILENCE, not elapsed time. See `lastActivityAt`.
    static let idleAckSeconds: TimeInterval = 25

    /// Idle after which the row no longer binds at all: `base_location_id = 0`,
    /// `location = ''`, bytes GC-swept. Measured 45 s binds, 50 s does not.
    static let idleBindSeconds: TimeInterval = 45

    /// Last time this session put anything on the wire or took anything off it.
    ///
    /// This — not `manifestReceivedAt` — is what the expiry thresholds measure
    /// against. Corrected 2026-08-10 after a 39-file / 73.6 GB run: every file
    /// past the first began well beyond both windows measured from the
    /// manifest (file 2 at 72.6 s, file 39 at 371.3 s), yet all 39 rows bound
    /// and `SyncFinished` arrived instantly. An absolute-age reading predicts
    /// 38 failures; we got none.
    ///
    /// The original experiment varied DEAD AIR after the manifest, so what it
    /// actually measured was how long the device tolerates silence. A session
    /// that keeps working — FileBegin, bytes, FileProgress, FileComplete,
    /// Ping/Pong — stays alive indefinitely. Six minutes of continuous
    /// transfer is fine; twenty-six seconds of nothing is not.
    private(set) var lastActivityAt: Date = Date()

    /// Seconds since this session last exchanged anything with the device.
    var secondsSinceActivity: TimeInterval { Date().timeIntervalSince(lastActivityAt) }

    /// Stamp wire activity. Called from the send and read paths, so any
    /// message in either direction resets the expiry clock.
    func noteActivity() { lastActivityAt = Date() }

    init(device: DeviceInfo, verbose: Bool = false) {
        self.device = device
        self.verbose = verbose
    }

    // MARK: - Public API

    func handshake() throws -> (grappa: Data, anchor: String) {
        // Create connection
        conn = ATH.create(
            "com.mediaporter.sync" as CFString,
            device.udid as CFString,
            0
        )
        guard conn != nil else { throw SyncError.handshakeFailed("CreateWithLibrary returned nil") }
        log("  ATC connection created for \(device.udid.prefix(16))...")

        // SendHostInfo
        let hostInfo: NSDictionary = [
            "LibraryID": "MEDIAPORTER00001",
            "SyncHostName": "mediaporter",
            "SyncedDataclasses": [] as [String],
            "Version": "12.8",
        ]
        check("SendHostInfo", ATH.sendHostInfo(conn!, hostInfo as CFDictionary))
        log("  >> SendHostInfo")

        _ = readUntil("SyncAllowed")
        log("  << SyncAllowed")

        // RequestingSync with host auth seed.
        let grappaData = try loadSyncAuthSeed()
        let hostInfoForSync: NSDictionary = [
            "Grappa": grappaData as CFData,
            "LibraryID": "MEDIAPORTER00001",
            "SyncHostName": "mediaporter",
            "SyncedDataclasses": [] as [String],
            "Version": "12.8",
        ]
        let params: NSDictionary = [
            "DataclassAnchors": ["Media": "0"] as NSDictionary,
            "Dataclasses": ["Media", "Keybag"] as NSArray,
            "HostInfo": hostInfoForSync,
        ]
        guard let msg = ATH.messageCreate(0, "RequestingSync" as CFString, params as CFDictionary) else {
            throw SyncError.handshakeFailed("AirTrafficHost couldn't build RequestingSync message")
        }
        check("RequestingSync", ATH.sendMessage(conn!, msg))
        log("  >> RequestingSync (with Grappa)")

        guard let readyMsg = readUntil("ReadyForSync") else {
            throw SyncError.handshakeFailed("No ReadyForSync received")
        }
        log("  << ReadyForSync")

        // Extract device grappa. Every value here is device-supplied —
        // type-check before bridging (B10: a blind fromOpaque cast on the
        // wrong CF type is undefined behavior, not a catchable error).
        guard let di = ATH.messageParam(readyMsg, "DeviceInfo" as CFString) else {
            throw SyncError.handshakeFailed("No DeviceInfo in ReadyForSync")
        }
        guard CFGetTypeID(unsafeBitCast(di, to: CFTypeRef.self)) == CFDictionaryGetTypeID() else {
            throw SyncError.handshakeFailed("DeviceInfo is not a dictionary")
        }
        let diDict = Unmanaged<CFDictionary>.fromOpaque(di).takeUnretainedValue()
        guard let grappaRef = CFDictionaryGetValue(diDict, Unmanaged.passUnretained("Grappa" as CFString).toOpaque()) else {
            throw SyncError.handshakeFailed("No Grappa in DeviceInfo")
        }
        guard CFGetTypeID(unsafeBitCast(grappaRef, to: CFTypeRef.self)) == CFDataGetTypeID() else {
            throw SyncError.handshakeFailed("Grappa in DeviceInfo is not data")
        }
        let grappaCF = Unmanaged<CFData>.fromOpaque(grappaRef).takeUnretainedValue()
        let grappa = Data(referencing: grappaCF as NSData)
        self.deviceGrappa = grappa
        log("  Device grappa: \(grappa.count)B")

        // Extract anchor — tolerate a missing/mis-typed anchors dict (keep
        // the "0" default), but never bridge without a type check.
        var anchor = "0"
        if let anchorsRaw = ATH.messageParam(readyMsg, "DataclassAnchors" as CFString),
           CFGetTypeID(unsafeBitCast(anchorsRaw, to: CFTypeRef.self)) == CFDictionaryGetTypeID() {
            let anchorsDict = Unmanaged<CFDictionary>.fromOpaque(anchorsRaw).takeUnretainedValue()
            if let mediaRef = CFDictionaryGetValue(anchorsDict, Unmanaged.passUnretained("Media" as CFString).toOpaque()),
               CFGetTypeID(unsafeBitCast(mediaRef, to: CFTypeRef.self)) == CFStringGetTypeID() {
                let mediaCF = Unmanaged<CFString>.fromOpaque(mediaRef).takeUnretainedValue()
                anchor = mediaCF as String
            }
        }
        log("  Anchor: \(anchor)")

        return (grappa, anchor)
    }

    func buildSyncPlist(files: [SyncFileInfo], anchor: Int) throws -> Data {
        let now = Date()
        var operations: [[String: Any]] = [
            [
                "operation": "update_db_info",
                "pid": Int.random(in: 100_000_000_000_000_000..<999_999_999_999_999_999),
                "db_info": [
                    "subtitle_language": -1,
                    "primary_container_pid": 0,
                    "audio_language": -1,
                ] as [String: Any],
            ]
        ]

        for f in files {
            var itemDict: [String: Any] = [
                "title": f.item.title,
                "sort_name": f.item.sortName,
                "total_time_ms": f.item.durationMs,
                "date_created": now,
                "date_modified": now,
                "remember_bookmark": true,
            ]

            if f.item.posterData != nil {
                itemDict["artwork_cache_id"] = Int.random(in: 1...9999)
            }
            // Pair to the second Airlock upload below. Drives the album-row
            // poster on TV.app's Library list.
            if f.item.showPosterData != nil {
                itemDict["album_artwork_cache_id"] = Int.random(in: 1...9999)
            }

            // TV-episode fields live in `video_info` sub-dict, snake_case.
            //
            // Confirmed via AMPDevicesAgent binary string-table dump at
            // 0x784603-0x784711 (the contiguous insert_track key cluster
            // for video_info), 2026-05-15. Accepted keys in this dict:
            //
            //   has_alternate_audio  is_anamorphic   is_hd
            //   has_subtitles        is_compressed   has_closed_captions
            //   is_self_contained    characteristics_valid
            //   season_number   ← drives album.season_number AND item_video.season_number
            //   series_name     ← drives item_artist.series_name (TV.app header label!)
            //   sort_series_name
            //   episode_id      ← string "S03E07" style
            //   episode_sort_id ← int
            //   network_name    ← e.g. "HBO"
            //   extended_content_rating
            //   movie_info      ← TEXT column
            //   audio_track_index audio_track_id
            //   subtitle_track_index subtitle_track_id
            //
            // Earlier rounds we sent these at top of `item` dict (wrong
            // level → silently dropped) and as kebab-case `show-name`/
            // `season-number` (those are iTunes Store metadata keys at
            // 0x770800, a different code path).
            var videoInfoDict: [String: Any] = [
                "has_alternate_audio": f.item.hasAlternateAudio,
                "is_anamorphic": false,
                "has_subtitles": f.item.hasSubtitles,
                "is_hd": f.item.isHD,
                "is_compressed": false,
                "has_closed_captions": false,
                "is_self_contained": false,
                "characteristics_valid": false,
            ]

            if f.item.isTVShow {
                itemDict["is_tv_show"] = true
                if let v = f.item.artist { itemDict["artist"] = v }
                if let v = f.item.sortArtist { itemDict["sort_artist"] = v }
                if let v = f.item.album { itemDict["album"] = v }
                if let v = f.item.sortAlbum { itemDict["sort_album"] = v }
                if let v = f.item.albumArtist { itemDict["album_artist"] = v }
                if let v = f.item.sortAlbumArtist { itemDict["sort_album_artist"] = v }
                // `episode_sort_id` lives on `item` table in current iOS
                // (older schema had it on video_info). Without it TV.app's
                // episode-row label prefixes "0." to the title.
                if let v = f.item.episodeSortID { itemDict["episode_sort_id"] = v }

                if let show = f.item.tvShowName {
                    videoInfoDict["series_name"] = show
                }
                if let v = f.item.sortTVShowName {
                    videoInfoDict["sort_series_name"] = v
                }
                if let s = f.item.seasonNumber {
                    videoInfoDict["season_number"] = s
                }
                if let e = f.item.episodeNumber, let s = f.item.seasonNumber {
                    videoInfoDict["episode_id"] = String(format: "S%02dE%02d", s, e)
                }
                if let v = f.item.episodeSortID {
                    videoInfoDict["episode_sort_id"] = v
                }
            } else {
                itemDict["is_movie"] = true
            }

            DebugLog.write("atc.insert_track",
                "asset=\(f.assetID) title=\"\(f.item.title)\" "
                + "has_alt_audio=\(f.item.hasAlternateAudio) "
                + "has_subs=\(f.item.hasSubtitles) "
                + "is_hd=\(f.item.isHD) "
                + "is_tv=\(f.item.isTVShow) "
                + "channels=\(f.item.channels)")
            operations.append([
                "operation": "insert_track",
                "pid": f.assetID,
                "item": itemDict,
                "location": ["kind": "MPEG-4 video file"],
                "video_info": videoInfoDict,
                "avformat_info": [
                    "bit_rate": 160,
                    "audio_format": 502,
                    "channels": f.item.channels,
                ] as [String: Any],
                "item_stats": [
                    "has_been_played": false,
                    "play_count_recent": 0,
                    "play_count_user": 0,
                    "skip_count_user": 0,
                    "skip_count_recent": 0,
                ] as [String: Any],
            ] as [String: Any])
        }

        let plist: [String: Any] = [
            "revision": anchor,
            "timestamp": now,
            "operations": operations,
        ]

        // Identity dump for re-upload binding diagnosis. We log the tuple
        // medialibraryd uses to match insert_track against existing rows
        // (show + season + episode) plus per-file randoms (assetID, device
        // path, artwork cache ids). When a previously-deleted episode
        // doesn't bind, this is the data we need to compare across runs.
        for f in files {
            let item = f.item
            var parts: [String] = [
                "asset=\(f.assetID)",
                "path=\(f.devicePath)",
                "title=\(item.title)",
            ]
            if item.isTVShow {
                parts.append("show=\(item.tvShowName ?? "")")
                if let s = item.seasonNumber { parts.append("s=\(s)") }
                if let e = item.episodeNumber { parts.append("e=\(e)") }
                if let id = item.episodeSortID { parts.append("ep_sort=\(id)") }
            }
            DebugLog.write("atc.plist.identity", parts.joined(separator: " "))
        }

        do {
            return try PropertyListSerialization.data(
                fromPropertyList: plist,
                format: .binary,
                options: 0
            )
        } catch {
            // Only reachable if a non-plist type sneaks into the dict —
            // pinned against by SyncPlistTests, but crash-free regardless (B1).
            throw SyncError.protocolError("sync plist serialization failed: \(error.localizedDescription)")
        }
    }

    /// Build a delete-only sync plist — single `delete_track` op per
    /// `syncID`, no `update_db_info`. We intentionally skip
    /// `update_db_info` because earlier traces showed it can trigger
    /// unrelated library-wide rewrites that we don't want on a focused
    /// delete. The pid we send IS the sync_id (the original wire pid
    /// from the insert), not the renumbered DB `item_pid`. medialibraryd
    /// resolves deletes by `item_store.sync_id`, not by `item.item_pid`
    /// (codex review 2026-05-17 + research/docs/HISTORY.md 2026-05-16
    /// on pid-renumbering semantics).
    func buildDeletePlist(syncIDs: [Int], anchor: Int) throws -> Data {
        let ops: [[String: Any]] = syncIDs.map { sid in
            ["operation": "delete_track", "pid": sid]
        }
        let plist: [String: Any] = [
            "revision": anchor,
            "timestamp": Date(),
            "operations": ops,
        ]
        DebugLog.write("atc.plist.delete",
            "anchor=\(anchor) count=\(syncIDs.count) syncIDs=\(syncIDs.map { String($0) }.joined(separator: ","))")
        do {
            return try PropertyListSerialization.data(
                fromPropertyList: plist, format: .binary, options: 0)
        } catch {
            throw SyncError.protocolError("delete plist serialization failed: \(error.localizedDescription)")
        }
    }

    func computeCIG(deviceGrappa: Data, plistData: Data) throws -> Data {
        var cigOut = [UInt8](repeating: 0, count: 21)
        var cigLen: Int32 = 21

        let rc = deviceGrappa.withUnsafeBytes { grappaPtr in
            plistData.withUnsafeBytes { plistPtr in
                CIG.calc(
                    grappaPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    plistPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    Int32(plistData.count),
                    &cigOut,
                    &cigLen
                )
            }
        }

        guard rc == 1 else { throw SyncError.cigFailed }
        return Data(cigOut.prefix(Int(cigLen)))
    }

    func register(
        afc: AFCClient,
        files: [SyncFileInfo],
        plistData: Data,
        cigData: Data,
        anchor: String,
        afterFileComplete: ((Int, SyncFileInfo) -> Void)? = nil
    ) throws {
        // Step 1: Write plist + CIG
        afc.makedirs("/iTunes_Control/Sync/Media")
        let plistPath = String(format: "/iTunes_Control/Sync/Media/Sync_%08d.plist", Int(anchor)!)
        try afc.writeFile(plistPath, data: plistData)
        try afc.writeFile(plistPath + ".cig", data: cigData)
        log("  AFC: plist+CIG -> \(plistPath)")

        // Step 2: SendPowerAssertion + MetadataSyncFinished
        log("  >> SendPowerAssertion")
        check("SendPowerAssertion", ATH.sendPowerAssertion(conn!, kCFBooleanTrue))
        log("  >> MetadataSyncFinished (anchor=\"\(anchor)\")")
        DebugLog.write("atc.MetadataSyncFinished", "anchor=\(anchor)")
        try checkOrThrow("MetadataSyncFinished", ATH.sendMetadataSyncFinished(
            conn!,
            ["Keybag": 1, "Media": 1] as NSDictionary as CFDictionary,
            ["Media": anchor] as NSDictionary as CFDictionary
        ))

        // Step 3: Read AssetManifest
        var gotManifest = false
        let ourIDs = Set(files.map { String($0.assetID) })
        var staleIDs: [String] = []
        log("  Waiting for AssetManifest...")

        // Mirror the wire trace to DebugLog, not just the `verbose` print.
        // The GUI constructs its RegisterSession with verbose:false, so when
        // this loop bailed in ~1.1 s the only surviving evidence was
        // "No AssetManifest received" with no indication of *why* — a
        // half-second connection drop and a 450 s device stall produced the
        // identical message. Distinguishing them matters: one is a retry, the
        // other is a device that needs waking.
        let manifestWaitStart = Date()
        // Budget by wall clock, NOT by message count.
        //
        // While medialibraryd scans its library to build the manifest it
        // streams `Progress` messages — roughly one per announced asset. The
        // old `for _ in 0..<30` loop didn't handle `Progress`, so each one
        // silently consumed an iteration: a 39-asset sync burned the entire
        // budget on progress updates in ~1 s and threw `noManifest` before the
        // manifest could arrive, while a 1-asset sync sailed through. It read
        // as a device-side scale limit; it was our own reader giving up.
        //
        // Waiting longer here costs nothing — the asset-expiry clock starts at
        // manifest *receipt* (`manifestReceivedAt`), so time spent before that
        // is free. What we must not do is bail early.
        // 180 s: a device that just ingested tens of GB indexes for minutes
        // before it can answer. Time spent here is free — the expiry clock
        // starts at manifest receipt.
        let manifestDeadline = manifestWaitStart.addingTimeInterval(180)
        var manifestTrace: [String] = []
        var progressCount = 0
        var quietReads = 0
        while Date() < manifestDeadline {
            let (msg, name) = readMsg(timeout: 15)
            guard let name else {
                // readMsg yields a nil name only when ATH.readMessage itself
                // returned nil — the connection is gone. A timeout comes back
                // as the literal "TIMEOUT" and keeps looping.
                DebugLog.error(
                    "atc.AssetManifest",
                    "connection closed after \(String(format: "%.1f", Date().timeIntervalSince(manifestWaitStart)))s "
                    + "waiting for AssetManifest — \(progressCount) Progress, "
                    + "trace: [\(manifestTrace.joined(separator: ", "))]"
                )
                break
            }
            // Library-scan heartbeat while the manifest is being built. Common
            // and uninteresting individually — counted, not traced, so the
            // diagnostic line stays readable at 39+ assets.
            if name == "Progress" {
                progressCount += 1
                continue
            }
            // A read timeout means the device is QUIET, which is exactly what
            // a busy one looks like: after ingesting a large batch,
            // medialibraryd can go minutes between messages while it indexes.
            // Bailing on consecutive timeouts cut a healthy sync off at 47 s
            // right after a 73.6 GB run. Let the deadline be the only bound —
            // a genuinely dead connection returns a nil name and breaks above,
            // which is the real "device gone" signal.
            if name == "TIMEOUT" {
                quietReads += 1
                continue
            }
            manifestTrace.append(name)
            log("  << \(name)")
            if name == "Ping" { sendPong(); continue }
            if name == "SyncFailed" { throw SyncError.rejected }
            if name == "AssetManifest" {
                gotManifest = true
                if verbose, let m = msg { CFShow(m as CFTypeRef) }
                if let m = msg {
                    dumpManifest(m)
                    staleIDs = extractStaleAssets(manifestMsg: m, ourIDs: ourIDs)
                    if !staleIDs.isEmpty {
                        log("  Manifest contains \(staleIDs.count) stale pending asset(s)")
                    }
                }
                break
            }
            if name == "SyncFinished" { break }
        }

        let manifestWait = Date().timeIntervalSince(manifestWaitStart)
        guard gotManifest else {
            DebugLog.error(
                "atc.AssetManifest",
                "giving up after \(String(format: "%.1f", manifestWait))s, "
                + "\(progressCount) Progress, \(quietReads) quiet read(s), \(manifestTrace.count) other: "
                + "[\(manifestTrace.joined(separator: ", "))]"
            )
            throw SyncError.noManifest
        }
        DebugLog.notice(
            "atc.AssetManifest",
            "received after \(String(format: "%.1f", manifestWait))s "
            + "(\(progressCount) Progress message(s) during the library scan)"
        )

        // Step 4: FileBegin + FileComplete for each file (already uploaded)
        afc.makedirs("/Airlock/Media")
        afc.makedirs("/Airlock/Media/Artwork")

        for (idx, f) in files.enumerated() {
            let aid = String(f.assetID)

            log("  >> FileBegin (asset=\(aid))")
            try sendMsgOrThrow("FileBegin", [
                "AssetID": aid,
                "FileSize": f.item.fileSize,
                "TotalSize": f.item.fileSize,
                "Dataclass": "Media",
            ])

            // Upload artwork if available
            if let poster = f.item.posterData {
                let artPath = "/Airlock/Media/Artwork/\(f.assetID)"
                log("  AFC: artwork -> \(artPath) (\(poster.count / 1024) KB)")
                try afc.writeFile(artPath, data: poster)
            }
            // Second Airlock artwork — show portrait for the album row.
            if let showPoster = f.item.showPosterData {
                let artPath = "/Airlock/Media/Artwork/\(f.assetID)_show"
                log("  AFC: show artwork -> \(artPath) (\(showPoster.count / 1024) KB)")
                try afc.writeFile(artPath, data: showPoster)
            }

            sendMsg("FileProgress", [
                "AssetID": aid,
                "AssetProgress": 1.0,
                "OverallProgress": 1.0,
                "Dataclass": "Media",
            ])

            log("  >> FileComplete (path=\(f.devicePath))")
            try sendMsgOrThrow("FileComplete", [
                "AssetID": aid,
                "AssetPath": f.devicePath,
                "Dataclass": "Media",
            ])

            // Hook for the gating experiment (#8): caller can probe device
            // state between FileCompletes. Production callers leave this nil.
            afterFileComplete?(idx, f)
        }

        // Send FileError for stale pending assets from previous failed syncs.
        // Without this, the device waits indefinitely for them and never
        // sends SyncFinished (CLAUDE.md finding #14).
        if !staleIDs.isEmpty {
            log("  Clearing \(staleIDs.count) stale pending asset(s)...")
            for sid in staleIDs {
                log("  >> FileError (stale asset=\(sid))")
                sendMsg("FileError", [
                    "AssetID": sid,
                    "Dataclass": "Media",
                    "ErrorCode": 0,
                ])
            }
        }

        // Step 5: Wait for SyncFinished
        log("  Waiting for SyncFinished...")
        var timeouts = 0
        var gotSyncAllowed = false

        for _ in 0..<120 {
            let (_, name) = readMsg(timeout: 5)
            guard let name else { break }
            if name == "TIMEOUT" {
                timeouts += 1
                if gotSyncAllowed {
                    log("  *** SYNC COMPLETE (device returned to idle) ***")
                    return
                }
                if timeouts >= 12 {
                    log("  SyncFinished not received (timeout)")
                    return
                }
                continue
            }
            timeouts = 0
            log("  << \(name)")
            if name == "Ping" { sendPong(); continue }
            if name == "SyncFinished" {
                log("  *** SYNC COMPLETE ***")
                return
            }
            if name == "SyncAllowed" { gotSyncAllowed = true }
        }
    }

    // MARK: - Streaming register API (plan #8)
    //
    // Lifecycle: handshake() → prepareSync() → [registerFile()...|abandonAsset()...] → finishSync()
    //
    // Lets PipelineController interleave per-file FileBegin/FileComplete with
    // the AFC upload loop so medialibraryd commits rows progressively instead
    // of in a 30 s/file burst at terminal SyncFinished. See plan #8 and the
    // gate-test confirmation in plan.md.
    //
    // The same AFC connection is reused for the plist write + per-file artwork
    // uploads. A background thread drains incoming ATC messages: it answers
    // every Ping with a Pong (else the session drops mid-batch — CLAUDE.md #9)
    // and stashes anything else (SyncFinished, SyncFailed, Ping-Pong noise) in
    // an inbox that finishSync() polls.

    /// Phase 1 of streaming register. Writes the upfront plist+CIG, sends
    /// MetadataSyncFinished, waits for AssetManifest, clears stale pending
    /// assets, and starts the Ping drainer. After this returns, the caller
    /// can interleave registerFile() calls with AFC uploads.
    func prepareSync(
        afc: AFCClient,
        files: [SyncFileInfo],
        plistData: Data,
        cigData: Data,
        anchor: String,
        progress: ((String) -> Void)? = nil
    ) throws {
        // Step 1: Write plist + CIG
        progress?("Writing sync manifest to device…")
        afc.makedirs("/iTunes_Control/Sync/Media")
        let plistPath = String(format: "/iTunes_Control/Sync/Media/Sync_%08d.plist", Int(anchor)!)
        try afc.writeFile(plistPath, data: plistData)
        try afc.writeFile(plistPath + ".cig", data: cigData)
        log("  AFC: plist+CIG -> \(plistPath)")

        // Step 2: SendPowerAssertion + MetadataSyncFinished
        log("  >> SendPowerAssertion")
        check("SendPowerAssertion", ATH.sendPowerAssertion(conn!, kCFBooleanTrue))
        log("  >> MetadataSyncFinished (anchor=\"\(anchor)\")")
        DebugLog.write("atc.MetadataSyncFinished", "anchor=\(anchor)")
        try checkOrThrow("MetadataSyncFinished", ATH.sendMetadataSyncFinished(
            conn!,
            ["Keybag": 1, "Media": 1] as NSDictionary as CFDictionary,
            ["Media": anchor] as NSDictionary as CFDictionary
        ))

        // Step 3: Wait AssetManifest, capture stale IDs.
        var gotManifest = false
        let ourIDs = Set(files.map { String($0.assetID) })
        var staleIDs: [String] = []
        progress?("Waiting for device library scan (AssetManifest)…")
        log("  Waiting for AssetManifest...")
        // Mirror the wire trace to DebugLog, not just the `verbose` print.
        // The GUI constructs its RegisterSession with verbose:false, so when
        // this loop bailed in ~1.1 s the only surviving evidence was
        // "No AssetManifest received" with no indication of *why* — a
        // half-second connection drop and a 450 s device stall produced the
        // identical message. Distinguishing them matters: one is a retry, the
        // other is a device that needs waking.
        let manifestWaitStart = Date()
        // Budget by wall clock, NOT by message count.
        //
        // While medialibraryd scans its library to build the manifest it
        // streams `Progress` messages — roughly one per announced asset. The
        // old `for _ in 0..<30` loop didn't handle `Progress`, so each one
        // silently consumed an iteration: a 39-asset sync burned the entire
        // budget on progress updates in ~1 s and threw `noManifest` before the
        // manifest could arrive, while a 1-asset sync sailed through. It read
        // as a device-side scale limit; it was our own reader giving up.
        //
        // Waiting longer here costs nothing — the asset-expiry clock starts at
        // manifest *receipt* (`manifestReceivedAt`), so time spent before that
        // is free. What we must not do is bail early.
        // 180 s: a device that just ingested tens of GB indexes for minutes
        // before it can answer. Time spent here is free — the expiry clock
        // starts at manifest receipt.
        let manifestDeadline = manifestWaitStart.addingTimeInterval(180)
        var manifestTrace: [String] = []
        var progressCount = 0
        var quietReads = 0
        while Date() < manifestDeadline {
            let (msg, name) = readMsg(timeout: 15)
            guard let name else {
                // readMsg yields a nil name only when ATH.readMessage itself
                // returned nil — the connection is gone. A timeout comes back
                // as the literal "TIMEOUT" and keeps looping.
                DebugLog.error(
                    "atc.AssetManifest",
                    "connection closed after \(String(format: "%.1f", Date().timeIntervalSince(manifestWaitStart)))s "
                    + "waiting for AssetManifest — \(progressCount) Progress, "
                    + "trace: [\(manifestTrace.joined(separator: ", "))]"
                )
                break
            }
            // Library-scan heartbeat while the manifest is being built. Common
            // and uninteresting individually — counted, not traced, so the
            // diagnostic line stays readable at 39+ assets.
            if name == "Progress" {
                progressCount += 1
                continue
            }
            // A read timeout means the device is QUIET, which is exactly what
            // a busy one looks like: after ingesting a large batch,
            // medialibraryd can go minutes between messages while it indexes.
            // Bailing on consecutive timeouts cut a healthy sync off at 47 s
            // right after a 73.6 GB run. Let the deadline be the only bound —
            // a genuinely dead connection returns a nil name and breaks above,
            // which is the real "device gone" signal.
            if name == "TIMEOUT" {
                quietReads += 1
                continue
            }
            manifestTrace.append(name)
            log("  << \(name)")
            if name == "Ping" { sendPong(); continue }
            if name == "SyncFailed" { throw SyncError.rejected }
            if name == "AssetManifest" {
                gotManifest = true
                // Start the delivery-window clock here, not at open() — this
                // is the point after which idling costs us the assets.
                manifestReceivedAt = Date()
                if let m = msg {
                    dumpManifest(m)
                    staleIDs = extractStaleAssets(manifestMsg: m, ourIDs: ourIDs)
                }
                break
            }
            if name == "SyncFinished" { break }
        }
        let manifestWait = Date().timeIntervalSince(manifestWaitStart)
        guard gotManifest else {
            DebugLog.error(
                "atc.AssetManifest",
                "giving up after \(String(format: "%.1f", manifestWait))s, "
                + "\(progressCount) Progress, \(quietReads) quiet read(s), \(manifestTrace.count) other: "
                + "[\(manifestTrace.joined(separator: ", "))]"
            )
            throw SyncError.noManifest
        }
        DebugLog.notice(
            "atc.AssetManifest",
            "received after \(String(format: "%.1f", manifestWait))s "
            + "(\(progressCount) Progress message(s) during the library scan)"
        )

        // Clear stale pending assets up front. Doing this before any of our
        // own FileBegins is safer than the old end-of-batch sweep (no race
        // with medialibraryd accepting our IDs first).
        if !staleIDs.isEmpty {
            progress?("Clearing \(staleIDs.count) stale pending asset(s) from prior syncs…")
            log("  Clearing \(staleIDs.count) stale pending asset(s)...")
            DebugLog.notice("atc.FileError.stale", "count=\(staleIDs.count) ids=\(staleIDs.joined(separator: ","))")
            for sid in staleIDs {
                sendMsg("FileError", [
                    "AssetID": sid,
                    "Dataclass": "Media",
                    "ErrorCode": 0,
                ])
            }
        }
        // Remember what we tried to clear. An ID that shows up again in a
        // later manifest is one FileError(0) demonstrably failed on — the
        // expired-asset signature — and `healStuckAssets` will delete_track
        // it before the NEXT run opens a session. Recording an empty list is
        // meaningful too: it retires IDs the FileError(0) did clear.
        StuckAssetLedger.recordManifest(staleIDs: staleIDs, udid: device.udid)

        // Make sure Airlock dirs exist before per-file artwork uploads.
        afc.makedirs("/Airlock/Media")
        afc.makedirs("/Airlock/Media/Artwork")

        self.streamingAFC = afc
        self.ourAssetIDs = ourIDs
        startDrainer()
    }

    /// Delete-only variant of `prepareSync`. Writes the delete plist +
    /// CIG, sends MetadataSyncFinished, then drains any AssetManifest /
    /// Ping that arrives (responding to Pings) but DOES NOT require an
    /// AssetManifest — codex 2026-05-17 / T5 evidence (PHANTOM_REP_PID_TESTS
    /// section "T5"): medialibraryd processes a delete-only plist and
    /// commits the row removal even when no AssetManifest is emitted in
    /// reply. Starts the Ping drainer so the caller can call
    /// `finishSync()` straight after.
    func prepareDelete(
        afc: AFCClient,
        plistData: Data, cigData: Data, anchor: String,
        progress: ((String) -> Void)? = nil
    ) throws {
        progress?("Writing delete manifest to device…")
        afc.makedirs("/iTunes_Control/Sync/Media")
        let plistPath = String(
            format: "/iTunes_Control/Sync/Media/Sync_%08d.plist", Int(anchor)!)
        try afc.writeFile(plistPath, data: plistData)
        try afc.writeFile(plistPath + ".cig", data: cigData)
        log("  AFC: delete plist+CIG -> \(plistPath)")

        log("  >> SendPowerAssertion")
        check("SendPowerAssertion", ATH.sendPowerAssertion(conn!, kCFBooleanTrue))
        log("  >> MetadataSyncFinished (anchor=\"\(anchor)\", delete-only)")
        DebugLog.write("atc.MetadataSyncFinished", "anchor=\(anchor) mode=delete")
        try checkOrThrow("MetadataSyncFinished", ATH.sendMetadataSyncFinished(
            conn!,
            ["Keybag": 1, "Media": 1] as NSDictionary as CFDictionary,
            ["Media": anchor] as NSDictionary as CFDictionary
        ))

        // Quick drain — if an AssetManifest comes we read past it but do
        // NOT treat its absence as failure. Also catch an early
        // SyncFinished so finishSync() exits immediately when the device
        // is fast.
        progress?("Waiting for device to acknowledge delete…")
        for _ in 0..<10 {
            let (_, name) = readMsg(timeout: 3)
            guard let name else { break }
            log("  << \(name)")
            if name == "Ping" { sendPong(); continue }
            if name == "SyncFailed" { throw SyncError.rejected }
            if name == "AssetManifest" { break }
            if name == "SyncFinished" {
                // Stash for finishSync() to pick up.
                inboxLock.lock(); inbox.append(name); inboxLock.unlock()
                break
            }
        }

        self.streamingAFC = afc
        self.ourAssetIDs = []
        startDrainer()
    }

    /// Phase 2 (per-file). Sends FileBegin → artwork upload → FileProgress →
    /// FileComplete. Bytes for `f.devicePath` must already be on the device
    /// via AFC at this point (caller's responsibility — typically right
    /// after `AFCUploader.upload` returns for this file). Each call commits
    /// the row in MediaLibrary.sqlitedb within ~1 s on the device.
    /// Send FileBegin only. Must be sent BEFORE AFC upload so medialibraryd
    /// can match incoming bytes at `f.devicePath` to the announced asset_id.
    /// The Swift port previously did this AFTER upload (registerFile bundled
    /// both halves) and rows ended up unbound — bytes arrived at the path
    /// with no prior claim, medialibraryd stored them as orphan, and the
    /// later FileComplete didn't retroactively bind. python-reference's
    /// upload_and_register is FileBegin → upload → FileProgress+Complete.
    func beginFile(_ f: SyncFileInfo) throws {
        guard streamingAFC != nil else {
            throw SyncError.handshakeFailed("beginFile called before prepareSync")
        }
        let aid = String(f.assetID)
        // Age of the delivery window at the moment we claim the asset. This is
        // THE number that decides whether the row binds (CLAUDE.md #16): the
        // wire accepts FileBegin either way, so without this line an expired
        // asset is indistinguishable from a healthy one until the user finds
        // an unplayable title in TV.app. Logged at .error past the danger
        // threshold so it survives `log show` without --info.
        let age = secondsSinceManifest ?? 0
        let idle = secondsSinceActivity
        let ageMsg = String(format: "asset=%@ path=%@ size=%d idle=%.1fs manifestAge=%.1fs",
                            aid, f.devicePath, f.item.fileSize, idle, age)
        if idle >= ATCSession.idleBindSeconds {
            DebugLog.error("atc.FileBegin",
                ageMsg + " *** \(Int(ATCSession.idleBindSeconds))s+ of silence — this asset will land UNBOUND")
        } else if idle >= ATCSession.idleAckSeconds {
            DebugLog.error("atc.FileBegin",
                ageMsg + " *** \(Int(ATCSession.idleAckSeconds))s+ of silence — the row should still bind, but expect no SyncFinished and a stranded pending asset")
        } else {
            DebugLog.notice("atc.FileBegin", ageMsg)
        }
        log("  >> FileBegin (asset=\(aid), manifest age \(String(format: "%.1f", age))s)")
        sendMsg("FileBegin", [
            "AssetID": aid,
            "FileSize": f.item.fileSize,
            "TotalSize": f.item.fileSize,
            "Dataclass": "Media",
        ])
    }

    /// Send artwork upload + FileProgress + FileComplete. Call AFTER the AFC
    /// upload of `f.devicePath` has finished. Pair with a prior beginFile.
    func completeFile(_ f: SyncFileInfo) throws {
        guard let afc = streamingAFC else {
            throw SyncError.handshakeFailed("completeFile called before prepareSync")
        }
        let aid = String(f.assetID)

        if let poster = f.item.posterData {
            let artPath = "/Airlock/Media/Artwork/\(f.assetID)"
            log("  AFC: artwork -> \(artPath) (\(poster.count / 1024) KB)")
            try afc.writeFile(artPath, data: poster)
        }
        if let showPoster = f.item.showPosterData {
            let artPath = "/Airlock/Media/Artwork/\(f.assetID)_show"
            log("  AFC: show artwork -> \(artPath) (\(showPoster.count / 1024) KB)")
            try afc.writeFile(artPath, data: showPoster)
        }

        sendMsg("FileProgress", [
            "AssetID": aid,
            "AssetProgress": 1.0,
            "OverallProgress": 1.0,
            "Dataclass": "Media",
        ])

        log("  >> FileComplete (path=\(f.devicePath))")
        DebugLog.write("atc.FileComplete", "asset=\(aid) path=\(f.devicePath)")
        sendMsg("FileComplete", [
            "AssetID": aid,
            "AssetPath": f.devicePath,
            "Dataclass": "Media",
        ])
    }

    /// Legacy bundled call — FileBegin + artwork + FileProgress + FileComplete
    /// in one shot. Kept for callers that pre-uploaded (legacy register path,
    /// orphan recovery). Do NOT use from the streaming pipelined flow — bytes
    /// must already be on the device when this runs, otherwise rows stay
    /// unbound.
    func registerFile(_ f: SyncFileInfo) throws {
        try beginFile(f)
        try completeFile(f)
    }

    /// Send an in-progress FileProgress for `assetID`. Used to keep
    /// medialibraryd's per-asset timer from giving up on a long upload —
    /// without periodic progress hints, multi-GB transfers can finish AFC-side
    /// but the device has already marked the asset slot as stale, so the
    /// terminal FileComplete binds nothing and the bytes get GC'd as orphan.
    /// Callers should throttle (every ~5 s / ~10 %).
    func sendProgress(assetID: Int, fraction: Double) {
        let aid = String(assetID)
        let p = max(0.0, min(1.0, fraction))
        sendMsg("FileProgress", [
            "AssetID": aid,
            "AssetProgress": p,
            "OverallProgress": p,
            "Dataclass": "Media",
        ])
        DebugLog.write("atc.FileProgress", "asset=\(assetID) frac=\(String(format: "%.2f", p))")
    }

    /// Send FileError(0) for an asset we will NOT be FileCompleting (transcode
    /// failure, user cancel mid-batch, etc.). Without this, medialibraryd
    /// blocks SyncFinished waiting for the missing asset (CLAUDE.md #8).
    func abandonAsset(assetID: Int) {
        log("  >> FileError (abandon asset=\(assetID))")
        DebugLog.notice("atc.abandonAsset", "id=\(assetID)")
        sendMsg("FileError", [
            "AssetID": String(assetID),
            "Dataclass": "Media",
            "ErrorCode": 0,
        ])
    }

    /// How the wait for `SyncFinished` actually ended. Only `.finished`
    /// means the device confirmed the commit; the caller decides how loudly
    /// to surface the rest (B8 — a timeout used to be indistinguishable
    /// from success).
    enum SyncFinishOutcome: Sendable {
        case finished           // real SyncFinished — row committed
        case allowedFallback    // SyncAllowed + 30 s grace, device never confirmed
        case connectionLost     // transport died before SyncFinished
        case timeout            // hard deadline hit with no signal at all
    }

    /// Phase 3. Waits for SyncFinished by polling the drainer's inbox (no
    /// direct readMsg — that would race the drainer for the single ATC
    /// connection and silently swallow SyncFinished).
    ///
    /// Treat ONLY `SyncFinished` as the terminal "row is bound and committed"
    /// signal. `SyncAllowed` is sent by the device much earlier (right after
    /// FileBegin / MetadataSyncFinished) as "you may proceed", and during a
    /// long upload it accumulates in the drainer inbox. If we treat it as
    /// terminal, finishSync returns instantly without medialibraryd ever
    /// committing our asset → row exists with base_location_id=0, file gets
    /// swept by background GC, TV.app shows the title with no playable file.
    /// Symptom in the wild: 1.5 GB Violet HEVC transcode (2026-05-14).
    ///
    /// Strategy:
    /// 1. Drop anything that landed in the inbox before we got here — old
    ///    SyncAllowed / InstalledAssets / AssetMetrics from the upload phase
    ///    are stale, not commit signals for the just-finished file.
    /// 2. Wait up to 120 s for `SyncFinished`.
    /// 3. Fallback: if `SyncAllowed` arrives but no `SyncFinished` follows
    ///    within 30 s, accept it with a warning so we don't hang forever on
    ///    a misbehaving device.
    @discardableResult
    func finishSync(deadlineSeconds: TimeInterval = 120) -> SyncFinishOutcome {
        log("  Waiting for SyncFinished...")
        DebugLog.write("atc.finishSync.wait", "deadline=\(Int(deadlineSeconds))s")
        let start = Date()
        let hardDeadline = start.addingTimeInterval(deadlineSeconds)

        // Drop pre-existing inbox entries — they're from the upload phase,
        // not commit signals for the just-finished file. `SyncFinished` is
        // the one exception: it is only ever sent once, as the terminal
        // commit, so if it landed while the caller was still between
        // FileComplete and this call it is ours and discarding it would
        // burn the full deadline waiting for a message that already came.
        // (Seen 2026-08-03 in `idle-test`, which reads the device DB after
        // FileComplete: SyncFinished arrived during the pull and the run
        // reported a bogus timeout on a row that had bound correctly.)
        let stale = drainInbox()
        if !stale.isEmpty {
            DebugLog.notice("atc.finishSync.discard_stale", "names=\(stale.joined(separator: ","))")
        }
        if stale.contains("SyncFinished") {
            log("  *** SYNC COMPLETE (SyncFinished arrived before finishSync) ***")
            DebugLog.notice("atc.finishSync.done", "via=SyncFinished_early elapsed=0s")
            stopDrainer()
            return .finished
        }

        var syncAllowedAt: Date? = nil
        while Date() < hardDeadline {
            for name in drainInbox() {
                log("  << \(name)")
                DebugLog.write("atc.inbox", "\(name) (+\(Int(Date().timeIntervalSince(start)))s)")
                if name == "SyncFinished" {
                    log("  *** SYNC COMPLETE (SyncFinished) ***")
                    DebugLog.write("atc.finishSync.done", "via=SyncFinished elapsed=\(Int(Date().timeIntervalSince(start)))s")
                    stopDrainer()
                    return .finished
                }
                if name == "SyncAllowed" && syncAllowedAt == nil {
                    syncAllowedAt = Date()
                    DebugLog.notice("atc.finishSync.syncallowed", "waiting up to 30s for SyncFinished")
                }
            }
            // Fallback: SyncAllowed seen, no SyncFinished after 30 s grace.
            if let sa = syncAllowedAt, Date().timeIntervalSince(sa) > 30 {
                log("  *** SYNC COMPLETE (SyncAllowed fallback, no SyncFinished) ***")
                DebugLog.notice("atc.finishSync.done", "via=SyncAllowed_fallback elapsed=\(Int(Date().timeIntervalSince(start)))s")
                stopDrainer()
                return .allowedFallback
            }
            // Connection dropped mid-wait (after the inbox above was drained, so
            // any SyncFinished that landed first already won). No point burning
            // the full 120s deadline on a dead socket.
            if isConnectionDead() {
                log("  *** ATC connection lost before SyncFinished ***")
                DebugLog.error("atc.finishSync.dead", "connection died after \(Int(Date().timeIntervalSince(start)))s — no SyncFinished")
                stopDrainer()
                return .connectionLost
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        log("  SyncFinished not received (\(Int(deadlineSeconds)) s timeout)")
        DebugLog.error("atc.finishSync.timeout", "elapsed=\(Int(deadlineSeconds))s")
        stopDrainer()
        return .timeout
    }

    /// Atomically pull and clear all pending message names from the drainer's
    /// inbox. Used by finishSync; never call from inside the drainer thread.
    private func drainInbox() -> [String] {
        inboxLock.lock(); defer { inboxLock.unlock() }
        let snapshot = inbox
        inbox.removeAll(keepingCapacity: true)
        return snapshot
    }

    // MARK: - Drainer

    private func startDrainer() {
        drainerStop = false
        inboxLock.lock(); connectionDead = false; inboxLock.unlock()
        let t = Thread { [weak self] in
            guard let self else { return }
            while !self.drainerStop {
                guard let c = self.conn else { return }
                // BLOCKING read — no inner timeout. ATH.readMessage parks
                // until either a real message arrives or the connection is
                // invalidated by close(). The previous timeout-based path
                // leaked an inflight ATH.readMessage on every TIMEOUT, and
                // when SyncFinished finally arrived it landed in a leaked
                // reader whose result was already discarded — so finishSync
                // never saw it and hung until the 120 s hard deadline.
                guard let msg = ATH.readMessage(c) else {
                    // nil = conn invalidated (close called) or transport error.
                    // This is the AUTHORITATIVE peer-death signal — far earlier
                    // than finishSync's 120s deadline. drainerStop distinguishes
                    // our own teardown (expected) from a mid-sync drop (yank /
                    // Wi-Fi loss): only the latter flags the connection dead so
                    // the next must-ack checkOrThrow aborts fast.
                    if !self.drainerStop {
                        self.markConnectionDead("drainer read returned nil mid-session (transport error / peer death)")
                    }
                    return
                }
                guard let nameCF = ATH.messageName(msg) else { continue }
                let name = nameCF as String
                if name == "Ping" {
                    self.sendPong()
                    DebugLog.write("atc.drainer", "Ping → Pong")
                    continue
                }
                DebugLog.write("atc.drainer", "<< \(name)")
                self.inboxLock.lock()
                self.inbox.append(name)
                self.inboxLock.unlock()
            }
        }
        t.name = "atc-ping-drainer"
        t.start()
        self.drainerThread = t
    }

    private func stopDrainer() {
        // Just flips the flag. The drainer's blocking ATH.readMessage will
        // be unblocked when close() invalidates the connection — that's the
        // intended teardown path. We don't join the thread (it's a Thread,
        // not a Task) but the flag prevents any further inbox writes.
        drainerStop = true
        drainerThread = nil
    }

    /// Wait `seconds` while keeping the ATC session alive: any Ping the
    /// device sends gets a Pong, otherwise the session drops (CLAUDE.md #9).
    /// Used by the #8 gating experiment to stall between FileCompletes.
    /// SyncFinished or other terminal messages arriving during the sleep
    /// are ignored — the experiment expects to see device-side state change
    /// without forcing the sync to terminate.
    func pingAwareSleep(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            let (_, name) = readMsg(timeout: min(remaining, 5))
            guard let name else { break }
            if name == "TIMEOUT" { continue }
            if name == "Ping" { sendPong(); continue }
            log("  (during sleep) << \(name)")
        }
    }

    func close() {
        stopDrainer()
        streamingAFC = nil
        if let c = conn {
            _ = ATH.invalidate(c)  // status code; nothing actionable on teardown
            ATH.release(c)
            conn = nil
        }
    }

    deinit { close() }

    // MARK: - Helpers

    static func generateDevicePath() -> (path: String, slot: String) {
        let slot = String(format: "F%02d", Int.random(in: 0...49))
        let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        let name = String((0..<4).map { _ in chars.randomElement()! }) + ".mp4"
        return ("/iTunes_Control/Music/\(slot)/\(name)", slot)
    }

    static func generateAssetID() -> Int {
        Int.random(in: 100_000_000_000_000_000..<999_999_999_999_999_999)
    }

    // MARK: - Private

    private func log(_ msg: String) {
        if verbose { print(msg) }
    }

    /// Diagnostic-only dump of every AssetManifest entry medialibraryd
    /// reported. Used to debug re-upload binding: when a previously-deleted
    /// episode silently fails to land, we need to know what the device
    /// thought was already present at the moment we hit FinishedSyncingMetadata.
    /// Writes to DebugLog under tag "atc.manifest".
    private func dumpManifest(_ manifestMsg: UnsafeMutableRawPointer) {
        guard let manifestRaw = ATH.messageParam(manifestMsg, "AssetManifest" as CFString) else {
            DebugLog.write("atc.manifest", "(no AssetManifest param)")
            return
        }
        let manifest = Unmanaged<CFDictionary>.fromOpaque(manifestRaw).takeUnretainedValue()
        let mediaKey = Unmanaged.passUnretained("Media" as CFString).toOpaque()
        guard let mediaRaw = CFDictionaryGetValue(manifest, mediaKey) else {
            DebugLog.write("atc.manifest", "(no Media key)")
            return
        }
        let mediaArray = Unmanaged<CFArray>.fromOpaque(mediaRaw).takeUnretainedValue()
        let count = CFArrayGetCount(mediaArray)
        DebugLog.write("atc.manifest", "count=\(count)")
        for i in 0..<count {
            guard let itemRaw = CFArrayGetValueAtIndex(mediaArray, i) else { continue }
            let itemDict = Unmanaged<CFDictionary>.fromOpaque(itemRaw).takeUnretainedValue()
            let nsDict = itemDict as NSDictionary
            let keys = (nsDict.allKeys as? [String]) ?? []
            let pairs = keys.sorted().map { k -> String in
                let v = nsDict[k]
                return "\(k)=\(v ?? "nil")"
            }
            DebugLog.write("atc.manifest[\(i)]", pairs.joined(separator: " "))
        }
    }

    private func extractStaleAssets(manifestMsg: UnsafeMutableRawPointer, ourIDs: Set<String>) -> [String] {
        var stale: [String] = []
        guard let manifestRaw = ATH.messageParam(manifestMsg, "AssetManifest" as CFString) else {
            return stale
        }
        let manifest = Unmanaged<CFDictionary>.fromOpaque(manifestRaw).takeUnretainedValue()

        let mediaKey = Unmanaged.passUnretained("Media" as CFString).toOpaque()
        guard let mediaRaw = CFDictionaryGetValue(manifest, mediaKey) else { return stale }
        let mediaArray = Unmanaged<CFArray>.fromOpaque(mediaRaw).takeUnretainedValue()

        let count = CFArrayGetCount(mediaArray)
        for i in 0..<count {
            guard let itemRaw = CFArrayGetValueAtIndex(mediaArray, i) else { continue }
            let itemDict = Unmanaged<CFDictionary>.fromOpaque(itemRaw).takeUnretainedValue()
            let aidKey = Unmanaged.passUnretained("AssetID" as CFString).toOpaque()
            guard let aidRaw = CFDictionaryGetValue(itemDict, aidKey) else { continue }

            let typeID = CFGetTypeID(unsafeBitCast(aidRaw, to: CFTypeRef.self))
            let aidStr: String
            if typeID == CFStringGetTypeID() {
                aidStr = Unmanaged<CFString>.fromOpaque(aidRaw).takeUnretainedValue() as String
            } else if typeID == CFNumberGetTypeID() {
                let num = Unmanaged<CFNumber>.fromOpaque(aidRaw).takeUnretainedValue()
                var v: Int64 = 0
                guard CFNumberGetValue(num, .sInt64Type, &v) else { continue }
                aidStr = String(v)
            } else {
                continue
            }

            if !ourIDs.contains(aidStr) {
                stale.append(aidStr)
            }
        }
        return stale
    }

    private func sendPong() {
        log("  >> Pong")
        sendMsg("Pong", [:])
    }

    /// Build + send an ATC message with `check` semantics. AirTrafficHost's
    /// messageCreate can return nil (B1 — was force-unwrapped at every send
    /// site); a nil here means the framework itself is broken, so we log at
    /// error level and skip the send rather than crash.
    private func sendMsg(_ name: String, _ params: NSDictionary) {
        guard let c = conn,
              let msg = ATH.messageCreate(0, name as CFString, params as CFDictionary) else {
            DebugLog.error("atc.messageCreate", "\(name): AirTrafficHost returned nil — message not sent")
            return
        }
        noteActivity()
        check(name, ATH.sendMessage(c, msg))
    }

    /// `sendMsg` for MUST-ACK messages — throws on messageCreate nil and on
    /// a drainer-flagged dead connection (checkOrThrow semantics).
    private func sendMsgOrThrow(_ name: String, _ params: NSDictionary) throws {
        guard let c = conn,
              let msg = ATH.messageCreate(0, name as CFString, params as CFDictionary) else {
            throw SyncError.protocolError("AirTrafficHost couldn't build \(name) message")
        }
        try checkOrThrow(name, ATH.sendMessage(c, msg))
    }

    @discardableResult
    private func check(_ tag: String, _ rc: Int32) -> Int32 {
        // NB: rc is logged for diagnostics only — it is NOT a liveness signal.
        // A2 telemetry confirmed must-ack sends (MetadataSyncFinished, FileComplete)
        // return wild nonzero rc (0xf69a43c0, 1, …) on perfectly successful syncs.
        // Connection death is detected by the drainer (see connectionDead), not here.
        if rc != 0 { log("  !! \(tag) returned status \(rc)") }
        return rc
    }

    /// Send-result check for MUST-ACK messages (FileBegin/FileComplete/
    /// MetadataSyncFinished). Logs rc like check(), then throws if the drainer
    /// has flagged the connection dead — so a connection that dropped mid-sync
    /// aborts at the next must-ack send instead of stalling to finishSync's
    /// 120s deadline. Does NOT throw on nonzero rc (that's meaningless here).
    private func checkOrThrow(_ tag: String, _ rc: Int32) throws {
        check(tag, rc)
        if isConnectionDead() {
            DebugLog.error("atc.connectionLost", "aborting at \(tag) — drainer saw transport death")
            throw SyncError.connectionLost(tag)
        }
    }

    private func isConnectionDead() -> Bool {
        inboxLock.lock(); defer { inboxLock.unlock() }
        return connectionDead
    }

    /// Called by the drainer when its blocking read returns nil unexpectedly.
    private func markConnectionDead(_ reason: String) {
        inboxLock.lock()
        let already = connectionDead
        connectionDead = true
        inboxLock.unlock()
        if !already { DebugLog.error("atc.drainer.dead", reason) }
    }

    private func readMsg(timeout: TimeInterval = 15) -> (UnsafeMutableRawPointer?, String?) {
        // Guard against close() racing the drainer: if conn is nil here, the
        // session is gone and there's no point starting a read.
        guard let c = self.conn else { return (nil, nil) }
        var result: UnsafeMutableRawPointer?
        let done = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            result = ATH.readMessage(c)
            done.signal()
        }

        let deadline = DispatchTime.now() + timeout
        if done.wait(timeout: deadline) == .timedOut {
            return (nil, "TIMEOUT")
        }

        guard let msg = result else { return (nil, nil) }
        // Anything the device says resets the expiry clock, including the
        // Progress heartbeats it streams during a library scan.
        noteActivity()
        guard let nameCF = ATH.messageName(msg) else { return (msg, nil) }
        return (msg, nameCF as String)
    }

    /// Read messages until we see `target` or run out of attempts. The default
    /// per-message timeout is generous (30s) because the iPad's medialibraryd
    /// can be busy ingesting after a multi-GB AFC upload session, and the ATC
    /// service often needs a beat to respond on a fresh connection. 8s was
    /// short enough to fail under that load.
    private func readUntil(
        _ target: String, maxMsgs: Int = 10, timeout: TimeInterval = 30
    ) -> UnsafeMutableRawPointer? {
        for _ in 0..<maxMsgs {
            let (msg, name) = readMsg(timeout: timeout)
            guard let name, name != "TIMEOUT" else { return nil }
            if name == target { return msg }
        }
        return nil
    }
}

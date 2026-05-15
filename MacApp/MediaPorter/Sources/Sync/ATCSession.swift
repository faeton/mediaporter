// ATC (AirTrafficHost) sync protocol implementation.
// Port of Python src/mediaporter/sync/atc.py

import Foundation
import CryptoKit

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
    /// Show portrait JPEG for TV episodes. Uploaded as a separate Airlock
    /// file keyed by the album_pid (see ATCSession.albumPid), paired with
    /// an `insert_album` op carrying `artwork_cache_id` so medialibraryd
    /// associates the JPEG bytes with the album row. Drives TV.app's
    /// show-detail header big-portrait slot.
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
    case noManifest
    case cigFailed
    case rejected

    var errorDescription: String? {
        switch self {
        case .handshakeFailed(let msg): return "ATC handshake failed: \(msg)"
        case .noManifest: return "No AssetManifest received from device"
        case .cigFailed: return "CIG computation failed"
        case .rejected: return "Device rejected sync"
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
    /// Names of non-Ping ATC messages the drainer has read but the foreground
    /// flow hasn't consumed yet. finishSync polls for SyncFinished here.
    private var inbox: [String] = []
    private var ourAssetIDs: Set<String> = []

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
        let msg = ATH.messageCreate(0, "RequestingSync" as CFString, params as CFDictionary)!
        check("RequestingSync", ATH.sendMessage(conn!, msg))
        log("  >> RequestingSync (with Grappa)")

        guard let readyMsg = readUntil("ReadyForSync") else {
            throw SyncError.handshakeFailed("No ReadyForSync received")
        }
        log("  << ReadyForSync")

        // Extract device grappa
        guard let di = ATH.messageParam(readyMsg, "DeviceInfo" as CFString) else {
            throw SyncError.handshakeFailed("No DeviceInfo in ReadyForSync")
        }
        let diDict = Unmanaged<CFDictionary>.fromOpaque(di).takeUnretainedValue()
        guard let grappaRef = CFDictionaryGetValue(diDict, Unmanaged.passUnretained("Grappa" as CFString).toOpaque()) else {
            throw SyncError.handshakeFailed("No Grappa in DeviceInfo")
        }
        let grappaCF = Unmanaged<CFData>.fromOpaque(grappaRef).takeUnretainedValue()
        let grappa = Data(referencing: grappaCF as NSData)
        self.deviceGrappa = grappa
        log("  Device grappa: \(grappa.count)B")

        // Extract anchor
        var anchor = "0"
        if let anchorsRaw = ATH.messageParam(readyMsg, "DataclassAnchors" as CFString) {
            let anchorsDict = Unmanaged<CFDictionary>.fromOpaque(anchorsRaw).takeUnretainedValue()
            if let mediaRef = CFDictionaryGetValue(anchorsDict, Unmanaged.passUnretained("Media" as CFString).toOpaque()) {
                let mediaCF = Unmanaged<CFString>.fromOpaque(mediaRef).takeUnretainedValue()
                anchor = mediaCF as String
            }
        }
        log("  Anchor: \(anchor)")

        return (grappa, anchor)
    }

    func buildSyncPlist(files: [SyncFileInfo], anchor: Int) -> Data {
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

        // Per-show / per-(show, season) operations.
        //
        // medialibraryd auto-derives item_artist + album rows from track
        // metadata, but it picks one of the inserted tracks as the album's
        // representative_item_pid — i.e. the show-detail big-poster slot
        // ends up showing that track's landscape still squashed into a
        // portrait frame. Explicit `insert_artist` + `insert_album` ops
        // with deterministic pids give us a stable row we can attach a
        // portrait poster to via a dedicated Airlock upload (see
        // register/prepareSync — file written to
        // `/Airlock/Media/Artwork/<album_pid>`).
        //
        // Pids are SHA256(show / show+season) → Int64 so re-syncs bind
        // to the same row instead of creating duplicates.
        //
        // Wire keys for insert_album are the cluster at AMPDevicesAgent
        // 0x77537b (artwork_item_pid, all_compilations, store_link_url)
        // plus shared item keys (album, sort_album, season_number,
        // series_name, sort_series_name). kind=8 is kAlbumKind_TVShow —
        // emitted so medialibraryd routes the row down the TV-show code
        // path (binary references `dbAlbumInfo.albumKind == kAlbumKind_TVShow`).
        var seenArtistPids = Set<Int64>()
        var seenAlbumPids = Set<Int64>()
        var albumArtworkCache: [Int64: Int] = [:]  // album_pid -> artwork_cache_id

        for f in files where f.item.isTVShow {
            guard let show = f.item.tvShowName,
                  let season = f.item.seasonNumber else { continue }
            let artistPid = ATCSession.artistPid(show: show)
            let albumPid = ATCSession.albumPid(show: show, season: season)

            if seenArtistPids.insert(artistPid).inserted {
                var artistItem: [String: Any] = [
                    "artist": show,
                    "sort_artist": show.lowercased(),
                    "album_artist": show,
                    "sort_album_artist": show.lowercased(),
                    "series_name": show,
                    "sort_series_name": show.lowercased(),
                ]
                if let p = f.item.showPosterData, !p.isEmpty {
                    // Same artwork as album — artist row reuses album's
                    // poster via `artwork_album_pid`, but we still set
                    // a cache_id in case medialibraryd needs it.
                    artistItem["artwork_cache_id"] = Int.random(in: 1...9999)
                }
                operations.append([
                    "operation": "insert_artist",
                    "pid": artistPid,
                    "item": artistItem,
                    "artwork_album_pid": albumPid,
                ] as [String: Any])
                DebugLog.write("atc.insert_artist",
                    "pid=\(artistPid) show=\"\(show)\" artwork_album_pid=\(albumPid)")
            }

            if seenAlbumPids.insert(albumPid).inserted {
                var albumItem: [String: Any] = [
                    "album": show,
                    "sort_album": show.lowercased(),
                    "album_artist": show,
                    "sort_album_artist": show.lowercased(),
                    "series_name": show,
                    "sort_series_name": show.lowercased(),
                    "season_number": season,
                    "is_tv_show": true,
                ]
                var albumOp: [String: Any] = [
                    "operation": "insert_album",
                    "pid": albumPid,
                    "all_compilations": false,
                    "kind": 8,  // kAlbumKind_TVShow — empirical guess
                ]
                if let p = f.item.showPosterData, !p.isEmpty {
                    let cacheID = Int.random(in: 1...9999)
                    albumItem["artwork_cache_id"] = cacheID
                    albumArtworkCache[albumPid] = cacheID
                }
                albumOp["item"] = albumItem
                operations.append(albumOp)
                DebugLog.write("atc.insert_album",
                    "pid=\(albumPid) show=\"\(show)\" season=\(season) "
                    + "artwork_cache_id=\(albumArtworkCache[albumPid] ?? 0)")
            }
        }

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
                // Link the track to the explicit album row we just emitted
                // above so medialibraryd doesn't synthesize a duplicate.
                // Without this, the device creates its own album row keyed
                // by the (album, season, album_artist) tuple and our
                // insert_album's pid orphans (no tracks reference it → no
                // representative_item_pid → album.artwork_status stays 0).
                if let show = f.item.tvShowName, let season = f.item.seasonNumber {
                    itemDict["album_pid"] = ATCSession.albumPid(show: show, season: season)
                }
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

        return try! PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .binary,
            options: 0
        )
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
        check("MetadataSyncFinished", ATH.sendMetadataSyncFinished(
            conn!,
            ["Keybag": 1, "Media": 1] as NSDictionary as CFDictionary,
            ["Media": anchor] as NSDictionary as CFDictionary
        ))

        // Step 3: Read AssetManifest
        var gotManifest = false
        let ourIDs = Set(files.map { String($0.assetID) })
        var staleIDs: [String] = []
        log("  Waiting for AssetManifest...")

        for _ in 0..<30 {
            let (msg, name) = readMsg(timeout: 15)
            guard let name else { break }
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

        guard gotManifest else { throw SyncError.noManifest }

        // Step 4: FileBegin + FileComplete for each file (already uploaded)
        afc.makedirs("/Airlock/Media")
        afc.makedirs("/Airlock/Media/Artwork")

        for (idx, f) in files.enumerated() {
            let aid = String(f.assetID)

            log("  >> FileBegin (asset=\(aid))")
            check("FileBegin", ATH.sendMessage(conn!, ATH.messageCreate(0, "FileBegin" as CFString, [
                "AssetID": aid,
                "FileSize": f.item.fileSize,
                "TotalSize": f.item.fileSize,
                "Dataclass": "Media",
            ] as NSDictionary as CFDictionary)!))

            // Upload artwork if available
            if let poster = f.item.posterData {
                let artPath = "/Airlock/Media/Artwork/\(f.assetID)"
                log("  AFC: artwork -> \(artPath) (\(poster.count / 1024) KB)")
                try afc.writeFile(artPath, data: poster)
            }
            // Portrait show poster keyed by album_pid (one per show/season).
            // Paired with the insert_album op's `artwork_cache_id` so the
            // album row's poster slot resolves to this JPEG instead of
            // representative_item_pid's landscape still.
            if let showPoster = f.item.showPosterData,
               let show = f.item.tvShowName, let season = f.item.seasonNumber {
                let albumPid = ATCSession.albumPid(show: show, season: season)
                let artPath = "/Airlock/Media/Artwork/\(albumPid)"
                log("  AFC: album artwork -> \(artPath) (\(showPoster.count / 1024) KB)")
                try afc.writeFile(artPath, data: showPoster)
            }

            check("FileProgress", ATH.sendMessage(conn!, ATH.messageCreate(0, "FileProgress" as CFString, [
                "AssetID": aid,
                "AssetProgress": 1.0,
                "OverallProgress": 1.0,
                "Dataclass": "Media",
            ] as NSDictionary as CFDictionary)!))

            log("  >> FileComplete (path=\(f.devicePath))")
            check("FileComplete", ATH.sendMessage(conn!, ATH.messageCreate(0, "FileComplete" as CFString, [
                "AssetID": aid,
                "AssetPath": f.devicePath,
                "Dataclass": "Media",
            ] as NSDictionary as CFDictionary)!))

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
                check("FileError", ATH.sendMessage(conn!, ATH.messageCreate(0, "FileError" as CFString, [
                    "AssetID": sid,
                    "Dataclass": "Media",
                    "ErrorCode": 0,
                ] as NSDictionary as CFDictionary)!))
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
        check("MetadataSyncFinished", ATH.sendMetadataSyncFinished(
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
        for _ in 0..<30 {
            let (msg, name) = readMsg(timeout: 15)
            guard let name else { break }
            log("  << \(name)")
            if name == "Ping" { sendPong(); continue }
            if name == "SyncFailed" { throw SyncError.rejected }
            if name == "AssetManifest" {
                gotManifest = true
                if let m = msg {
                    dumpManifest(m)
                    staleIDs = extractStaleAssets(manifestMsg: m, ourIDs: ourIDs)
                }
                break
            }
            if name == "SyncFinished" { break }
        }
        guard gotManifest else { throw SyncError.noManifest }

        // Clear stale pending assets up front. Doing this before any of our
        // own FileBegins is safer than the old end-of-batch sweep (no race
        // with medialibraryd accepting our IDs first).
        if !staleIDs.isEmpty {
            progress?("Clearing \(staleIDs.count) stale pending asset(s) from prior syncs…")
            log("  Clearing \(staleIDs.count) stale pending asset(s)...")
            DebugLog.notice("atc.FileError.stale", "count=\(staleIDs.count) ids=\(staleIDs.joined(separator: ","))")
            for sid in staleIDs {
                check("FileError", ATH.sendMessage(conn!, ATH.messageCreate(0, "FileError" as CFString, [
                    "AssetID": sid,
                    "Dataclass": "Media",
                    "ErrorCode": 0,
                ] as NSDictionary as CFDictionary)!))
            }
        }

        // Make sure Airlock dirs exist before per-file artwork uploads.
        afc.makedirs("/Airlock/Media")
        afc.makedirs("/Airlock/Media/Artwork")

        self.streamingAFC = afc
        self.ourAssetIDs = ourIDs
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
        DebugLog.write("atc.FileBegin",
            "asset=\(aid) path=\(f.devicePath) size=\(f.item.fileSize)")
        log("  >> FileBegin (asset=\(aid))")
        check("FileBegin", ATH.sendMessage(conn!, ATH.messageCreate(0, "FileBegin" as CFString, [
            "AssetID": aid,
            "FileSize": f.item.fileSize,
            "TotalSize": f.item.fileSize,
            "Dataclass": "Media",
        ] as NSDictionary as CFDictionary)!))
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
        // Portrait album artwork keyed by album_pid. Same pid is computed
        // by buildSyncPlist when emitting insert_album, so the cache_id
        // there pairs with this Airlock JPEG.
        if let showPoster = f.item.showPosterData,
           let show = f.item.tvShowName, let season = f.item.seasonNumber {
            let albumPid = ATCSession.albumPid(show: show, season: season)
            let artPath = "/Airlock/Media/Artwork/\(albumPid)"
            log("  AFC: album artwork -> \(artPath) (\(showPoster.count / 1024) KB)")
            try afc.writeFile(artPath, data: showPoster)
        }

        check("FileProgress", ATH.sendMessage(conn!, ATH.messageCreate(0, "FileProgress" as CFString, [
            "AssetID": aid,
            "AssetProgress": 1.0,
            "OverallProgress": 1.0,
            "Dataclass": "Media",
        ] as NSDictionary as CFDictionary)!))

        log("  >> FileComplete (path=\(f.devicePath))")
        DebugLog.write("atc.FileComplete", "asset=\(aid) path=\(f.devicePath)")
        check("FileComplete", ATH.sendMessage(conn!, ATH.messageCreate(0, "FileComplete" as CFString, [
            "AssetID": aid,
            "AssetPath": f.devicePath,
            "Dataclass": "Media",
        ] as NSDictionary as CFDictionary)!))
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
        check("FileProgress", ATH.sendMessage(conn!, ATH.messageCreate(0, "FileProgress" as CFString, [
            "AssetID": aid,
            "AssetProgress": p,
            "OverallProgress": p,
            "Dataclass": "Media",
        ] as NSDictionary as CFDictionary)!))
        DebugLog.write("atc.FileProgress", "asset=\(assetID) frac=\(String(format: "%.2f", p))")
    }

    /// Send FileError(0) for an asset we will NOT be FileCompleting (transcode
    /// failure, user cancel mid-batch, etc.). Without this, medialibraryd
    /// blocks SyncFinished waiting for the missing asset (CLAUDE.md #8).
    func abandonAsset(assetID: Int) {
        log("  >> FileError (abandon asset=\(assetID))")
        DebugLog.notice("atc.abandonAsset", "id=\(assetID)")
        check("FileError", ATH.sendMessage(conn!, ATH.messageCreate(0, "FileError" as CFString, [
            "AssetID": String(assetID),
            "Dataclass": "Media",
            "ErrorCode": 0,
        ] as NSDictionary as CFDictionary)!))
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
    func finishSync() {
        log("  Waiting for SyncFinished...")
        DebugLog.write("atc.finishSync.wait", "deadline=120s")
        let start = Date()
        let hardDeadline = start.addingTimeInterval(120)

        // Drop pre-existing inbox entries — they're from the upload phase,
        // not commit signals for the just-finished file.
        let stale = drainInbox()
        if !stale.isEmpty {
            DebugLog.notice("atc.finishSync.discard_stale", "names=\(stale.joined(separator: ","))")
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
                    return
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
                return
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        log("  SyncFinished not received (120 s timeout)")
        DebugLog.error("atc.finishSync.timeout", "elapsed=120s")
        stopDrainer()
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
                    // nil = conn invalidated (close called) or transport
                    // error. Either way, drainer is done.
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

    /// Deterministic 18-digit positive Int derived from SHA256 of `key`.
    /// Matches the asset-id width used for track pids so medialibraryd
    /// treats it as a normal entity pid. Same key → same pid → re-syncs
    /// bind back to the same album/artist row instead of duplicating.
    private static func deterministicPid(_ key: String) -> Int64 {
        let hash = SHA256.hash(data: Data(key.utf8))
        var v: UInt64 = 0
        for byte in hash.prefix(8) {
            v = (v << 8) | UInt64(byte)
        }
        // Mask off top bit so the result fits in Int64 positive range,
        // then clamp into the 17-digit window we use for track ids.
        let positive = v & 0x7FFF_FFFF_FFFF_FFFF
        return Int64(positive % 900_000_000_000_000_000 + 100_000_000_000_000_000)
    }

    static func albumPid(show: String, season: Int) -> Int64 {
        deterministicPid("album:\(show.lowercased())|s\(season)")
    }

    static func artistPid(show: String) -> Int64 {
        deterministicPid("artist:\(show.lowercased())")
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
        check("Pong", ATH.sendMessage(conn!, ATH.messageCreate(0, "Pong" as CFString, [:] as NSDictionary as CFDictionary)!))
    }

    @discardableResult
    private func check(_ tag: String, _ rc: Int32) -> Int32 {
        if rc != 0 { log("  !! \(tag) returned status \(rc)") }
        return rc
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

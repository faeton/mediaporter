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

        // RequestingSync with Grappa
        let grappaData = loadGrappaBlob()
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

            if f.item.isTVShow {
                itemDict["is_tv_show"] = true
                if let show = f.item.tvShowName { itemDict["tv_show_name"] = show }
                if let v = f.item.sortTVShowName { itemDict["sort_tv_show_name"] = v }
                if let s = f.item.seasonNumber { itemDict["season_number"] = s }
                if let e = f.item.episodeNumber { itemDict["episode_number"] = e }
                if let v = f.item.episodeSortID { itemDict["episode_sort_id"] = v }
                if let v = f.item.artist { itemDict["artist"] = v }
                if let v = f.item.sortArtist { itemDict["sort_artist"] = v }
                if let v = f.item.album { itemDict["album"] = v }
                if let v = f.item.sortAlbum { itemDict["sort_album"] = v }
                if let v = f.item.albumArtist { itemDict["album_artist"] = v }
                if let v = f.item.sortAlbumArtist { itemDict["sort_album_artist"] = v }
            } else {
                itemDict["is_movie"] = true
            }

            operations.append([
                "operation": "insert_track",
                "pid": f.assetID,
                "item": itemDict,
                "location": ["kind": "MPEG-4 video file"],
                "video_info": [
                    "has_alternate_audio": false,
                    "is_anamorphic": false,
                    "has_subtitles": false,
                    "is_hd": f.item.isHD,
                    "is_compressed": false,
                    "has_closed_captions": false,
                    "is_self_contained": false,
                    "characteristics_valid": false,
                ] as [String: Any],
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
            // Second Airlock artwork — show portrait for the album row.
            if let showPoster = f.item.showPosterData {
                let artPath = "/Airlock/Media/Artwork/\(f.assetID)_show"
                log("  AFC: show artwork -> \(artPath) (\(showPoster.count / 1024) KB)")
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
        anchor: String
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
        check("MetadataSyncFinished", ATH.sendMetadataSyncFinished(
            conn!,
            ["Keybag": 1, "Media": 1] as NSDictionary as CFDictionary,
            ["Media": anchor] as NSDictionary as CFDictionary
        ))

        // Step 3: Wait AssetManifest, capture stale IDs.
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
                if let m = msg {
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
            log("  Clearing \(staleIDs.count) stale pending asset(s)...")
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
    func registerFile(_ f: SyncFileInfo) throws {
        guard let afc = streamingAFC else {
            throw SyncError.handshakeFailed("registerFile called before prepareSync")
        }
        let aid = String(f.assetID)
        log("  >> FileBegin (asset=\(aid))")
        check("FileBegin", ATH.sendMessage(conn!, ATH.messageCreate(0, "FileBegin" as CFString, [
            "AssetID": aid,
            "FileSize": f.item.fileSize,
            "TotalSize": f.item.fileSize,
            "Dataclass": "Media",
        ] as NSDictionary as CFDictionary)!))

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
    }

    /// Send FileError(0) for an asset we will NOT be FileCompleting (transcode
    /// failure, user cancel mid-batch, etc.). Without this, medialibraryd
    /// blocks SyncFinished waiting for the missing asset (CLAUDE.md #8).
    func abandonAsset(assetID: Int) {
        log("  >> FileError (abandon asset=\(assetID))")
        check("FileError", ATH.sendMessage(conn!, ATH.messageCreate(0, "FileError" as CFString, [
            "AssetID": String(assetID),
            "Dataclass": "Media",
            "ErrorCode": 0,
        ] as NSDictionary as CFDictionary)!))
    }

    /// Phase 3. Waits for SyncFinished by polling the drainer's inbox (no
    /// direct readMsg — that would race the drainer for the single ATC
    /// connection and silently swallow SyncFinished). SyncAllowed is also
    /// terminal: the device only emits it once it has flushed our anchor
    /// and is ready to accept a fresh sync, which is what we need before
    /// returning. Subsequent Progress / Ping noise during medialibraryd's
    /// background indexing is irrelevant to us.
    func finishSync() {
        log("  Waiting for SyncFinished/SyncAllowed...")
        let hardDeadline = Date().addingTimeInterval(120)
        while Date() < hardDeadline {
            for name in drainInbox() {
                log("  << \(name)")
                if name == "SyncFinished" || name == "SyncAllowed" {
                    log("  *** SYNC COMPLETE (\(name)) ***")
                    stopDrainer()
                    return
                }
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        log("  SyncFinished not received (120 s timeout)")
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
                if self.verbose { NSLog("ATC drainer: << %@", name) }
                if name == "Ping" {
                    self.sendPong()
                    continue
                }
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

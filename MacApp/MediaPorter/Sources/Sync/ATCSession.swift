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
    var seasonNumber: Int?
    var episodeNumber: Int?
    var isHD: Bool = false
    var channels: Int = 2
    var posterData: Data?
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
        ATH.sendHostInfo(conn!, hostInfo as CFDictionary)
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
        ATH.sendMessage(conn!, msg)
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

            if f.item.isTVShow {
                itemDict["is_tv_show"] = true
                if let show = f.item.tvShowName { itemDict["tv_show_name"] = show }
                if let s = f.item.seasonNumber { itemDict["season_number"] = s }
                if let e = f.item.episodeNumber { itemDict["episode_number"] = e }
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
        ATH.sendPowerAssertion(conn!, kCFBooleanTrue)
        log("  >> MetadataSyncFinished (anchor=\"\(anchor)\")")
        ATH.sendMetadataSyncFinished(
            conn!,
            ["Keybag": 1, "Media": 1] as NSDictionary as CFDictionary,
            ["Media": anchor] as NSDictionary as CFDictionary
        )

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
                break
            }
            if name == "SyncFinished" { break }
        }

        guard gotManifest else { throw SyncError.noManifest }

        // Step 4: FileBegin + FileComplete for each file (already uploaded)
        afc.makedirs("/Airlock/Media")
        afc.makedirs("/Airlock/Media/Artwork")

        for f in files {
            let aid = String(f.assetID)

            log("  >> FileBegin (asset=\(aid))")
            ATH.sendMessage(conn!, ATH.messageCreate(0, "FileBegin" as CFString, [
                "AssetID": aid,
                "FileSize": f.item.fileSize,
                "TotalSize": f.item.fileSize,
                "Dataclass": "Media",
            ] as NSDictionary as CFDictionary)!)

            // Upload artwork if available
            if let poster = f.item.posterData {
                let artPath = "/Airlock/Media/Artwork/\(f.assetID)"
                log("  AFC: artwork -> \(artPath) (\(poster.count / 1024) KB)")
                try afc.writeFile(artPath, data: poster)
            }

            ATH.sendMessage(conn!, ATH.messageCreate(0, "FileProgress" as CFString, [
                "AssetID": aid,
                "AssetProgress": 1.0,
                "OverallProgress": 1.0,
                "Dataclass": "Media",
            ] as NSDictionary as CFDictionary)!)

            log("  >> FileComplete (path=\(f.devicePath))")
            ATH.sendMessage(conn!, ATH.messageCreate(0, "FileComplete" as CFString, [
                "AssetID": aid,
                "AssetPath": f.devicePath,
                "Dataclass": "Media",
            ] as NSDictionary as CFDictionary)!)
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

    func close() {
        if let c = conn {
            ATH.invalidate(c)
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

    private func sendPong() {
        log("  >> Pong")
        ATH.sendMessage(conn!, ATH.messageCreate(0, "Pong" as CFString, [:] as NSDictionary as CFDictionary)!)
    }

    private func readMsg(timeout: TimeInterval = 15) -> (UnsafeMutableRawPointer?, String?) {
        var result: UnsafeMutableRawPointer?
        let done = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            result = ATH.readMessage(self.conn!)
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

    private func readUntil(_ target: String, maxMsgs: Int = 10) -> UnsafeMutableRawPointer? {
        for _ in 0..<maxMsgs {
            let (msg, name) = readMsg(timeout: 8)
            guard let name, name != "TIMEOUT" else { return nil }
            if name == target { return msg }
        }
        return nil
    }
}

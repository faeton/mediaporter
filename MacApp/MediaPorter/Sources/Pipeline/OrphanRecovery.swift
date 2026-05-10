// Recover from a failed registration when in-memory state is gone.
//
// After the pipeline transcodes a file we tag it with full metadata
// (title, show, season, episode, year, network…) via Tagger before upload.
// The tagged .m4v survives in the system tempdir until the next app quit.
// Combined with the bytes already on the device, that's enough to register
// without re-uploading 19 GB or even keeping the original FileJobs around.
//
// Flow:
//   1. Walk the tempdir for *.m4v files.
//   2. ffprobe each for embedded TMDb-style tags + duration + HD flag.
//   3. Scan /iTunes_Control/Music/F00..F49 on the device for orphan bytes.
//   4. Match each local file to a device file by EXACT byte size.
//   5. Build SyncItem from the m4v's tags, wrap in PreparedSyncFile with
//      the matched device path, run the standard register call.

import AVFoundation
import Foundation

struct OrphanCandidate {
    let localURL: URL
    let size: Int64
    let title: String
    let showName: String?
    let season: Int?
    let episode: Int?
    let durationMs: Int
    let isHD: Bool
    let channels: Int

    var sortName: String { title.lowercased() }
    var isTVShow: Bool { showName != nil && season != nil && episode != nil }
}

public struct OrphanRecoveryReport: Sendable {
    public let localFound: Int
    public let deviceFound: Int
    public let registered: Int
    public let deviceUnmatched: Int
    public let candidatesUnmatched: Int
    public let registeredTitles: [String]   // for CLI logging
}

public enum OrphanRecoveryError: LocalizedError {
    case scanFailed(String)
    case registerFailed(String)
    public var errorDescription: String? {
        switch self {
        case .scanFailed(let m): return "Device scan failed: \(m)"
        case .registerFailed(let m): return "Register failed: \(m)"
        }
    }
}

/// Public end-to-end orphan recovery. Walks the system tempdir for tagged
/// .m4v files, scans the device's `/iTunes_Control/Music/F*/` for orphan
/// bytes, matches by exact byte size, and runs the standard register call.
/// No re-upload — purely reuses bytes already on the device.
public func recoverOrphansEndToEnd(device: DeviceInfo) throws -> OrphanRecoveryReport {
    let candidates = OrphanRecovery.scanLocalCandidates()
    let deviceFiles: [DeviceMediaFile]
    do {
        deviceFiles = try DeviceMaintenance.scanStagingMedia(device: device)
    } catch {
        throw OrphanRecoveryError.scanFailed(error.localizedDescription)
    }
    let (pairs, devUnmatched, candUnmatched) =
        OrphanRecovery.match(candidates: candidates, deviceFiles: deviceFiles)
    if pairs.isEmpty {
        return OrphanRecoveryReport(
            localFound: candidates.count, deviceFound: deviceFiles.count,
            registered: 0, deviceUnmatched: devUnmatched.count,
            candidatesUnmatched: candUnmatched.count, registeredTitles: []
        )
    }
    let prepared = pairs.map { (cand, dev) -> PreparedSyncFile in
        PreparedSyncFile(
            item: OrphanRecovery.makeSyncItem(from: cand),
            assetID: ATCSession.generateAssetID(),
            devicePath: dev.path,
            slot: dev.slot
        )
    }
    do {
        try registerUploadedFiles(device: device, files: prepared, verbose: false)
    } catch {
        throw OrphanRecoveryError.registerFailed(error.localizedDescription)
    }
    // Clean up the local /tmp copies we just registered.
    for (cand, _) in pairs {
        try? FileManager.default.removeItem(at: cand.localURL)
    }
    let titles = pairs.map { (cand, _) -> String in
        if cand.isTVShow {
            return "\(cand.showName ?? "?") S\(cand.season ?? 0)E\(cand.episode ?? 0) — \(cand.title)"
        }
        return cand.title
    }
    return OrphanRecoveryReport(
        localFound: candidates.count, deviceFound: deviceFiles.count,
        registered: pairs.count, deviceUnmatched: devUnmatched.count,
        candidatesUnmatched: candUnmatched.count, registeredTitles: titles
    )
}

enum OrphanRecovery {
    /// Walk the tempdir for .m4v files left by previous pipeline runs.
    static func scanLocalCandidates() -> [OrphanCandidate] {
        let tmp = FileManager.default.temporaryDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return [] }

        return entries.compactMap { url in
            guard url.pathExtension.lowercased() == "m4v" else { return nil }
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attrs?[.size] as? Int64, size > 0 else { return nil }
            return probe(url: url, size: size)
        }
    }

    /// Read TV/movie metadata from a tagged .m4v.
    ///
    /// We previously parsed ffprobe's JSON output, but ffprobe's MP4-atom →
    /// text-key translation is leaky — `episode_sort` / `season_number` came
    /// back missing from `format.tags` even though they were physically
    /// present in the file (verified via raw `ffprobe -show_format`). Result:
    /// 25 episodes registered with episode_number=0, all sorted by upload
    /// order instead of episode order in the TV app.
    ///
    /// AVFoundation reads MP4 atoms directly by their 4-char identifier
    /// (`tvsh`, `tvsn`, `tves`, `tven`), which is what AtomicParsley/iTunes
    /// actually stored. No translation layer to fail.
    private static func probe(url: URL, size: Int64) -> OrphanCandidate? {
        let asset = AVURLAsset(url: url)

        var title: String?
        var show: String?
        var season: Int?
        var episode: Int?
        var episodeID: String?
        var height = 0
        var channels = 2

        // Walk all metadata items. Match by both `key` (4-char OSType code,
        // e.g. "tvsh") and `commonKey`/`identifier` for portability.
        let items = asset.metadata + asset.commonMetadata
        for item in items {
            // OSType-encoded key, e.g. "tves" for TV episode number.
            let key4: String? = {
                if let n = item.key as? NSNumber {
                    let raw = UInt32(truncatingIfNeeded: n.int64Value)
                    var bytes = [UInt8](repeating: 0, count: 4)
                    bytes[0] = UInt8((raw >> 24) & 0xff)
                    bytes[1] = UInt8((raw >> 16) & 0xff)
                    bytes[2] = UInt8((raw >>  8) & 0xff)
                    bytes[3] = UInt8(raw & 0xff)
                    return String(bytes: bytes, encoding: .utf8)
                }
                return item.key as? String
            }()
            let ident = item.identifier?.rawValue ?? ""

            switch (key4 ?? "", ident) {
            case ("tvsh", _), (_, "itsk/tvsh"), (_, "com.apple.iTunes.tvsh"):
                show = item.stringValue ?? show
            case ("tvsn", _), (_, "itsk/tvsn"):
                season = (item.numberValue?.intValue) ?? Int(item.stringValue ?? "") ?? season
            case ("tves", _), (_, "itsk/tves"):
                episode = (item.numberValue?.intValue) ?? Int(item.stringValue ?? "") ?? episode
            case ("tven", _), (_, "itsk/tven"):
                episodeID = item.stringValue ?? episodeID
            case ("\u{00A9}nam", _), (_, "itsk/©nam"), (_, "common/title"):
                title = item.stringValue ?? title
            default:
                // commonKey "title" catches the iTunes "©nam" atom too.
                if item.commonKey?.rawValue == "title" { title = item.stringValue ?? title }
            }
        }

        // Fallback: derive episode # from "S01E11"-style episode_id.
        if episode == nil, let id = episodeID {
            episode = parseEpisodeID(id)
        }

        // Duration via AVAsset (CMTime) — more reliable than parsing ffprobe.
        let durSec = CMTimeGetSeconds(asset.duration)
        let durationMs = durSec.isFinite ? Int(durSec * 1000) : 0

        // Stream characteristics.
        for track in asset.tracks {
            if track.mediaType == .video {
                let dim = track.naturalSize.applying(track.preferredTransform)
                height = max(height, Int(abs(dim.height)))
            } else if track.mediaType == .audio {
                if let descs = track.formatDescriptions as? [CMFormatDescription],
                   let f = descs.first,
                   let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(f)?.pointee {
                    channels = max(channels, Int(asbd.mChannelsPerFrame))
                }
            }
        }

        // Title fallback — better than dropping the file entirely.
        let resolvedTitle = title ?? url.deletingPathExtension().lastPathComponent

        return OrphanCandidate(
            localURL: url,
            size: size,
            title: resolvedTitle,
            showName: show,
            season: season,
            episode: episode,
            durationMs: durationMs,
            isHD: height >= 720,
            channels: channels
        )
    }

    private static func parseEpisodeID(_ s: String) -> Int? {
        // "S01E11" → 11.
        let pattern = "[Ee](\\d{1,3})"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(s.startIndex..., in: s)
        guard let m = regex.firstMatch(in: s, range: range),
              let r = Range(m.range(at: 1), in: s)
        else { return nil }
        return Int(s[r])
    }

    /// Pair each local candidate to a device file with the exact same byte
    /// size. Returns matched pairs + the leftover device files (true orphans
    /// with no local match) + the leftover candidates (no device match).
    static func match(
        candidates: [OrphanCandidate], deviceFiles: [DeviceMediaFile]
    ) -> (pairs: [(OrphanCandidate, DeviceMediaFile)],
          deviceUnmatched: [DeviceMediaFile],
          candidatesUnmatched: [OrphanCandidate]) {
        var bySize: [Int64: [DeviceMediaFile]] = [:]
        for f in deviceFiles { bySize[f.size, default: []].append(f) }

        var pairs: [(OrphanCandidate, DeviceMediaFile)] = []
        var unmatched: [OrphanCandidate] = []
        for c in candidates {
            guard var group = bySize[c.size], !group.isEmpty else {
                unmatched.append(c); continue
            }
            let pick = group.removeFirst()
            bySize[c.size] = group
            pairs.append((c, pick))
        }
        let leftoverDevice = bySize.values.flatMap { $0 }
        return (pairs, leftoverDevice, unmatched)
    }

    /// Build a SyncItem the register call can consume from the tags we
    /// extracted. Movies use `is_movie`; TV uses `is_tv_show` + show fields.
    static func makeSyncItem(from c: OrphanCandidate) -> SyncItem {
        var item = SyncItem(
            fileURL: c.localURL,
            title: c.title,
            sortName: c.sortName,
            durationMs: c.durationMs,
            fileSize: Int(c.size),
            isMovie: !c.isTVShow,
            isTVShow: c.isTVShow,
            tvShowName: c.showName,
            seasonNumber: c.season,
            episodeNumber: c.episode,
            isHD: c.isHD,
            channels: c.channels,
            posterData: nil
        )
        // Not strictly necessary, but keeps the register code happy when it
        // checks `f.item.posterData != nil` to decide whether to set
        // artwork_cache_id.
        _ = item
        return item
    }
}

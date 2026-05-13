// Per-file state machine — tracks a single file through the pipeline.

import Foundation
import Observation

/// Which subtitle (if any) should be burned into the video during transcode.
/// Burn-in is only offered when the pipeline is already re-encoding the video —
/// the filter is free then. Mutually exclusive: at most one per job.
public enum BurnInSubtitle: Equatable, Hashable, Sendable {
    /// Index into `mediaInfo.subtitleStreams`.
    case embedded(Int)
    /// Index into `mediaInfo.externalSubtitles`.
    case external(Int)
}

public enum JobStatus: String {
    case pending
    case analyzing
    case analyzed
    /// External audio/sub tracks are being muxed into an intermediate MKV
    /// before the main transcode pass (#11e). Short pre-stage; only seen
    /// when the job has non-empty `externalTracksToMux`.
    case muxing
    case transcoding
    case tagging
    case ready
    case syncing
    /// Bytes are on the device but not yet registered with ATC. The pipeline
    /// runs registration as one short batch call after every file finishes
    /// uploading, so files sit here for seconds-to-minutes between upload
    /// complete and final visibility in the TV app. Distinguishing this from
    /// `.syncing` keeps the timeline counters honest — "1 active" instead of
    /// "17 active" while uploads are sequential.
    case uploaded
    case synced
    case failed
}

@Observable
public class FileJob: Identifiable {
    public let id = UUID()
    public let inputURL: URL
    public let fileName: String
    public let fileSize: Int

    public var status: JobStatus = .pending
    public var error: String?
    public var progress: Double = 0  // 0.0–1.0

    // Analysis results
    public var mediaInfo: MediaInfo?
    public var decision: TranscodeDecision?
    public var metadata: ResolvedMetadata?

    /// TV-show cluster key (`TVShowCluster.key`) when the file is detected as
    /// an episode. Files that share a clusterID share one TMDb show lookup
    /// and one user-edited show identity. nil for movies.
    public var clusterID: String?

    /// Set by analyzeOne when an entry on the device's MediaLibrary matches
    /// this job's (title, duration). Drives the "on device" chip and the
    /// pipeline's skip-by-default behaviour (#10b). nil = not yet checked
    /// (no device snapshot was available during analyze).
    public var duplicateOnDevice: Bool?

    /// User opt-in override for `duplicateOnDevice`. When true, the
    /// pipeline syncs the file even though a match exists on the device
    /// (creates a duplicate row — same caveat as before #10b).
    public var syncDespiteDuplicate: Bool = false

    /// External audio / sub tracks that should be muxed into this episode
    /// before transcode (#11e). Resolved by `ClusterSelection.apply` against
    /// the cluster's `ReleaseExtras` (#11c) and the current cluster
    /// selection. Empty for files without extras or with no extras selected.
    public var externalTracksToMux: [ExternalTrackRef] = []

    // User selections (populated after analysis)
    public var selectedAudio: [Int] = []          // indices into audioStreams
    public var selectedSubtitles: [Int] = []      // indices into subtitleStreams
    public var selectedExternalSubs: [Int] = []   // indices into externalSubtitles
    public var maxResolution: ResolutionLimit = .original
    /// At most one sub can be burned into the video. Only honored when
    /// `videoBeingReencoded` is already true, otherwise the UI hides the toggle.
    public var burnInSubtitle: BurnInSubtitle?

    // Output
    public var outputURL: URL?

    public init(url: URL) {
        self.inputURL = url
        self.fileName = url.lastPathComponent
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        self.fileSize = (attrs?[.size] as? Int) ?? 0
    }

    public var fileSizeMB: Int { fileSize / 1_048_576 }

    /// True if any *selected* stream requires re-encoding (or the video is being
    /// downscaled). Selection matters: deselecting an incompatible track flips
    /// this off, because that track won't be mapped into the output.
    public var needsReencode: Bool {
        guard let d = decision, let info = mediaInfo else { return false }
        if maxResolution.wouldDownscale(from: info.videoStreams.first?.height) { return true }
        for v in info.videoStreams where d.streamActions[v.index] == "transcode" { return true }
        for idx in selectedAudio where idx < info.audioStreams.count {
            let s = info.audioStreams[idx]
            if d.streamActions[s.index] == "transcode" { return true }
        }
        return false
    }

    /// True if we must run ffmpeg (as a stream-copy remux) even when nothing is
    /// being re-encoded: container change, dropped tracks, subtitle conversion,
    /// external subs to embed.
    public var needsRemuxOnly: Bool {
        guard let d = decision, let info = mediaInfo else { return false }
        if d.needsRemux { return true }
        if selectedAudio.count != info.audioStreams.count { return true }
        if !selectedExternalSubs.isEmpty { return true }
        for s in info.subtitleStreams where d.streamActions[s.index] == "convert_to_mov_text" {
            // Counts only if the user kept the sub selected for the output.
            if let srcIdx = info.subtitleStreams.firstIndex(where: { $0.index == s.index }),
               selectedSubtitles.contains(srcIdx) {
                return true
            }
        }
        return false
    }

    public var needsWork: Bool { needsReencode || needsRemuxOnly }

    public var selectedAudioNeedingTranscode: [Int] {
        guard let d = decision, let info = mediaInfo else { return [] }
        return selectedAudio.filter { idx in
            guard idx < info.audioStreams.count else { return false }
            return d.streamActions[info.audioStreams[idx].index] == "transcode"
        }
    }

    /// Some tracks copy, some transcode — dropping the transcode ones avoids
    /// the audio re-encode and still leaves usable audio.
    public var canDropAudioToAvoidReencode: Bool {
        let transcode = selectedAudioNeedingTranscode.count
        let valid = selectedAudio.filter { $0 < (mediaInfo?.audioStreams.count ?? 0) }.count
        return transcode >= 1 && transcode < valid
    }

    /// True if the video stream itself is being re-encoded — i.e. the ffmpeg
    /// command already has `-c:v hevc_videotoolbox/libx265` with a video filter
    /// chain. Burn-in is "free" only in this case.
    public var videoBeingReencoded: Bool {
        guard let d = decision, let info = mediaInfo else { return false }
        if maxResolution.wouldDownscale(from: info.videoStreams.first?.height) { return true }
        for v in info.videoStreams where d.streamActions[v.index] == "transcode" { return true }
        return false
    }

    /// A single label describing what the pipeline will actually do with the
    /// current selection: "transcode" (re-encodes), "remux" (stream-copies),
    /// or "copy" (no ffmpeg pass — upload source as-is).
    public var effectiveAction: String {
        if needsReencode { return "transcode" }
        if needsRemuxOnly { return "remux" }
        return "copy"
    }
}

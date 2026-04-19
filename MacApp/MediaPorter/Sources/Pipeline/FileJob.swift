// Per-file state machine — tracks a single file through the pipeline.

import Foundation
import Observation

public enum JobStatus: String {
    case pending
    case analyzing
    case analyzed
    case transcoding
    case tagging
    case ready
    case syncing
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

    // User selections (populated after analysis)
    public var selectedAudio: [Int] = []          // indices into audioStreams
    public var selectedSubtitles: [Int] = []      // indices into subtitleStreams
    public var selectedExternalSubs: [Int] = []   // indices into externalSubtitles
    public var maxResolution: ResolutionLimit = .original

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

    /// A single label describing what the pipeline will actually do with the
    /// current selection: "transcode" (re-encodes), "remux" (stream-copies),
    /// or "copy" (no ffmpeg pass — upload source as-is).
    public var effectiveAction: String {
        if needsReencode { return "transcode" }
        if needsRemuxOnly { return "remux" }
        return "copy"
    }
}

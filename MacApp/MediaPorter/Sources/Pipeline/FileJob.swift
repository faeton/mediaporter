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

    public var needsWork: Bool {
        guard let d = decision else { return false }
        let downscale = maxResolution.wouldDownscale(from: mediaInfo?.videoStreams.first?.height)
        return d.needsTranscode || d.needsRemux || downscale
    }

}

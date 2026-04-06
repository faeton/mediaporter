// Per-file state machine — tracks a single file through the pipeline.

import Foundation
import SwiftUI

enum JobStatus: String {
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
class FileJob: Identifiable {
    let id = UUID()
    let inputURL: URL
    let fileName: String
    let fileSize: Int

    var status: JobStatus = .pending
    var error: String?
    var progress: Double = 0  // 0.0–1.0

    // Analysis results
    var mediaInfo: MediaInfo?
    var decision: TranscodeDecision?
    var metadata: ResolvedMetadata?

    // User selections (populated after analysis)
    var selectedAudio: [Int] = []          // indices into audioStreams
    var selectedSubtitles: [Int] = []      // indices into subtitleStreams
    var selectedExternalSubs: [Int] = []   // indices into externalSubtitles
    var maxResolution: ResolutionLimit = .original

    // Output
    var outputURL: URL?

    init(url: URL) {
        self.inputURL = url
        self.fileName = url.lastPathComponent
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        self.fileSize = (attrs?[.size] as? Int) ?? 0
    }

    var fileSizeMB: Int { fileSize / 1_048_576 }

    var needsWork: Bool {
        guard let d = decision else { return false }
        let downscale = maxResolution.wouldDownscale(from: mediaInfo?.videoStreams.first?.height)
        return d.needsTranscode || d.needsRemux || downscale
    }

    var statusIcon: String {
        switch status {
        case .pending: return "circle.dashed"
        case .analyzing: return "magnifyingglass"
        case .analyzed: return "checkmark.circle"
        case .transcoding: return "arrow.triangle.2.circlepath"
        case .tagging: return "tag"
        case .ready: return "checkmark.circle.fill"
        case .syncing: return "arrow.up.circle"
        case .synced: return "checkmark.circle.fill"
        case .failed: return "xmark.circle"
        }
    }

    var statusColor: Color {
        switch status {
        case .pending: return .gray
        case .analyzing: return .blue
        case .analyzed: return .blue
        case .transcoding: return .orange
        case .tagging: return .purple
        case .ready: return .green
        case .syncing: return .orange
        case .synced: return .green
        case .failed: return .red
        }
    }
}

// File detail panel — shows analysis results and track selection.

import SwiftUI

struct FileDetailView: View {
    @Bindable var job: FileJob

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Header
                HStack {
                    Image(systemName: "film")
                        .font(.title2)
                    Text(job.fileName)
                        .font(.title2.bold())
                        .lineLimit(1)
                    Spacer()
                    Text("\(job.fileSizeMB) MB")
                        .foregroundColor(.secondary)
                }

                Divider()

                if job.status == .pending {
                    ContentUnavailableView(
                        "Waiting",
                        systemImage: "clock",
                        description: Text("Queued for analysis")
                    )
                } else if job.status == .analyzing {
                    ProgressView("Analyzing...")
                        .frame(maxWidth: .infinity)
                        .padding()
                } else if job.mediaInfo != nil {
                    // Video
                    VideoInfoSection(job: job)

                    // Audio
                    AudioTracksSection(job: job)

                    // Subtitles
                    SubtitleTracksSection(job: job)

                    // Metadata
                    MetadataSection(job: job)

                    // Duration
                    if let info = job.mediaInfo {
                        GroupBox("File Info") {
                            VStack(alignment: .leading, spacing: 4) {
                                LabeledContent("Duration", value: formatDuration(info.duration))
                                LabeledContent("Format", value: info.formatName)
                                if let br = info.bitRate {
                                    LabeledContent("Bitrate", value: "\(br / 1000) kbps")
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                // Error
                if let error = job.error {
                    GroupBox {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundColor(.red)
                    }
                }

                // Progress
                if job.status == .transcoding {
                    ProgressView(value: job.progress) {
                        Text("Transcoding \(Int(job.progress * 100))%")
                    }
                }
            }
            .padding()
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

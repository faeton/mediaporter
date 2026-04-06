// Single file row in the sidebar list.

import SwiftUI

struct FileRowView: View {
    let job: FileJob

    var body: some View {
        HStack(spacing: 8) {
            StatusIcon(job: job)

            VStack(alignment: .leading, spacing: 2) {
                Text(job.fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.system(.body, design: .default))
                    .foregroundColor(job.status == .synced ? .secondary : .primary)

                HStack(spacing: 6) {
                    Text("\(job.fileSizeMB) MB")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    if job.status == .transcoding || job.status == .syncing {
                        Text("\(Int(job.progress * 100))%")
                            .font(.caption2)
                            .foregroundColor(job.status == .transcoding ? .orange : .blue)
                    } else if job.status == .failed {
                        Text(job.error ?? "Error")
                            .font(.caption2)
                            .foregroundColor(.red)
                            .lineLimit(1)
                    } else if job.status == .synced {
                        Text("synced")
                            .font(.caption2)
                            .foregroundColor(.green)
                    } else if job.status != .pending {
                        Text(job.status.rawValue)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            // Inline progress bar for active jobs
            if (job.status == .transcoding || job.status == .syncing) && job.progress > 0 {
                ProgressView(value: job.progress)
                    .frame(width: 50)
            }
        }
        .padding(.vertical, 2)
    }
}

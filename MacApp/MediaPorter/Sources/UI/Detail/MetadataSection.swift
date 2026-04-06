// Metadata section — poster preview, editable title/year.

import SwiftUI

struct MetadataSection: View {
    @Bindable var job: FileJob
    @Environment(PipelineController.self) private var pipeline

    var body: some View {
        GroupBox("Metadata") {
            HStack(alignment: .top, spacing: 12) {
                // Poster preview
                if let data = job.metadata?.posterData, let nsImage = NSImage(data: data) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 100, height: 150)
                        .cornerRadius(6)
                        .shadow(radius: 2)
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.1))
                        .frame(width: 100, height: 150)
                        .overlay {
                            Image(systemName: "photo")
                                .font(.title)
                                .foregroundColor(.secondary)
                        }
                }

                VStack(alignment: .leading, spacing: 8) {
                    // Title
                    LabeledContent("Title") {
                        Text(job.metadata?.title ?? job.fileName)
                            .lineLimit(2)
                    }

                    // Type
                    if let meta = job.metadata {
                        switch meta {
                        case .movie(let m):
                            if let year = m.year {
                                LabeledContent("Year", value: String(year))
                            }
                            if let genre = m.genre {
                                LabeledContent("Genre", value: genre)
                            }
                        case .tvEpisode(let e):
                            LabeledContent("Show", value: e.showName)
                            LabeledContent("Episode", value: e.episodeID)
                            if let epTitle = e.episodeTitle {
                                LabeledContent("Title", value: epTitle)
                            }
                        }
                    }

                    // TMDb status
                    HStack {
                        if let meta = job.metadata {
                            switch meta {
                            case .movie(let m) where m.tmdbID != nil:
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.caption)
                                Text("TMDb matched")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            case .tvEpisode(let e) where e.tmdbShowID != nil:
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.caption)
                                Text("TMDb matched")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            default:
                                Image(systemName: "info.circle")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                                Text("Fallback metadata")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

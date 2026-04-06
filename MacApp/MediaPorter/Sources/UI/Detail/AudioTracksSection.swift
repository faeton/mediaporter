// Audio track selection — checkboxes per track.

import SwiftUI

private let langNames: [String: String] = [
    "eng": "English", "rus": "Russian", "fra": "French", "fre": "French",
    "deu": "German", "ger": "German", "spa": "Spanish", "ita": "Italian",
    "por": "Portuguese", "jpn": "Japanese", "kor": "Korean",
    "zho": "Chinese", "chi": "Chinese", "ara": "Arabic", "hin": "Hindi",
    "tur": "Turkish", "ukr": "Ukrainian", "pol": "Polish",
    "nld": "Dutch", "dut": "Dutch", "swe": "Swedish", "nor": "Norwegian",
    "dan": "Danish", "fin": "Finnish", "ces": "Czech", "cze": "Czech",
    "ron": "Romanian", "rum": "Romanian", "hun": "Hungarian",
    "und": "Unknown",
]

private func formatAudioTrack(_ stream: StreamInfo) -> String {
    let lang = langNames[stream.language?.lowercased() ?? "und"] ?? stream.language?.uppercased() ?? "UND"
    let codec = stream.codecName.uppercased()
    let ch: String
    if let channels = stream.channels {
        ch = channels >= 6 ? "\(channels - 1).1" : "\(channels).0"
    } else {
        ch = ""
    }
    var parts = [lang, codec, ch]
    if let title = stream.title, !title.isEmpty {
        parts.append("\"\(title)\"")
    }
    return parts.filter { !$0.isEmpty }.joined(separator: " ")
}

struct AudioTracksSection: View {
    @Bindable var job: FileJob

    var body: some View {
        guard let info = job.mediaInfo, !info.audioStreams.isEmpty else {
            return AnyView(EmptyView())
        }

        return AnyView(
            GroupBox("Audio Tracks") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(info.audioStreams.enumerated()), id: \.offset) { idx, stream in
                        HStack {
                            Toggle(isOn: Binding(
                                get: { job.selectedAudio.contains(idx) },
                                set: { on in
                                    if on { if !job.selectedAudio.contains(idx) { job.selectedAudio.append(idx) } }
                                    else { job.selectedAudio.removeAll { $0 == idx } }
                                }
                            )) {
                                Text(formatAudioTrack(stream))
                                    .font(.callout)
                            }
                            .toggleStyle(.checkbox)

                            Spacer()

                            let action = classifyAudioStream(stream)
                            Text(action.action)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(action.action == "copy" ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                                .foregroundColor(action.action == "copy" ? .green : .orange)
                                .cornerRadius(3)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        )
    }
}

// Subtitle track selection — internal + external subtitles.

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
    "bul": "Bulgarian", "hrv": "Croatian", "srp": "Serbian",
    "heb": "Hebrew", "tha": "Thai", "vie": "Vietnamese",
    "ind": "Indonesian", "may": "Malay", "gre": "Greek", "ell": "Greek",
    "und": "Unknown",
]

private func langName(_ code: String?) -> String {
    guard let code, !code.isEmpty else { return "Unknown" }
    return langNames[code.lowercased()] ?? code.uppercased()
}

private func formatSubTrack(_ stream: StreamInfo) -> String {
    let lang = langName(stream.language)
    let codec = stream.codecName.uppercased()
    var parts = [lang, codec]
    if let title = stream.title, !title.isEmpty {
        parts.append("\"\(title)\"")
    }
    if stream.isForced {
        parts.append("[forced]")
    }
    return parts.joined(separator: " ")
}

private func formatExternalSub(_ sub: ExternalSubtitle) -> String {
    let lang = langName(sub.language)
    let fmt = sub.format.uppercased()
    return "\(lang) \(fmt) (external)"
}

struct SubtitleTracksSection: View {
    @Bindable var job: FileJob

    var body: some View {
        guard let info = job.mediaInfo else { return AnyView(EmptyView()) }

        let hasSubs = !info.subtitleStreams.isEmpty || !info.externalSubtitles.isEmpty
        guard hasSubs else { return AnyView(EmptyView()) }

        return AnyView(
            GroupBox("Subtitles") {
                VStack(alignment: .leading, spacing: 6) {
                    // Internal subtitles
                    ForEach(Array(info.subtitleStreams.enumerated()), id: \.offset) { idx, stream in
                        let isBitmap = isBitmapSubtitle(stream.codecName)
                        HStack {
                            Toggle(isOn: Binding(
                                get: { job.selectedSubtitles.contains(idx) },
                                set: { on in
                                    if on { if !job.selectedSubtitles.contains(idx) { job.selectedSubtitles.append(idx) } }
                                    else { job.selectedSubtitles.removeAll { $0 == idx } }
                                }
                            )) {
                                Text(formatSubTrack(stream))
                                    .font(.callout)
                                    .foregroundColor(isBitmap ? .secondary : .primary)
                            }
                            .toggleStyle(.checkbox)
                            .disabled(isBitmap)

                            if isBitmap {
                                Text("bitmap — skip")
                                    .font(.caption2)
                                    .foregroundColor(.red)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color.red.opacity(0.1))
                                    .cornerRadius(3)
                            }
                        }
                    }

                    // External subtitles
                    if !info.externalSubtitles.isEmpty {
                        Divider()

                        ForEach(Array(info.externalSubtitles.enumerated()), id: \.offset) { idx, sub in
                            Toggle(isOn: Binding(
                                get: { job.selectedExternalSubs.contains(idx) },
                                set: { on in
                                    if on { if !job.selectedExternalSubs.contains(idx) { job.selectedExternalSubs.append(idx) } }
                                    else { job.selectedExternalSubs.removeAll { $0 == idx } }
                                }
                            )) {
                                Text(formatExternalSub(sub))
                                    .font(.callout)
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        )
    }
}

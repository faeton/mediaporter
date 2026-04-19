// File row — poster thumb + title + meta + inline expansion for audio/subs/resolution.

import SwiftUI
import MediaPorterCore

struct FileRowView: View {
    let job: FileJob
    let isExpanded: Bool
    let theme: Theme
    let accent: AccentKey
    let density: Density
    let onToggle: () -> Void
    let onRemove: () -> Void
    @Environment(PipelineController.self) private var pipeline
    @State private var confirmTranscode = false
    @State private var isEditingTitle = false
    @State private var editedTitle = ""
    @State private var editedYear = ""
    @State private var retryTMDb = true
    @State private var isRetryingLookup = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded { expanded.padding(.leading, 58).padding(.trailing, 16) }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isExpanded ? theme.rowSelected : Color.clear)
        )
        .animation(.easeInOut(duration: 0.15), value: isExpanded)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.textFaint)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .animation(.easeInOut(duration: 0.15), value: isExpanded)

            PosterThumb(job: job, theme: theme, density: density)

            VStack(alignment: .leading, spacing: 2) {
                titleLine
                Text(job.fileName)
                    .font(.system(size: density.fontMeta - 1, design: .monospaced))
                    .foregroundStyle(theme.textFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)

                metaRow

                if isActive, job.progress > 0 {
                    HStack(spacing: 8) {
                        ProgressBarInline(value: job.progress, theme: theme,
                                          color: job.status == .transcoding ? Color(hex: 0xFF9F0A) : accent.solid)
                        Text("\(Int(job.progress * 100))%")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(theme.textDim)
                            .frame(minWidth: 34, alignment: .trailing)
                    }
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            RemoveButton(theme: theme, action: onRemove)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, density.rowPadY)
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
    }

    private var titleLine: some View {
        Group {
            if case .tvEpisode(let ep) = job.metadata {
                HStack(spacing: 0) {
                    Text(ep.showName).fontWeight(.semibold)
                        .foregroundStyle(theme.text)
                    Text(String(format: " · S%02dE%02d", ep.season, ep.episode))
                        .fontWeight(.medium).foregroundStyle(theme.textDim)
                    if let et = ep.episodeTitle, !et.isEmpty {
                        Text(" · \(et)").fontWeight(.medium).foregroundStyle(theme.textDim)
                    }
                }
            } else if case .movie(let m) = job.metadata {
                HStack(spacing: 0) {
                    Text(m.title).fontWeight(.semibold)
                        .foregroundStyle(theme.text)
                    if let y = m.year {
                        Text(" · \(String(y))").fontWeight(.medium).foregroundStyle(theme.textDim)
                    }
                }
            } else {
                Text(job.fileName).fontWeight(.semibold).foregroundStyle(theme.text)
            }
        }
        .font(.system(size: density.fontTitle))
        .lineLimit(1)
        .truncationMode(.tail)
    }

    private var metaRow: some View {
        HStack(spacing: 6) {
            StatusDot(status: job.status, theme: theme, accent: accent)
            if job.decision != nil {
                ActionChip(action: job.effectiveAction, theme: theme)
            }
            MetaDot(theme: theme)
            if let v = job.mediaInfo?.videoStreams.first {
                Text("\(v.width)×\(v.height) · \(v.codecName.uppercased())")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textDim)
            }
            MetaDot(theme: theme)
            if let d = job.mediaInfo?.duration {
                Text(fmtDuration(d))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textDim)
            }
            MetaDot(theme: theme)
            Text(fmtSizeMB(job.fileSizeMB))
                .font(.system(size: 11))
                .foregroundStyle(theme.textDim)
            if !tmdbMatched {
                MetaDot(theme: theme)
                Text("no TMDb match")
                    .font(.system(size: 10))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(theme.chipSkip, in: RoundedRectangle(cornerRadius: 3))
                    .foregroundStyle(theme.chipSkipText)
            }
        }
        .padding(.top, 4)
    }

    private var tmdbMatched: Bool {
        guard let m = job.metadata else { return false }
        switch m {
        case .movie(let mm): return mm.tmdbID != nil
        case .tvEpisode(let e): return e.tmdbShowID != nil
        }
    }

    private var isActive: Bool {
        switch job.status {
        case .analyzing, .transcoding, .tagging, .syncing: return true
        default: return false
        }
    }

    // MARK: - Expanded

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 2) {
            Divider().background(theme.divider).padding(.top, 4)
            Spacer().frame(height: 10)

            videoSection
            if let audios = job.mediaInfo?.audioStreams, !audios.isEmpty {
                audioSection(audios: audios)
            }
            if subtitlesPresent {
                subtitlesSection
            }
            metadataSection
        }
        .padding(.bottom, density.expandedPad)
    }

    private var videoSection: some View {
        OptionsRow(label: "Video", systemImage: "film", theme: theme) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if let v = job.mediaInfo?.videoStreams.first {
                        Text("\(v.codecName.uppercased()) · \(v.width)×\(v.height)" + (v.profile.map { " · \($0)" } ?? ""))
                            .font(.system(size: 12)).foregroundStyle(theme.text)
                    }
                    ActionChip(action: videoAction, theme: theme)
                    Spacer(minLength: 8)
                    if job.status == .analyzed && !pipeline.isRunning {
                        Button { confirmTranscode = true } label: {
                            Text("Transcode only…")
                                .font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 5)
                                        .strokeBorder(theme.divider, lineWidth: 1)
                                )
                                .foregroundStyle(theme.text)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Transcode this file and tag it, but don't send it to the device.")
                    }
                }
                ResolutionPicker(job: job, theme: theme, accent: accent)
                if job.maxResolution != .original, let srcH = job.mediaInfo?.videoStreams.first?.height {
                    let target = job.maxResolution.maxHeight ?? srcH
                    if target < srcH {
                        HStack(spacing: 5) {
                            Image(systemName: "info.circle")
                                .font(.system(size: 10))
                            Text("Will downscale \(srcH)p → \(target)p. Saves space, no visible quality loss on device.")
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(theme.textDim)
                        .padding(.top, 2)
                    }
                }
            }
        }
        .confirmationDialog(
            "Transcode \(job.fileName) without syncing?",
            isPresented: $confirmTranscode,
            titleVisibility: .visible
        ) {
            Button("Transcode") {
                Task { await pipeline.transcodeOne(job) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The output will go to macOS's temp directory:\n\(tempDirDisplay)\n\nFiles there may be cleared on reboot or when macOS reclaims space. Move what you want to keep.")
        }
    }

    private var tempDirDisplay: String {
        FileManager.default.temporaryDirectory.path
    }

    private var videoAction: String {
        guard let decision = job.decision, let firstV = job.mediaInfo?.videoStreams.first else { return "copy" }
        return decision.streamActions[firstV.index] ?? (decision.needsTranscode ? "transcode" : "copy")
    }

    private func audioSection(audios: [StreamInfo]) -> some View {
        OptionsRow(label: "Audio", systemImage: "waveform", theme: theme) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(audios.indices, id: \.self) { i in
                    let a = audios[i]
                    let on = job.selectedAudio.contains(i)
                    let act = job.decision?.streamActions[a.index] ?? "copy"
                    SelectableLine(checked: on, theme: theme, accent: accent,
                                   onTap: { toggleAudio(i) }) {
                        HStack(spacing: 8) {
                            Text(a.language ?? "Unknown")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(theme.text)
                                .frame(minWidth: 80, alignment: .leading)
                            Text("\(a.codecName.uppercased()) \(channelsLabel(a.channels ?? 2))")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(theme.textDim)
                            if let t = a.title, !t.isEmpty {
                                Text("· \(t)")
                                    .font(.system(size: 11).italic())
                                    .foregroundStyle(theme.textFaint)
                                    .lineLimit(1).truncationMode(.tail)
                            }
                            Spacer(minLength: 8)
                            ActionChip(action: act, theme: theme)
                        }
                    }
                }
            }
        }
    }

    private var subtitlesPresent: Bool {
        let subs = job.mediaInfo?.subtitleStreams ?? []
        let ext = job.mediaInfo?.externalSubtitles ?? []
        return !subs.isEmpty || !ext.isEmpty
    }

    private var subtitlesSection: some View {
        OptionsRow(label: "Subtitles", systemImage: "captions.bubble", theme: theme) {
            VStack(alignment: .leading, spacing: 2) {
                if let subs = job.mediaInfo?.subtitleStreams {
                    ForEach(subs.indices, id: \.self) { i in
                        let s = subs[i]
                        let act = job.decision?.streamActions[s.index] ?? "embed"
                        let disabled = act == "skip-bitmap"
                        let on = job.selectedSubtitles.contains(i)
                        SelectableLine(checked: on, theme: theme, accent: accent,
                                       disabled: disabled,
                                       onTap: { toggleSubtitle(i) }) {
                            HStack(spacing: 8) {
                                Text(s.language ?? "Unknown")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(theme.text)
                                    .frame(minWidth: 80, alignment: .leading)
                                Text(s.codecName.uppercased())
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(theme.textDim)
                                if s.isForced {
                                    Text("[forced]")
                                        .font(.system(size: 10))
                                        .foregroundStyle(theme.textFaint)
                                }
                                if let t = s.title, !t.isEmpty {
                                    Text("· \(t)")
                                        .font(.system(size: 11).italic())
                                        .foregroundStyle(theme.textFaint)
                                        .lineLimit(1).truncationMode(.tail)
                                }
                                Spacer(minLength: 8)
                                ActionChip(action: act, theme: theme)
                            }
                        }
                    }
                }
                if let ext = job.mediaInfo?.externalSubtitles {
                    ForEach(ext.indices, id: \.self) { i in
                        let e = ext[i]
                        let on = job.selectedExternalSubs.contains(i)
                        SelectableLine(checked: on, theme: theme, accent: accent,
                                       onTap: { toggleExternal(i) }) {
                            HStack(spacing: 8) {
                                Text(e.language.isEmpty ? "Unknown" : e.language)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(theme.text)
                                    .frame(minWidth: 80, alignment: .leading)
                                Text(e.format.uppercased())
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(theme.textDim)
                                Text("sidecar")
                                    .font(.system(size: 10))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(theme.pill, in: RoundedRectangle(cornerRadius: 3))
                                    .foregroundStyle(theme.textFaint)
                                Spacer(minLength: 8)
                                ActionChip(action: "embed", theme: theme)
                            }
                        }
                    }
                }
            }
        }
    }

    private var metadataSection: some View {
        OptionsRow(label: "Metadata", systemImage: "tag", theme: theme) {
            HStack(spacing: 8) {
                if tmdbMatched {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(red: 0.19, green: 0.82, blue: 0.35))
                    Text("TMDb matched · poster and metadata attached")
                        .font(.system(size: 12)).foregroundStyle(theme.text)
                } else {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(theme.chipSkipText)
                    Text("No TMDb match · fallback poster generated")
                        .font(.system(size: 12)).foregroundStyle(theme.textDim)
                    Button { openEditTitle() } label: {
                        Text("Edit title…")
                            .font(.system(size: 11))
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(theme.divider, lineWidth: 1)
                            )
                            .foregroundStyle(theme.text)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .sheet(isPresented: $isEditingTitle) {
            EditTitleSheet(
                theme: theme,
                accent: accent,
                initialTitle: editedTitle,
                initialYear: editedYear,
                hasAPIKey: !pipeline.tmdbAPIKey.isEmpty,
                retryTMDb: $retryTMDb,
                isLoading: $isRetryingLookup,
                onSave: { newTitle, newYear, shouldRetry in
                    Task { await saveEditedTitle(newTitle, year: newYear, retry: shouldRetry) }
                },
                onCancel: { isEditingTitle = false }
            )
        }
    }

    // MARK: - Title editing

    private func openEditTitle() {
        switch job.metadata {
        case .movie(let m):
            editedTitle = m.title
            editedYear = m.year.map(String.init) ?? ""
        case .tvEpisode(let e):
            editedTitle = e.showName
            editedYear = e.year.map(String.init) ?? ""
        case .none:
            editedTitle = job.fileName
                .replacingOccurrences(of: "." + (job.inputURL.pathExtension), with: "")
            editedYear = ""
        }
        retryTMDb = !pipeline.tmdbAPIKey.isEmpty
        isEditingTitle = true
    }

    private func saveEditedTitle(_ newTitle: String, year: String, retry: Bool) async {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let yearInt = Int(year.trimmingCharacters(in: .whitespaces))

        // 1. Optionally re-query TMDb with the edited title as hint.
        if retry, !pipeline.tmdbAPIKey.isEmpty {
            isRetryingLookup = true
            let resolved: ResolvedMetadata?
            switch job.metadata {
            case .tvEpisode(let e):
                resolved = await MetadataLookup.lookup(
                    path: job.inputURL,
                    showOverride: trimmed,
                    seasonOverride: e.season,
                    episodeOverride: e.episode,
                    apiKey: pipeline.tmdbAPIKey
                )
            default:
                // For movies / unknown: TMDb lookup parses filename, so override via a temp URL.
                let alias = job.inputURL.deletingLastPathComponent()
                    .appendingPathComponent(trimmed + (yearInt.map { " (\($0))" } ?? "") + "." + job.inputURL.pathExtension)
                resolved = await MetadataLookup.lookup(
                    path: alias,
                    apiKey: pipeline.tmdbAPIKey
                )
            }
            isRetryingLookup = false
            if let resolved {
                job.metadata = resolved
                isEditingTitle = false
                return
            }
            // fall through to local edit if lookup returned nil
        }

        // 2. Local edit only — update the existing metadata and regenerate fallback poster.
        let poster = PosterGenerator.generate(title: trimmed, year: yearInt)
        switch job.metadata {
        case .tvEpisode(var e):
            e.showName = trimmed
            if let y = yearInt { e.year = y }
            e.showPosterData = poster
            job.metadata = .tvEpisode(e)
        case .movie(var m):
            m.title = trimmed
            if yearInt != nil { m.year = yearInt }
            m.posterData = poster
            job.metadata = .movie(m)
        case .none:
            job.metadata = .movie(MovieMetadata(
                title: trimmed, year: yearInt, genre: nil, overview: nil,
                longOverview: nil, director: nil, posterURL: nil,
                posterData: poster, tmdbID: nil
            ))
        }
        isEditingTitle = false
    }

    private func toggleAudio(_ i: Int) {
        if let idx = job.selectedAudio.firstIndex(of: i) {
            job.selectedAudio.remove(at: idx)
        } else {
            job.selectedAudio = (job.selectedAudio + [i]).sorted()
        }
    }
    private func toggleSubtitle(_ i: Int) {
        if let idx = job.selectedSubtitles.firstIndex(of: i) {
            job.selectedSubtitles.remove(at: idx)
        } else {
            job.selectedSubtitles = (job.selectedSubtitles + [i]).sorted()
        }
    }
    private func toggleExternal(_ i: Int) {
        if let idx = job.selectedExternalSubs.firstIndex(of: i) {
            job.selectedExternalSubs.remove(at: idx)
        } else {
            job.selectedExternalSubs = (job.selectedExternalSubs + [i]).sorted()
        }
    }

    private func channelsLabel(_ ch: Int) -> String {
        if ch >= 6 { return "\(ch - 1).1" }
        return "\(ch).0"
    }
}

// MARK: - Subcomponents

private struct MetaDot: View {
    let theme: Theme
    var body: some View {
        Text("·").font(.system(size: 11)).foregroundStyle(theme.textFaint)
    }
}

private struct StatusDot: View {
    let status: JobStatus
    let theme: Theme
    let accent: AccentKey

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
                .overlay(
                    Circle()
                        .strokeBorder(dotColor.opacity(0.2), lineWidth: 3)
                        .opacity(isAnimating ? 1 : 0)
                )
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.textDim)
        }
    }

    private var isAnimating: Bool {
        status == .analyzing || status == .transcoding || status == .syncing
    }

    private var dotColor: Color {
        switch status {
        case .pending: return theme.textFaint
        case .analyzing: return accent.solid
        case .analyzed: return theme.textDim
        case .transcoding: return Color(hex: 0xFF9F0A)
        case .tagging: return Color(hex: 0xBF5AF2)
        case .ready: return Color(red: 0.19, green: 0.82, blue: 0.35)
        case .syncing: return accent.solid
        case .synced: return Color(red: 0.19, green: 0.82, blue: 0.35)
        case .failed: return Color(red: 1.0, green: 0.27, blue: 0.23)
        }
    }
    private var label: String {
        switch status {
        case .pending: return "Queued"
        case .analyzing: return "Analyzing"
        case .analyzed: return "Ready for options"
        case .transcoding: return "Transcoding"
        case .tagging: return "Tagging"
        case .ready: return "Ready to send"
        case .syncing: return "Uploading"
        case .synced: return "Synced"
        case .failed: return "Failed"
        }
    }
}

private struct PosterThumb: View {
    let job: FileJob
    let theme: Theme
    let density: Density

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            theme.posterBg
                .overlay {
                    if let data = job.metadata?.posterData, let image = NSImage(data: data) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "film")
                            .font(.system(size: 18))
                            .foregroundStyle(theme.textFaint)
                    }
                }
            if job.status == .synced {
                ZStack {
                    Rectangle().fill(Color.black.opacity(0.3))
                    Circle()
                        .fill(Color(red: 0.19, green: 0.82, blue: 0.35))
                        .frame(width: 14, height: 14)
                        .overlay(
                            Image(systemName: "checkmark")
                                .font(.system(size: 7, weight: .heavy))
                                .foregroundStyle(.white)
                        )
                        .padding(3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
        }
        .frame(width: density.thumbWidth, height: density.thumbHeight)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.2), radius: 3, y: 2)
    }
}

private struct RemoveButton: View {
    let theme: Theme
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering ? Color(red: 1.0, green: 0.27, blue: 0.23) : theme.textFaint)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(hovering ? theme.rowHover : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Remove")
    }
}

/// Whole-line selection button — click anywhere on the row to toggle the checkbox.
struct SelectableLine<Content: View>: View {
    let checked: Bool
    let theme: Theme
    let accent: AccentKey
    var disabled: Bool = false
    let onTap: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        Button(action: { if !disabled { onTap() } }) {
            HStack(spacing: 8) {
                checkbox
                content()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(hovering && !disabled ? theme.rowHover : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .opacity(disabled ? 0.55 : 1)
        .onHover { hovering = $0 }
    }

    private var checkbox: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(checked ? accent.solid : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(checked ? accent.solid : theme.divider, lineWidth: 1)
            )
            .frame(width: 15, height: 15)
            .overlay(
                checked
                    ? Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.white)
                    : nil
            )
    }
}

struct ActionChip: View {
    let action: String
    let theme: Theme

    var body: some View {
        let (bg, fg, label) = colors
        Text(label)
            .font(.system(size: 10, design: .monospaced))
            .tracking(0.2)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(bg, in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(fg)
    }

    private var colors: (Color, Color, String) {
        switch action {
        case "copy":        return (theme.chipCopy, theme.chipCopyText, "copy")
        case "transcode":   return (theme.chipTranscode, theme.chipTranscodeText, "transcode")
        case "embed":       return (theme.chipCopy, theme.chipCopyText, "embed")
        case "skip-bitmap": return (theme.chipSkip, theme.chipSkipText, "bitmap · skip")
        case "remux":       return (theme.chipRemux, theme.chipRemuxText, "remux")
        default:            return (theme.pill, theme.pillText, action)
        }
    }
}

struct ProgressBarInline: View {
    let value: Double
    let theme: Theme
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.divider)
                Capsule().fill(color)
                    .frame(width: geo.size.width * max(0, min(1, value)))
                    .animation(.easeOut(duration: 0.3), value: value)
            }
        }
        .frame(height: 3)
    }
}

private struct OptionsRow<Content: View>: View {
    let label: String
    let systemImage: String
    let theme: Theme
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 10))
                Text(label)
                    .font(.system(size: 11))
            }
            .foregroundStyle(theme.textDim)
            .frame(width: 82, alignment: .leading)
            .padding(.top, 3)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
    }
}

private struct ResolutionPicker: View {
    let job: FileJob
    let theme: Theme
    let accent: AccentKey
    @Environment(PipelineController.self) private var pipeline

    var body: some View {
        let sourceH = job.mediaInfo?.videoStreams.first?.height ?? 0
        // Recommended = device's suggested resolution if known, else 1080p for HD sources.
        let recommended: ResolutionLimit = pipeline.deviceInfo?.suggestedResolution
            ?? (sourceH >= 1080 ? .fhd : .original)

        // Start with Original, then downscale options that would actually shrink the file.
        var opts: [(ResolutionLimit, String)] = [(.original, "Original · \(sourceH)p")]
        if sourceH > 2160 { opts.append((.uhd4k, "4K · 2160p")) }
        if sourceH > 1080 { opts.append((.fhd, "1080p")) }
        if sourceH > 720  { opts.append((.hd, "720p")) }

        return HStack(spacing: 4) {
            ForEach(opts, id: \.0.rawValue) { opt in
                let on = job.maxResolution == opt.0
                let isRec = opt.0 == recommended
                Button {
                    job.maxResolution = opt.0
                } label: {
                    HStack(spacing: 6) {
                        Text(opt.1).font(.system(size: 12, weight: .medium))
                        if isRec && opt.0 != .original {
                            Text("Recommended")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(accent.solid)
                        }
                    }
                    .foregroundStyle(on ? accent.solid : theme.text)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(on ? accent.soft : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(on ? accent.solid : theme.divider, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(on ? "Selected" : "Click to use \(opt.1)")
            }
        }
    }
}

// MARK: - Edit Title sheet

private struct EditTitleSheet: View {
    let theme: Theme
    let accent: AccentKey
    let initialTitle: String
    let initialYear: String
    let hasAPIKey: Bool
    @Binding var retryTMDb: Bool
    @Binding var isLoading: Bool
    let onSave: (_ title: String, _ year: String, _ retryTMDb: Bool) -> Void
    let onCancel: () -> Void

    @State private var title: String = ""
    @State private var year: String = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit title")
                .font(.system(size: 15, weight: .semibold))

            Text("Used as the poster label and, with a TMDb key, as the search term.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Title").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Title", text: $title, prompt: Text("Movie or show name"))
                    .textFieldStyle(.roundedBorder)
                    .focused($titleFocused)
                    .onSubmit(performSave)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Year (optional)").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Year", text: $year, prompt: Text("2024"))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 120)
            }

            if hasAPIKey {
                Toggle("Re-query TMDb with this title", isOn: $retryTMDb)
                    .font(.system(size: 12))
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                    Text("Add a TMDb key in Settings to fetch real posters when editing.")
                        .font(.system(size: 11))
                }
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            HStack {
                if isLoading {
                    ProgressView().controlSize(.small)
                    Text("Searching TMDb…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: performSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || isLoading)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            title = initialTitle
            year = initialYear
            DispatchQueue.main.async { titleFocused = true }
        }
    }

    private func performSave() {
        onSave(title, year, retryTMDb)
    }
}

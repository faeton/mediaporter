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

                if job.status == .failed, let err = job.error, !err.isEmpty {
                    Text(err)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.chipSkipText)
                        .lineLimit(6)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if job.status == .failed {
                RetryButton(theme: theme, accent: accent) { pipeline.retry(job) }
            }
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
                Text(videoDimensionSummary(v))
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
                        Text(videoExpandedSummary(v))
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
                        let recommended = pipeline.deviceInfo?.suggestedResolution ?? .fhd
                        let recH = recommended.maxHeight ?? target
                        let tail: String = target >= recH
                            ? "Saves space, no visible quality loss on device."
                            : "Saves more space, but will look noticeably softer than the device can display."
                        HStack(spacing: 5) {
                            Image(systemName: "info.circle")
                                .font(.system(size: 10))
                            Text("Will downscale \(srcH)p → \(target)p. \(tail)")
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
                let dest = alongsideSourceDestination(for: job)
                Task { await pipeline.transcodeOne(job, destinationURL: dest) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Saving next to the source as:\n\(alongsideSourceDestination(for: job).lastPathComponent)\n\nThe file stays in \(job.inputURL.deletingLastPathComponent().path).")
        }
    }

    /// Transcoded output path next to the source file. Uses a `.mediaporter.m4v`
    /// suffix so it's obvious which file is the transcode and avoids clobbering
    /// the original or any prior run. Appends " 2", " 3"… if a collision exists.
    private func alongsideSourceDestination(for job: FileJob) -> URL {
        let dir = job.inputURL.deletingLastPathComponent()
        let stem = job.inputURL.deletingPathExtension().lastPathComponent
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent("\(stem).mediaporter.m4v")
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(stem).mediaporter \(n).m4v")
            n += 1
        }
        return candidate
    }

    private var videoAction: String {
        guard let decision = job.decision, let firstV = job.mediaInfo?.videoStreams.first else { return "copy" }
        return decision.streamActions[firstV.index] ?? (decision.needsTranscode ? "transcode" : "copy")
    }

    /// Compact video dimensions for the meta row. Unwrap Int? explicitly so
    /// string interpolation doesn't leak "Optional(3840)".
    private func videoDimensionSummary(_ v: StreamInfo) -> String {
        let dims = (v.width.flatMap { w in v.height.map { h in "\(w)×\(h)" } }) ?? ""
        let codec = v.codecName.uppercased()
        return dims.isEmpty ? codec : "\(dims) · \(codec)"
    }

    /// Fuller video line for the expanded section (codec · dims · profile).
    private func videoExpandedSummary(_ v: StreamInfo) -> String {
        let dims = (v.width.flatMap { w in v.height.map { h in "\(w)×\(h)" } }) ?? ""
        var parts: [String] = [v.codecName.uppercased()]
        if !dims.isEmpty { parts.append(dims) }
        if let p = v.profile, !p.isEmpty { parts.append(p) }
        return parts.joined(separator: " · ")
    }

    /// Short human label for the codec column in the subtitle list.
    private func subtitleKindLabel(_ s: StreamInfo) -> String {
        switch s.codecName {
        case "subrip", "srt": return "SRT"
        case "ass", "ssa": return "ASS"
        case "mov_text": return "MOV_TEXT"
        case "webvtt": return "WEBVTT"
        case "hdmv_pgs_subtitle", "pgssub": return "PGS"
        case "dvd_subtitle": return "VOBSUB"
        case "dvb_subtitle": return "DVB"
        default: return s.codecName.uppercased()
        }
    }

    /// Disposition flags worth surfacing per subtitle track. "default" is only
    /// shown when it contradicts the language (e.g. default on a non-primary
    /// language), since "default" on a single-language sub is meaningless.
    private func subtitleDispositionTags(_ s: StreamInfo) -> [String] {
        var tags: [String] = []
        if s.isForced { tags.append("forced") }
        if s.isHearingImpaired { tags.append("SDH") }
        if s.isDefault { tags.append("default") }
        return tags
    }

    /// A single subtitle track row (checkbox + language + codec + flags + chip).
    /// Extracted so the ViewBuilder in subtitlesSection doesn't get tangled in
    /// nested ForEach type inference.
    @ViewBuilder
    private func subtitleRow(subs: [StreamInfo], index i: Int) -> some View {
        let s = subs[i]
        let rawAction = job.decision?.streamActions[s.index] ?? "embed"
        let act: String = {
            if rawAction == "skip" { return isBitmapSubtitle(s.codecName) ? "bitmap" : "skip" }
            if rawAction == "convert_to_mov_text" { return "convert" }
            return rawAction
        }()
        let disabled = rawAction == "skip" && isBitmapSubtitle(s.codecName)
        let on = job.selectedSubtitles.contains(i)

        SelectableLine(
            checked: on, theme: theme, accent: accent, disabled: disabled,
            onTap: { toggleSubtitle(i) }
        ) {
            HStack(spacing: 8) {
                Text(s.language ?? "und")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.text)
                    .frame(minWidth: 50, alignment: .leading)
                Text(subtitleKindLabel(s))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.textDim)
                ForEach(subtitleDispositionTags(s), id: \.self) { tag in
                    Text(tag)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(theme.pill, in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(theme.pillText)
                }
                if let t = s.title, !t.isEmpty {
                    Text("· \(t)")
                        .font(.system(size: 11).italic())
                        .foregroundStyle(theme.textFaint)
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 8)
                if job.videoBeingReencoded {
                    BurnInButton(
                        isOn: job.burnInSubtitle == .embedded(i),
                        theme: theme,
                        accent: accent,
                        onTap: { toggleBurnIn(.embedded(i)) }
                    )
                }
                ActionChip(action: act, theme: theme)
            }
        }
    }

    /// One-line explainer shown above the subtitle checklist. Message depends
    /// on what kinds of subs the file actually has, so it's informative instead
    /// of generic ("drop a .srt next to the file" wouldn't help if the user
    /// already has text subs available).
    @ViewBuilder
    private var subtitleExplainer: some View {
        let subs = job.mediaInfo?.subtitleStreams ?? []
        let hasAnyText = subs.contains { !isBitmapSubtitle($0.codecName) }
        let hasAnyBitmap = subs.contains { isBitmapSubtitle($0.codecName) }
        let onlyBitmap = !subs.isEmpty && !hasAnyText && hasAnyBitmap

        if onlyBitmap {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textDim)
                Text("All subtitles are bitmap (PGS/VOBSUB) — the TV app can't display those in MP4. Drop a .srt alongside the file to add text subs.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 6)
        } else if hasAnyBitmap && hasAnyText {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textDim)
                Text("Bitmap subtitles (PGS/VOBSUB) can't be embedded — only text subs will ship.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textDim)
            }
            .padding(.bottom, 6)
        }
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
                subtitleExplainer
                if let subs = job.mediaInfo?.subtitleStreams {
                    ForEach(subs.indices, id: \.self) { i in
                        subtitleRow(subs: subs, index: i)
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
                                if job.videoBeingReencoded {
                                    BurnInButton(
                                        isOn: job.burnInSubtitle == .external(i),
                                        theme: theme,
                                        accent: accent,
                                        onTap: { toggleBurnIn(.external(i)) }
                                    )
                                }
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
                // For movies / unknown: pass title + year directly so the filename
                // parser's quirks (regex edge cases, noise in the original name)
                // can't swallow the user's explicit hint.
                resolved = await MetadataLookup.lookupMovieDirect(
                    title: trimmed,
                    year: yearInt,
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

    /// Mutually-exclusive burn-in selector. Tapping the currently-burned track
    /// clears the burn-in; tapping another track moves it.
    private func toggleBurnIn(_ target: BurnInSubtitle) {
        if job.burnInSubtitle == target {
            job.burnInSubtitle = nil
        } else {
            job.burnInSubtitle = target
        }
    }

    private func channelsLabel(_ ch: Int) -> String {
        if ch >= 6 { return "\(ch - 1).1" }
        return "\(ch).0"
    }
}

// MARK: - Subcomponents

/// Tiny toggle button for "burn this subtitle into the video". Shown only when
/// the video is already being re-encoded so burn-in is zero extra cost. A job
/// can have at most one burn-in selection.
private struct BurnInButton: View {
    let isOn: Bool
    let theme: Theme
    let accent: AccentKey
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 9, weight: .semibold))
                Text("Burn in")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(isOn ? .white : theme.textDim)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(
                isOn
                    ? AnyShapeStyle(accent.solid)
                    : AnyShapeStyle(hovering ? theme.pill.opacity(1.4) : theme.pill),
                in: RoundedRectangle(cornerRadius: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(isOn ? accent.ring : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(isOn ? "Burned into video during transcode"
                   : "Burn this subtitle into the video (no extra cost — already transcoding)")
    }
}

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
    @State private var previewing = false

    private var hasPoster: Bool {
        guard let data = job.metadata?.posterData, NSImage(data: data) != nil else { return false }
        return true
    }

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
        // Hold 0.15s to peek at the full-size poster. A quick click doesn't
        // trigger (perform: only fires after the threshold), so the row-select
        // behavior on the rest of the row is unaffected. Release to dismiss.
        .onLongPressGesture(
            minimumDuration: 0.15,
            maximumDistance: 12,
            perform: { if hasPoster { previewing = true } },
            onPressingChanged: { inProgress in
                if !inProgress { previewing = false }
            }
        )
        .popover(isPresented: $previewing, arrowEdge: .trailing) {
            PosterPreview(job: job, theme: theme)
        }
        .help(hasPoster ? "Hold to preview" : "")
    }
}

/// Large-size poster preview shown in a popover while the user is holding
/// down on the thumbnail.
private struct PosterPreview: View {
    let job: FileJob
    let theme: Theme

    var body: some View {
        VStack(spacing: 8) {
            Group {
                if let data = job.metadata?.posterData, let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    theme.posterBg
                        .overlay(
                            Image(systemName: "film")
                                .font(.system(size: 48))
                                .foregroundStyle(theme.textFaint)
                        )
                }
            }
            .frame(width: 360, height: 540)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            if let title = job.metadata?.title {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
        }
        .padding(14)
    }
}

private struct RetryButton: View {
    let theme: Theme
    let accent: AccentKey
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering ? accent.solid : theme.textDim)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(hovering ? accent.soft : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Retry")
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
        case "skip":        return (theme.pill, theme.pillText, "skip")
        // Bitmap subs can't go into MP4 — it's a container limit, not an error.
        // Neutral pill instead of red-alert so the row doesn't look broken.
        case "bitmap":      return (theme.pill, theme.pillText, "bitmap · can't embed")
        case "convert":     return (theme.chipRemux, theme.chipRemuxText, "convert to mov_text")
        case "skip-bitmap": return (theme.pill, theme.pillText, "bitmap · can't embed")
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
        if sourceH > 480  { opts.append((.sd, "480p")) }
        if sourceH > 360  { opts.append((.tiny, "360p")) }

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

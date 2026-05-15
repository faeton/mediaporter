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
    @Environment(\.openSettings) private var openSettings
    @State private var confirmTranscode = false
    @State private var isEditingTitle = false
    @State private var editedTitle = ""
    @State private var editedYear = ""
    @State private var editedKind: EditMediaKind = .movie
    @State private var editedSeason: Int = 1
    @State private var editedEpisode: Int = 1
    @State private var retryTMDb = true
    @State private var isRetryingLookup = false

    /// Anchor for the "Apply selection to all N episodes of <show>?" popover
    /// (#11b). Set by `didChangeClusterSelection()` after any audio / sub /
    /// resolution / burn-in toggle that lands on a clustered file with ≥ 1
    /// sibling. Non-nil ⇒ popover shown; cleared on user choice or 5 s timer.
    @State private var clusterApplyPending: ClusterApplyPrompt?
    @State private var clusterApplyDismissTask: Task<Void, Never>?

    /// When true, every per-row change propagates to siblings without
    /// surfacing the popover. Power-user setting.
    @AppStorage("alwaysApplyWithinShow") private var alwaysApplyWithinShow: Bool = false

    private struct ClusterApplyPrompt: Identifiable, Equatable {
        let id = UUID()
        let clusterID: String
        let siblingCount: Int
        let showLabel: String
    }

    /// Cluster picker presentation — shown for TV files instead of EditTitleSheet.
    /// `id == clusterID`, so a non-nil value drives `.sheet(item:)`.
    @State private var showPickerInvocation: ShowPickerInvocation?

    /// Args bundle for the on-demand picker (vs the auto-prompt path in
    /// ContentView which reads from pipeline.pendingShowPicks).
    private struct ShowPickerInvocation: Identifiable {
        let id: String                     // clusterID
        let query: String
        let candidates: [TVShowCandidate]
        let affectedCount: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded { expanded.padding(.leading, 58).padding(.trailing, 16) }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isExpanded ? theme.rowSelected : Color.clear)
        )
        // Dim rows that won't actually be sent (#10b skip). The "on device — skip"
        // badge keeps full opacity so the toggle is still discoverable.
        .opacity(job.duplicateOnDevice == true && !job.syncDespiteDuplicate ? 0.5 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isExpanded)
        .popover(item: $clusterApplyPending, attachmentAnchor: .point(.bottom)) { prompt in
            clusterApplyPopover(prompt: prompt)
        }
    }

    private func clusterApplyPopover(prompt: ClusterApplyPrompt) -> some View {
        let n = prompt.siblingCount
        let plural = n == 1 ? "episode" : "episodes"
        return VStack(alignment: .leading, spacing: 10) {
            Text("Apply selection to all \(n) other \(plural) of *\(prompt.showLabel)*?")
                .font(.system(size: 13))
                .foregroundStyle(theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320, alignment: .leading)
            HStack(spacing: 8) {
                Button("Apply to all") {
                    pipeline.captureClusterSelection(from: job, propagate: true)
                    clusterApplyDismissTask?.cancel()
                    clusterApplyPending = nil
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button("Just this one") {
                    pipeline.captureClusterSelection(from: job, propagate: false)
                    clusterApplyDismissTask?.cancel()
                    clusterApplyPending = nil
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer()
                Toggle("Always", isOn: $alwaysApplyWithinShow)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help("Always propagate per-row changes to every episode in the same show without asking.")
            }
        }
        .padding(12)
        .frame(width: 360)
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
            StatusDot(status: job.status, hasError: job.error != nil, theme: theme, accent: accent)
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
            // Source bitrate — the real "why is this 1080p file so huge"
            // signal. Hidden when ffprobe didn't surface a number.
            if let br = job.mediaInfo?.bitRate, br > 0 {
                MetaDot(theme: theme)
                Text(fmtBitrate(br))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textDim)
            }
            if !tmdbMatched {
                MetaDot(theme: theme)
                if tmdbKeyMissing {
                    Button { openSettings() } label: {
                        Text("no TMDb key")
                            .font(.system(size: 10))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(theme.chipSkip, in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(theme.chipSkipText)
                    }
                    .buttonStyle(.plain)
                    .help("TMDb API key not set — click to add one in Settings. Fallback poster generated for now.")
                } else {
                    Text("no TMDb match")
                        .font(.system(size: 10))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(theme.chipSkip, in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(theme.chipSkipText)
                }
            }
            if let extrasLabel = externalTracksLabel {
                MetaDot(theme: theme)
                Text(extrasLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(accent.soft, in: RoundedRectangle(cornerRadius: 3))
                    .foregroundStyle(accent.solid)
                    .help("External tracks queued for muxing. Cluster choices live in the extras section at the top of the list.")
            }
            if job.duplicateOnDevice == true {
                MetaDot(theme: theme)
                Button {
                    job.syncDespiteDuplicate.toggle()
                } label: {
                    Text(job.syncDespiteDuplicate ? "will duplicate" : "on device — skip")
                        .font(.system(size: 10))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(
                            job.syncDespiteDuplicate ? Color(hex: 0xFF9F0A).opacity(0.18) : theme.chipSkip,
                            in: RoundedRectangle(cornerRadius: 3)
                        )
                        .foregroundStyle(job.syncDespiteDuplicate ? Color(hex: 0xFF9F0A) : theme.chipSkipText)
                }
                .buttonStyle(.plain)
                .help(job.syncDespiteDuplicate
                      ? "Will sync anyway and create a duplicate row in TV.app. Click to skip."
                      : "Already on the device. Click to sync anyway (creates a duplicate row).")
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

    private var tmdbKeyMissing: Bool {
        pipeline.tmdbAPIKey.isEmpty
    }

    private var isActive: Bool {
        switch job.status {
        case .analyzing, .muxing, .transcoding, .tagging, .syncing: return true
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
                    // Also show for .ready so users can re-transcode with
                    // different settings (e.g. flip resolution or burn-in)
                    // without having to remove-and-readd the file.
                    if (job.status == .analyzed || job.status == .ready) && !pipeline.isRunning {
                        Button { confirmTranscode = true } label: {
                            Text(job.status == .ready ? "Re-transcode…" : "Transcode only…")
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
                ResolutionPicker(job: job, theme: theme, accent: accent,
                                 onChange: didChangeClusterSelection)
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

    /// Collect labels of every subtitle track currently selected for this
    /// job, keyed by ISO 639-2/T language. Embedded streams come first (in
    /// selection order), then external SRTs, then cluster-mux extras. Used
    /// by `sameLangSubWarning` to surface the iOS picker's same-language
    /// dedup behavior — the TV-app collapses two tracks that share a lang
    /// code into a single picker entry regardless of `title`, `handler_name`,
    /// or disposition. We verified this on iPhone 16 Pro / iOS 26.4.2 with
    /// the `MacApp/scripts/test_subtitle_picker.py` variant set: only F (rus
    /// + qaa) and I (rus + ukr) split the picker; everything else collapsed.
    private var selectedSubLabelsByLang: [(lang: String, labels: [String])] {
        let subs = job.mediaInfo?.subtitleStreams ?? []
        let exts = job.mediaInfo?.externalSubtitles ?? []

        var order: [String] = []
        var grouped: [String: [String]] = [:]
        func add(_ rawLang: String?, _ label: String) {
            let key = LanguageCodes.toIso6392T(rawLang) ?? "und"
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(label)
        }

        for i in job.selectedSubtitles where i < subs.count {
            let s = subs[i]
            let label = (s.title?.isEmpty == false) ? s.title! : "embedded #\(i + 1)"
            add(s.language, label)
        }
        for i in job.selectedExternalSubs where i < exts.count {
            let e = exts[i]
            let parent = e.path.deletingLastPathComponent().lastPathComponent
            add(e.language, parent.isEmpty ? e.path.lastPathComponent : parent)
        }
        for ref in job.externalTracksToMux where ref.kind == .sub {
            add(ref.lang, ref.label)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    /// Warning rendered above the subtitle list when 2+ tracks share a
    /// language code. iPad TV-app's picker shows only one of them; the
    /// rest are in the mp4 but invisible to the user.
    @ViewBuilder
    private var sameLangSubWarning: some View {
        let conflicts = selectedSubLabelsByLang.filter { $0.labels.count > 1 }
        if !conflicts.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(conflicts, id: \.lang) { c in
                    let display = Locale.current.localizedString(forLanguageCode: c.lang)?
                        .capitalized ?? c.lang.uppercased()
                    let visible = c.labels.first ?? c.lang
                    let hidden = c.labels.dropFirst().joined(separator: ", ")
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.chipSkipText)
                        (Text("iPad TV.app shows only one \(display) subtitle — using ")
                            + Text(visible).bold()
                            + Text(". \(hidden) won't appear in the picker."))
                            .font(.system(size: 11))
                            .foregroundStyle(theme.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.bottom, 6)
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
                if job.canDropAudioToAvoidReencode {
                    dropAudioBanner(audios: audios)
                }
                ForEach(audios.indices, id: \.self) { i in
                    let a = audios[i]
                    let on = job.selectedAudio.contains(i)
                    let act = job.decision?.streamActions[a.index] ?? "copy"
                    SelectableLine(checked: on, theme: theme, accent: accent,
                                   onTap: { toggleAudio(i) }) {
                        HStack(spacing: 8) {
                            audioLanguagePicker(streamIdx: i, audio: a)
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

    /// Inline nudge shown when the job has both copy-able and transcode-only
    /// audio tracks (e.g. EN EAC3 + RU AC3). One click drops the transcode ones
    /// and skips the audio re-encode entirely.
    private func dropAudioBanner(audios: [StreamInfo]) -> some View {
        let droppable = job.selectedAudioNeedingTranscode
        let langs: [String] = droppable.compactMap { idx in
            guard idx < audios.count else { return nil }
            return audios[idx].language?.isEmpty == false ? audios[idx].language : nil
        }
        let langLabel = langs.isEmpty ? "incompatible tracks" :
            "\(langs.joined(separator: ", ").uppercased()) (\(droppable.count == 1 ? "1 track" : "\(droppable.count) tracks"))"
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 11))
                .foregroundStyle(accent.solid)
            VStack(alignment: .leading, spacing: 2) {
                Text("Drop \(langLabel) to skip the audio re-encode.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.text)
                Text("These tracks need AAC conversion. The others copy through unchanged.")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.textDim)
            }
            Spacer(minLength: 6)
            Button("Drop") {
                job.selectedAudio = job.selectedAudio.filter { !droppable.contains($0) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(EdgeInsets(top: 7, leading: 9, bottom: 7, trailing: 7))
        .background(accent.soft, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(accent.ring, lineWidth: 0.5))
        .padding(.bottom, 4)
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
                sameLangSubWarning
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
                    Button { openEditTitle() } label: {
                        Text("Wrong match?")
                            .font(.system(size: 11))
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(theme.divider, lineWidth: 1)
                            )
                            .foregroundStyle(theme.textDim)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Search TMDb again with a different title")
                } else if tmdbKeyMissing {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(theme.chipSkipText)
                    Text("TMDb API key not set · using fallback poster")
                        .font(.system(size: 12)).foregroundStyle(theme.textDim)
                    Button { openSettings() } label: {
                        Text("Add TMDb key…")
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
                    .help("Open Settings → Metadata to paste a free TMDb v3 key.")
                    Button {
                        NSWorkspace.shared.open(URL(string: "https://porter.md/setup#tmdb")!)
                    } label: {
                        Text("How to get one")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.textDim)
                            .underline()
                    }
                    .buttonStyle(.plain)
                    .help("Open the porter.md setup guide in your browser.")
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
                initialKind: editedKind,
                initialSeason: editedSeason,
                initialEpisode: editedEpisode,
                hasAPIKey: !pipeline.tmdbAPIKey.isEmpty,
                retryTMDb: $retryTMDb,
                isLoading: $isRetryingLookup,
                onSave: { newTitle, newYear, newKind, newSeason, newEpisode, shouldRetry in
                    Task {
                        await saveEditedTitle(
                            newTitle, year: newYear, kind: newKind,
                            season: newSeason, episode: newEpisode,
                            retry: shouldRetry
                        )
                    }
                },
                onCancel: { isEditingTitle = false }
            )
        }
        .sheet(item: $showPickerInvocation) { inv in
            ShowPickerSheet(
                theme: theme,
                accent: accent,
                clusterID: inv.id,
                initialQuery: inv.query,
                initialCandidates: inv.candidates,
                affectedCount: inv.affectedCount,
                onClose: { showPickerInvocation = nil }
            )
        }
    }

    // MARK: - Title editing

    private func openEditTitle() {
        // TV episodes go through the cluster picker — choosing a show there
        // applies to every episode that shares the cluster id.
        if case .tvEpisode(let e) = job.metadata, let clusterID = job.clusterID {
            let affected = pipeline.jobs(inCluster: clusterID).count
            let query = e.showName
            showPickerInvocation = ShowPickerInvocation(
                id: clusterID,
                query: query,
                candidates: [],            // populated by the sheet's first search
                affectedCount: max(affected, 1)
            )
            // Kick a search now so the sheet opens populated.
            if !pipeline.tmdbAPIKey.isEmpty {
                Task {
                    if let results = try? await TMDbClient.searchTVShows(
                        query: query, apiKey: pipeline.tmdbAPIKey
                    ) {
                        showPickerInvocation = ShowPickerInvocation(
                            id: clusterID, query: query,
                            candidates: results, affectedCount: max(affected, 1)
                        )
                    }
                }
            }
            return
        }

        // Seed S/E from the filename so a movie-misdetected episode comes
        // pre-filled with what the user almost certainly wants.
        let parsed = parseSeasonEpisode(from: job.fileName)
        switch job.metadata {
        case .movie(let m):
            editedTitle = m.title
            editedYear = m.year.map(String.init) ?? ""
            editedKind = .movie
            editedSeason = parsed.season ?? 1
            editedEpisode = parsed.episode ?? 1
        case .tvEpisode(let e):
            editedTitle = e.showName
            editedYear = e.year.map(String.init) ?? ""
            editedKind = .tv
            editedSeason = e.season
            editedEpisode = e.episode
        case .none:
            editedTitle = job.fileName
                .replacingOccurrences(of: "." + (job.inputURL.pathExtension), with: "")
            editedYear = ""
            editedKind = (parsed.season != nil || parsed.episode != nil) ? .tv : .movie
            editedSeason = parsed.season ?? 1
            editedEpisode = parsed.episode ?? 1
        }
        retryTMDb = !pipeline.tmdbAPIKey.isEmpty
        isEditingTitle = true
    }

    private func saveEditedTitle(
        _ newTitle: String, year: String, kind: EditMediaKind,
        season: Int, episode: Int, retry: Bool
    ) async {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let yearInt = Int(year.trimmingCharacters(in: .whitespaces))

        // 1. Optionally re-query TMDb with the edited title + kind as hints.
        //    Routing is now driven by the user-selected Movie/TV picker, not
        //    by the current metadata case — so a movie-misdetected episode
        //    can be corrected by toggling to TV in the sheet.
        if retry, !pipeline.tmdbAPIKey.isEmpty {
            isRetryingLookup = true
            let resolved: ResolvedMetadata?
            switch kind {
            case .tv:
                // Direct route — bypasses filename-shape detection so the
                // user's explicit TV choice wins even when the filename
                // looks like a movie (e.g. `o04.mkv`).
                resolved = await MetadataLookup.lookupTVDirect(
                    showName: trimmed,
                    season: season,
                    episode: episode,
                    year: yearInt,
                    apiKey: pipeline.tmdbAPIKey,
                    sourceURL: job.inputURL
                )
            case .movie:
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

        // 2. Local edit only — overwrite metadata of the chosen kind and
        //    regenerate fallback poster. Switching kind (movie ↔ TV) here
        //    replaces the metadata case, not just mutates the existing one.
        let poster = PosterGenerator.generate(title: trimmed, year: yearInt)
        switch kind {
        case .tv:
            // Preserve season/episode IDs from existing TV metadata when
            // present, otherwise build from the form values.
            var existing: EpisodeMetadata?
            if case .tvEpisode(let ep) = job.metadata { existing = ep }
            let epID = String(format: "S%02dE%02d", season, episode)
            var e = existing ?? EpisodeMetadata(
                showName: trimmed, season: season, episode: episode,
                episodeTitle: trimmed, episodeID: epID, year: yearInt,
                genre: nil, overview: nil, longOverview: nil, network: nil,
                posterURL: nil, posterData: nil,
                showPosterURL: nil, showPosterData: poster,
                tmdbShowID: nil
            )
            e.showName = trimmed
            e.season = season
            e.episode = episode
            if let y = yearInt { e.year = y }
            e.showPosterData = poster
            job.metadata = .tvEpisode(e)
        case .movie:
            var existing: MovieMetadata?
            if case .movie(let m) = job.metadata { existing = m }
            var m = existing ?? MovieMetadata(
                title: trimmed, year: yearInt, genre: nil, overview: nil,
                longOverview: nil, director: nil, posterURL: nil,
                posterData: poster, tmdbID: nil
            )
            m.title = trimmed
            if yearInt != nil { m.year = yearInt }
            m.posterData = poster
            job.metadata = .movie(m)
        }
        isEditingTitle = false
    }

    private func toggleAudio(_ i: Int) {
        if let idx = job.selectedAudio.firstIndex(of: i) {
            job.selectedAudio.remove(at: idx)
        } else {
            job.selectedAudio = (job.selectedAudio + [i]).sorted()
        }
        didChangeClusterSelection()
    }

    /// Language label for an audio track. Order of precedence: user override,
    /// ffprobe-extracted language (real or script-inferred), "Unknown". Used
    /// in both the displayed label and the cluster propagation flow.
    private func audioLanguageDisplay(_ a: StreamInfo, streamIdx: Int) -> String {
        if let lo = job.audioLanguageOverrides[streamIdx], !lo.isEmpty {
            return AudioLanguageOptions.label(for: lo) ?? lo.uppercased()
        }
        if let lang = a.language, !lang.isEmpty, lang.lowercased() != "und" {
            return AudioLanguageOptions.label(for: lang) ?? lang.capitalized
        }
        return "Unknown"
    }

    /// Click-to-pick label for the audio track's language. Shows the
    /// resolved name (override → probe → "Unknown") and opens a Menu of
    /// common languages on click. Picking a language sets the override on
    /// the job and routes through `didChangeClusterSelection()` so the same
    /// "Apply to all N episodes?" popover surfaces for cluster propagation.
    @ViewBuilder
    private func audioLanguagePicker(streamIdx: Int, audio: StreamInfo) -> some View {
        let label = audioLanguageDisplay(audio, streamIdx: streamIdx)
        let isOverride = job.audioLanguageOverrides[streamIdx] != nil
        Menu {
            ForEach(AudioLanguageOptions.common, id: \.code) { opt in
                Button(opt.label) { setAudioLanguage(streamIdx: streamIdx, code: opt.code) }
            }
            if isOverride {
                Divider()
                Button("Clear override", role: .destructive) {
                    setAudioLanguage(streamIdx: streamIdx, code: nil)
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(label == "Unknown" ? theme.textDim : theme.text)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(theme.textFaint)
            }
            .frame(minWidth: 80, alignment: .leading)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(isOverride
            ? "Language set manually — applies to the M4V tag and the iOS audio switcher. Click to change."
            : "ffprobe couldn't find a language tag. Click to set one manually.")
    }

    private func setAudioLanguage(streamIdx: Int, code: String?) {
        if let code, !code.isEmpty {
            job.audioLanguageOverrides[streamIdx] = code
        } else {
            job.audioLanguageOverrides.removeValue(forKey: streamIdx)
        }
        didChangeClusterSelection()
    }
    private func toggleSubtitle(_ i: Int) {
        if let idx = job.selectedSubtitles.firstIndex(of: i) {
            job.selectedSubtitles.remove(at: idx)
        } else {
            job.selectedSubtitles = (job.selectedSubtitles + [i]).sorted()
        }
        didChangeClusterSelection()
    }
    private func toggleExternal(_ i: Int) {
        if let idx = job.selectedExternalSubs.firstIndex(of: i) {
            job.selectedExternalSubs.remove(at: idx)
        } else {
            job.selectedExternalSubs = (job.selectedExternalSubs + [i]).sorted()
        }
        didChangeClusterSelection()
    }

    /// Mutually-exclusive burn-in selector. Tapping the currently-burned track
    /// clears the burn-in; tapping another track moves it.
    private func toggleBurnIn(_ target: BurnInSubtitle) {
        if job.burnInSubtitle == target {
            job.burnInSubtitle = nil
        } else {
            job.burnInSubtitle = target
        }
        didChangeClusterSelection()
    }

    /// Called after every per-row selection change (audio / sub / external /
    /// resolution / burn-in) that could be propagated cluster-wide. Either:
    /// - "Always apply" setting on ⇒ silently propagate to every sibling.
    /// - Cluster has ≥ 1 sibling ⇒ surface the popover ("Apply to all?" /
    ///   "Just this one"), auto-dismiss after 5 s.
    /// - No siblings (movie / one-off) ⇒ nothing.
    private func didChangeClusterSelection() {
        guard let cid = job.clusterID else { return }
        let siblings = pipeline.clusterSiblingCount(of: job)
        guard siblings > 0 else { return }

        if alwaysApplyWithinShow {
            pipeline.captureClusterSelection(from: job, propagate: true)
            return
        }

        let label = clusterShowLabel(for: cid)
        clusterApplyPending = ClusterApplyPrompt(
            clusterID: cid, siblingCount: siblings, showLabel: label
        )
        clusterApplyDismissTask?.cancel()
        clusterApplyDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled { clusterApplyPending = nil }
        }
    }

    /// Counter chip text "+N audio, +M sub" for the meta row, nil when this
    /// job has no externals queued (#11d).
    private var externalTracksLabel: String? {
        let refs = job.externalTracksToMux
        guard !refs.isEmpty else { return nil }
        let dubN = refs.lazy.filter { $0.kind == .dub }.count
        let subN = refs.lazy.filter { $0.kind == .sub }.count
        var parts: [String] = []
        if dubN > 0 { parts.append("+\(dubN) audio") }
        if subN > 0 { parts.append("+\(subN) sub") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Show-name (with year) for the popover header. Falls back to the
    /// parsed title on the current job if the cluster has no resolution yet.
    private func clusterShowLabel(for clusterID: String) -> String {
        if let r = pipeline.tvShowResolutions[clusterID] {
            return r.showName
        }
        if case .tvEpisode(let e) = job.metadata { return e.showName }
        return job.fileName
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
    let hasError: Bool
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
        if status == .uploaded && !hasError { return true }
        return status == .analyzing || status == .transcoding || status == .syncing
    }

    private var dotColor: Color {
        switch status {
        case .pending: return theme.textFaint
        case .analyzing: return accent.solid
        case .analyzed: return theme.textDim
        case .muxing: return Color(hex: 0xFF9F0A)
        case .transcoding: return Color(hex: 0xFF9F0A)
        case .tagging: return Color(hex: 0xBF5AF2)
        case .ready: return Color(red: 0.19, green: 0.82, blue: 0.35)
        case .syncing: return accent.solid
        // While the batch ATC register is in flight every uploaded row sits
        // here. Animate it so the user sees the work-in-progress instead of
        // a static green "done"-looking dot.
        case .uploaded: return hasError ? Color(red: 1.0, green: 0.58, blue: 0.0) : accent.solid
        case .synced: return Color(red: 0.19, green: 0.82, blue: 0.35)
        case .failed: return Color(red: 1.0, green: 0.27, blue: 0.23)
        }
    }
    private var label: String {
        switch status {
        case .pending: return "Queued"
        case .analyzing: return "Analyzing"
        case .analyzed: return "Ready for options"
        case .muxing: return "Muxing extras"
        case .transcoding: return "Transcoding"
        case .tagging: return "Tagging"
        case .ready: return "Ready to send"
        case .syncing: return "Uploading"
        case .uploaded: return hasError ? "Needs sync" : "Syncing…"
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

    private var thumbData: Data? {
        job.metadata?.previewThumbData
    }

    private var hasPoster: Bool {
        guard let data = thumbData, NSImage(data: data) != nil else { return false }
        return true
    }

    private var hasSecondaryArtwork: Bool {
        // True when the popover will show *additional* artwork beyond what's
        // already in the thumb (i.e. an episode still alongside the show
        // portrait). Drives the small stacked-images marker.
        guard job.metadata?.isEpisode == true else { return false }
        return job.metadata?.episodeStillData != nil
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            theme.posterBg
                .overlay {
                    if let data = thumbData, let image = NSImage(data: data) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "film")
                            .font(.system(size: 18))
                            .foregroundStyle(theme.textFaint)
                    }
                }
            // Episode badge (top-left). A random video frame doesn't read at
            // 44pt — the episode number does, and it disambiguates rows in a
            // cluster of identical-looking show portraits.
            if let badge = job.metadata?.episodeBadge {
                Text(badge)
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.black.opacity(0.72))
                    )
                    .padding(3)
            }
            // Stacked-images marker (top-right) — hints there's more artwork
            // accessible on hold. Only shown when there actually is.
            if hasSecondaryArtwork {
                Image(systemName: "square.on.square")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(
                        Circle().fill(Color.black.opacity(0.6))
                    )
                    .padding(3)
                    .frame(maxWidth: .infinity, alignment: .topTrailing)
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
/// down on the thumbnail. For TV episodes shows both artworks side by side
/// (show portrait + episode still) so the user can verify the cluster
/// picker resolved correctly — the device-side portrait isn't otherwise
/// visible from the Mac app.
private struct PosterPreview: View {
    let job: FileJob
    let theme: Theme

    var body: some View {
        VStack(spacing: 10) {
            if job.metadata?.isEpisode == true {
                // Episode still front-and-centre on expand. Show portrait
                // already lives in the thumb, so we relegate it to a small
                // confirmation tile underneath.
                artworkColumn(
                    label: job.metadata?.episodeBadge.map { "Episode · \($0)" } ?? "Episode",
                    data: job.metadata?.episodeStillData,
                    width: 480, height: 270
                )
                artworkColumn(
                    label: "Show artwork",
                    data: job.metadata?.showPortraitData,
                    width: 120, height: 180
                )
            } else {
                artworkColumn(
                    label: nil,
                    data: job.metadata?.posterData,
                    width: 360, height: 540
                )
            }

            if let title = job.metadata?.title {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 540)
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private func artworkColumn(label: String?, data: Data?, width: CGFloat, height: CGFloat) -> some View {
        VStack(spacing: 6) {
            if let label {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.textDim)
                    .textCase(.uppercase)
            }
            Group {
                if let data, let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    theme.posterBg
                        .overlay(
                            VStack(spacing: 6) {
                                Image(systemName: "photo")
                                    .font(.system(size: 28))
                                    .foregroundStyle(theme.textFaint)
                                Text("Not available")
                                    .font(.system(size: 10))
                                    .foregroundStyle(theme.textFaint)
                            }
                        )
                }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
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
    var onChange: (() -> Void)? = nil
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
                    onChange?()
                } label: {
                    VStack(spacing: 2) {
                        HStack(spacing: 6) {
                            Text(opt.1).font(.system(size: 12, weight: .medium))
                            if isRec && opt.0 != .original {
                                Text("Recommended")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(accent.solid)
                            }
                        }
                        if let est = estimatedSize(for: opt.0) {
                            Text("≈ \(est)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(on ? accent.solid.opacity(0.85) : theme.textFaint)
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

    /// Approximate output size for this option, formatted ("1.2 GB" / "420 MB").
    /// Returns nil when we don't have enough info to estimate (no mediaInfo yet).
    private func estimatedSize(for limit: ResolutionLimit) -> String? {
        guard let info = job.mediaInfo else { return nil }
        // "videoWillReencode" when another selection (e.g. non-compat codec)
        // already forces a video re-encode — in which case .original still
        // produces a new file, not a copy of the source.
        let videoWillReencode: Bool = {
            guard let d = job.decision else { return false }
            for v in info.videoStreams where d.streamActions[v.index] == "transcode" {
                return true
            }
            return false
        }()
        let bytes = estimateOutputBytes(
            for: limit,
            mediaInfo: info,
            selectedAudioCount: max(job.selectedAudio.count, 1),
            videoWillReencode: videoWillReencode
        )
        guard bytes > 0 else { return nil }
        return ByteFormat.short(bytes)
    }
}

// MARK: - Edit Title sheet

enum EditMediaKind: String, CaseIterable, Identifiable {
    case movie, tv
    var id: String { rawValue }
    var label: String { self == .movie ? "Movie" : "TV show" }
}

private struct EditTitleSheet: View {
    let theme: Theme
    let accent: AccentKey
    let initialTitle: String
    let initialYear: String
    let initialKind: EditMediaKind
    let initialSeason: Int
    let initialEpisode: Int
    let hasAPIKey: Bool
    @Binding var retryTMDb: Bool
    @Binding var isLoading: Bool
    let onSave: (_ title: String, _ year: String, _ kind: EditMediaKind,
                 _ season: Int, _ episode: Int, _ retryTMDb: Bool) -> Void
    let onCancel: () -> Void

    @State private var title: String = ""
    @State private var year: String = ""
    @State private var kind: EditMediaKind = .movie
    @State private var seasonText: String = "1"
    @State private var episodeText: String = "1"
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit title")
                .font(.system(size: 15, weight: .semibold))

            Text("Used as the poster label and, with a TMDb key, as the search term.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Type", selection: $kind) {
                ForEach(EditMediaKind.allCases) { k in
                    Text(k.label).tag(k)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 6) {
                Text(kind == .tv ? "Show name" : "Title")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Title", text: $title, prompt: Text(kind == .tv ? "Show name" : "Movie name"))
                    .textFieldStyle(.roundedBorder)
                    .focused($titleFocused)
                    .onSubmit(performSave)
            }

            if kind == .tv {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Season").font(.system(size: 11)).foregroundStyle(.secondary)
                        TextField("S", text: $seasonText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Episode").font(.system(size: 11)).foregroundStyle(.secondary)
                        TextField("E", text: $episodeText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                    }
                    Spacer()
                }
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
            kind = initialKind
            seasonText = String(initialSeason)
            episodeText = String(initialEpisode)
            DispatchQueue.main.async { titleFocused = true }
        }
    }

    private func performSave() {
        let s = Int(seasonText.trimmingCharacters(in: .whitespaces)) ?? 1
        let e = Int(episodeText.trimmingCharacters(in: .whitespaces)) ?? 1
        onSave(title, year, kind, s, e, retryTMDb)
    }
}

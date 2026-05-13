// Cluster-scoped selection (#11a).
//
// Holds the user's *intent* for a whole TV-show cluster — audio/sub
// languages+codecs, resolution, burn-in language — and resolves it back to
// concrete `selectedAudio` / `selectedSubtitles` / `maxResolution` /
// `burnInSubtitle` per `FileJob` at analyze time.
//
// Why intent (not stream indices)? Episode indices drift — one episode has
// a commentary track at index 2, the next doesn't. Matching by
// (language, codec_name) survives those drifts and matches what the user
// actually wanted ("Russian AAC dub", not "audio stream #2").
//
// External-track intent fields (`includedDubStudios`, `defaultAudioStudio`,
// `includedSubLabels`) are carried here too so 11c-11e can populate them
// without growing the API; they're inert until the scanner lands.

import Foundation

public struct LangCodec: Hashable, Sendable {
    public let lang: String
    public let codec: String
    public init(lang: String, codec: String) {
        self.lang = lang
        self.codec = codec
    }
}

public enum AudioIntent: Sendable, Equatable {
    /// Seed default: pick every audio stream (today's behaviour).
    case all
    /// Pick streams whose (lang, codec) is in the set. Empty set → no audio.
    case langCodecs(Set<LangCodec>)
}

public enum SubIntent: Sendable, Equatable {
    /// Seed default: pick every text-only subtitle (today's behaviour).
    case allText
    /// Pick text subs whose (lang, codec) is in the set.
    case langCodecs(Set<LangCodec>)
}

public struct ClusterSelection: Sendable, Equatable {
    public var audio: AudioIntent = .all
    public var subs: SubIntent = .allText
    public var maxResolution: ResolutionLimit = .original
    /// Target language for burn-in. Resolves per-episode against first
    /// matching embedded sub, then external sub. nil = no burn-in.
    public var burnInSubLang: String?

    // External-track intent — populated by 11c-11e, inert until then.
    public var includedDubStudios: Set<String> = []
    public var defaultAudioStudio: String?
    public var includedSubLabels: Set<String> = []

    public init() {}
}

private func normLang(_ s: String?) -> String {
    let v = (s ?? "").trimmingCharacters(in: .whitespaces).lowercased()
    return v.isEmpty ? "und" : v
}

private func normCodec(_ s: String) -> String { s.lowercased() }

public extension ClusterSelection {
    /// Reverse-engineer cluster intent from a job's current per-row
    /// selection. Called when the UI mutates a row and the user opts to
    /// propagate to siblings (11b) — or on every change if Settings says so.
    static func capture(from job: FileJob) -> ClusterSelection {
        guard let info = job.mediaInfo else { return ClusterSelection() }
        var sel = ClusterSelection()

        let aPairs = Set(job.selectedAudio.compactMap { idx -> LangCodec? in
            guard idx >= 0 && idx < info.audioStreams.count else { return nil }
            let s = info.audioStreams[idx]
            return LangCodec(lang: normLang(s.language), codec: normCodec(s.codecName))
        })
        sel.audio = .langCodecs(aPairs)

        let sPairs = Set(job.selectedSubtitles.compactMap { idx -> LangCodec? in
            guard idx >= 0 && idx < info.subtitleStreams.count else { return nil }
            let s = info.subtitleStreams[idx]
            return LangCodec(lang: normLang(s.language), codec: normCodec(s.codecName))
        })
        sel.subs = .langCodecs(sPairs)

        sel.maxResolution = job.maxResolution

        switch job.burnInSubtitle {
        case .embedded(let i):
            if i >= 0 && i < info.subtitleStreams.count {
                sel.burnInSubLang = normLang(info.subtitleStreams[i].language)
            }
        case .external(let i):
            if i >= 0 && i < info.externalSubtitles.count {
                sel.burnInSubLang = normLang(info.externalSubtitles[i].language)
            }
        case .none:
            sel.burnInSubLang = nil
        }
        return sel
    }

    /// Resolve only the external-track intent against `extras` and write
    /// `externalTracksToMux` on `job`. Used in `analyzeOne` when no full
    /// cluster intent is stored yet — keeps `selectedAudio`,
    /// `selectedSubtitles`, `maxResolution`, `burnInSubtitle` untouched.
    func applyExternals(to job: FileJob, extras: ReleaseExtras) {
        guard let key = episodeKey(for: job),
              (!includedDubStudios.isEmpty || !includedSubLabels.isEmpty) else {
            job.externalTracksToMux = []
            return
        }
        var refs: [ExternalTrackRef] = []
        for d in extras.dubs where includedDubStudios.contains(d.label) {
            guard let url = d.episodes[key] else { continue }
            refs.append(ExternalTrackRef(
                kind: .dub, path: url, label: d.label, lang: d.lang,
                forced: false, isDefault: defaultAudioStudio == d.label
            ))
        }
        for s in extras.subs where includedSubLabels.contains(s.label) {
            guard let url = s.episodes[key] else { continue }
            refs.append(ExternalTrackRef(
                kind: .sub, path: url, label: s.label, lang: s.lang,
                forced: s.forced, isDefault: false
            ))
        }
        job.externalTracksToMux = refs
    }

    /// Apply this cluster intent to a single job. Overwrites
    /// `selectedAudio`, `selectedSubtitles`, `maxResolution`,
    /// `burnInSubtitle`, and — when `extras` is provided — populates
    /// `externalTracksToMux` for the job's episode.
    func apply(to job: FileJob, extras: ReleaseExtras? = nil) {
        guard let info = job.mediaInfo else { return }

        switch audio {
        case .all:
            job.selectedAudio = Array(0..<info.audioStreams.count)
        case .langCodecs(let pairs):
            var picked = info.audioStreams.enumerated().compactMap { idx, s -> Int? in
                pairs.contains(LangCodec(lang: normLang(s.language), codec: normCodec(s.codecName))) ? idx : nil
            }
            // Fallback: cluster wanted some audio but this episode has no
            // matching track. An empty audio selection bricks the output —
            // keep every track so the file stays usable. (Spec said "skip
            // silently"; bricking the file isn't silent.)
            if picked.isEmpty && !pairs.isEmpty && !info.audioStreams.isEmpty {
                picked = Array(0..<info.audioStreams.count)
            }
            job.selectedAudio = picked
        }

        switch subs {
        case .allText:
            job.selectedSubtitles = info.subtitleStreams.enumerated().compactMap { idx, s in
                isTextSubtitle(s.codecName) || s.codecName == "mov_text" ? idx : nil
            }
        case .langCodecs(let pairs):
            job.selectedSubtitles = info.subtitleStreams.enumerated().compactMap { idx, s in
                guard isTextSubtitle(s.codecName) || s.codecName == "mov_text" else { return nil }
                return pairs.contains(LangCodec(lang: normLang(s.language), codec: normCodec(s.codecName))) ? idx : nil
            }
        }

        job.maxResolution = maxResolution

        if let target = burnInSubLang {
            if let embIdx = info.subtitleStreams.firstIndex(where: { normLang($0.language) == target }),
               isTextSubtitle(info.subtitleStreams[embIdx].codecName) || info.subtitleStreams[embIdx].codecName == "mov_text" {
                job.burnInSubtitle = .embedded(embIdx)
            } else if let extIdx = info.externalSubtitles.firstIndex(where: { normLang($0.language) == target }) {
                job.burnInSubtitle = .external(extIdx)
            } else {
                job.burnInSubtitle = nil
            }
        } else {
            job.burnInSubtitle = nil
        }

        // External tracks (#11c-e). Resolve the cluster's includedDubStudios
        // / includedSubLabels against this episode's (season, episode) key,
        // mark the selected default audio studio. Episodes missing from a
        // studio's set are silently skipped — common for orphan dubs.
        if let extras = extras,
           let key = episodeKey(for: job),
           (!includedDubStudios.isEmpty || !includedSubLabels.isEmpty) {
            var refs: [ExternalTrackRef] = []
            for d in extras.dubs where includedDubStudios.contains(d.label) {
                guard let url = d.episodes[key] else { continue }
                refs.append(ExternalTrackRef(
                    kind: .dub, path: url, label: d.label, lang: d.lang,
                    forced: false, isDefault: defaultAudioStudio == d.label
                ))
            }
            for s in extras.subs where includedSubLabels.contains(s.label) {
                guard let url = s.episodes[key] else { continue }
                refs.append(ExternalTrackRef(
                    kind: .sub, path: url, label: s.label, lang: s.lang,
                    forced: s.forced, isDefault: false
                ))
            }
            job.externalTracksToMux = refs
        } else {
            job.externalTracksToMux = []
        }
    }
}

/// Derive an `EpisodeKey` for the job from its parsed filename. Used to
/// look up per-episode dub / sub paths in `ReleaseExtras.dubs/subs`.
private func episodeKey(for job: FileJob) -> EpisodeKey? {
    let parsed = FilenameParser.parse(job.fileName)
    guard let s = parsed.season, let n = parsed.episode else { return nil }
    return EpisodeKey(season: s, episode: n)
}

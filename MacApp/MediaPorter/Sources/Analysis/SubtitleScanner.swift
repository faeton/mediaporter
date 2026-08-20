// External subtitle detection and language normalization.

import Foundation
import NaturalLanguage

// MARK: - Language Map

private let subExtensions: Set<String> = ["srt", "ass", "ssa", "vtt"]

private let langMap: [String: String] = [
    "en": "eng", "english": "eng", "eng": "eng",
    "ru": "rus", "russian": "rus", "rus": "rus",
    "uk": "ukr", "ukrainian": "ukr", "ukr": "ukr",
    "fr": "fre", "french": "fre", "fre": "fre", "fra": "fre",
    "de": "ger", "german": "ger", "ger": "ger", "deu": "ger",
    "es": "spa", "spanish": "spa", "spa": "spa",
    "it": "ita", "italian": "ita", "ita": "ita",
    "pt": "por", "portuguese": "por", "por": "por",
    "ja": "jpn", "japanese": "jpn", "jpn": "jpn",
    "ko": "kor", "korean": "kor", "kor": "kor",
    "zh": "chi", "chinese": "chi", "chi": "chi", "zho": "chi",
    "ar": "ara", "arabic": "ara", "ara": "ara",
    "hi": "hin", "hindi": "hin", "hin": "hin",
    "pl": "pol", "polish": "pol", "pol": "pol",
    "nl": "dut", "dutch": "dut", "dut": "dut", "nld": "dut",
    "sv": "swe", "swedish": "swe", "swe": "swe",
    "no": "nor", "norwegian": "nor", "nor": "nor",
    "da": "dan", "danish": "dan", "dan": "dan",
    "fi": "fin", "finnish": "fin", "fin": "fin",
    "cs": "cze", "czech": "cze", "cze": "cze", "ces": "cze",
    "tr": "tur", "turkish": "tur", "tur": "tur",
    "th": "tha", "thai": "tha", "tha": "tha",
    "he": "heb", "hebrew": "heb", "heb": "heb",
    "el": "gre", "greek": "gre", "gre": "gre", "ell": "gre",
    "hu": "hun", "hungarian": "hun", "hun": "hun",
    "ro": "rum", "romanian": "rum", "rum": "rum", "ron": "rum",
    "bg": "bul", "bulgarian": "bul", "bul": "bul",
    "hr": "hrv", "croatian": "hrv", "hrv": "hrv",
    "sr": "srp", "serbian": "srp", "srp": "srp",
    "sk": "slo", "slovak": "slo", "slo": "slo", "slk": "slo",
    "vi": "vie", "vietnamese": "vie", "vie": "vie",
    "id": "ind", "indonesian": "ind", "ind": "ind",
    "ms": "may", "malay": "may", "may": "may", "msa": "may",
]

/// Normalize a language string to ISO 639-2 code.
func normalizeLanguage(_ lang: String?) -> String {
    guard let lang, !lang.isEmpty else { return "und" }
    return langMap[lang.lowercased()] ?? "und"
}

/// Separators that may sit between the video stem and a language tag.
private let stemSeparators: Set<Character> = [".", "_", "-", " "]

/// Tags that are a real ISO code *and* a widespread non-language convention.
/// ".hi" is Hindi in ISO 639-1 and "hearing impaired" on a large share of the
/// English releases in circulation, so the tag alone can't settle it — sniff the
/// text and only fall back to the literal reading when the text doesn't answer.
private let ambiguousLanguageTags: Set<String> = ["hi"]

/// Scan for external subtitle files matching a video file.
///
/// Exactly two name shapes count as a sidecar for `<stem>.<video-ext>`:
///
///   `<stem>.srt`             — bare sidecar; language sniffed from the cue text
///   `<stem><sep><tag>.srt`   — "movie.en.srt"; language read from `<tag>`
///
/// The bare shape used to be rejected: the guard demanded `filename.count >
/// videoStem.count`, which is false for an exact stem match, so the single
/// most common sidecar layout ("Show.avi" + "Show.srt") was silently dropped.
/// Nothing else picked it up either — `ExternalTrackScanner.scanRelease`
/// deliberately skips files sitting directly in the source dir on the grounds
/// that this function already handles them.
///
/// The separator requirement replaces that length check: without it a bare
/// `hasPrefix` would pair "Show 1.avi" with "Show 10.srt".
func scanExternalSubtitles(mediaInfo: inout MediaInfo) {
    let videoStem = mediaInfo.path.deletingPathExtension().lastPathComponent
    let directory = mediaInfo.path.deletingLastPathComponent()

    guard let contents = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    ) else { return }

    // `contentsOfDirectory` order is unspecified; sort so the track order in
    // the muxed output (and the checkbox order in the UI) is reproducible.
    for fileURL in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        let ext = fileURL.pathExtension.lowercased()
        guard subExtensions.contains(ext) else { continue }

        let filename = fileURL.deletingPathExtension().lastPathComponent
        guard filename.hasPrefix(videoStem) else { continue }

        let remainder = String(filename.dropFirst(videoStem.count))
        guard remainder.isEmpty || stemSeparators.contains(remainder[remainder.startIndex])
        else { continue }

        // A remainder that is nothing but digits is a sibling's episode number,
        // not a language tag: "Show.mkv" must not adopt "Show 2.srt".
        let tail = remainder.trimmingCharacters(in: CharacterSet(charactersIn: "._- "))
        if !tail.isEmpty, tail.allSatisfy(\.isNumber) { continue }

        // Extract language from the remainder: "movie.en.srt" → "en". Tags
        // compound ("movie.en.forced.srt", "movie.rus.full.srt"), so each token
        // is tried in turn — reading the remainder as one blob resolves nothing
        // and silently demotes a correctly tagged track to "und".
        var language = "und"
        var tagIsAmbiguous = false
        for token in remainder.split(whereSeparator: { stemSeparators.contains($0) }) {
            let raw = String(token).lowercased()
            let code = normalizeLanguage(raw)
            if code != "und" {
                language = code
                tagIsAmbiguous = ambiguousLanguageTags.contains(raw)
                break
            }
        }

        // No usable tag in the name — read the text instead. A bare "Show.srt"
        // beside a foreign-language rip is exactly the case the name can't
        // answer, and "und" shows up in the TV.app picker as "Unknown". An
        // ambiguous tag gets the same treatment, but keeps its literal reading
        // if the text can't beat it.
        if language == "und" || tagIsAmbiguous {
            if let sniffed = sniffSubtitleLanguage(at: fileURL, format: ext) {
                language = sniffed
            }
        }

        mediaInfo.externalSubtitles.append(
            ExternalSubtitle(path: fileURL, language: language, format: ext)
        )
    }
}

// MARK: - Language Sniffing

/// Minimum number of cue characters before the recognizer's verdict is worth
/// trusting. A signs-only track ("МОРСКАЯ ПЕХОТА США") clears this easily; a
/// two-cue credits stub does not, and stays "und".
private let minSniffCharacters = 40

/// Language confidence floor. `NLLanguageRecognizer` always names a winner, so
/// without a floor a stub of proper nouns would get labelled at random.
private let minSniffConfidence = 0.5

/// Identify the language of a sidecar whose name carries no language tag, by
/// running its cue text through `NLLanguageRecognizer`.
///
/// Returns nil — leaving the track "und" rather than mislabelling it — when the
/// file can't be decoded, holds too little text to judge, the recognizer isn't
/// confident, or it names a language outside `langMap`.
func sniffSubtitleLanguage(at url: URL, format: String) -> String? {
    var best: (code: String, confidence: Double)?
    for text in decodeCandidates(at: url) {
        let cues = cueText(from: text, format: format)
        guard cues.count >= minSniffCharacters,
              let hit = dominantLanguage(of: cues) else { continue }
        if hit.confidence > (best?.confidence ?? 0) { best = hit }
    }
    guard let best, best.confidence >= minSniffConfidence else { return nil }
    return best.code
}

/// Top language hypothesis for `text`, normalized to ISO 639-2. Nil when the
/// recognizer's pick has no `langMap` entry — an unmappable answer is no answer.
private func dominantLanguage(of text: String) -> (code: String, confidence: Double)? {
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(text)
    guard let top = recognizer.languageHypotheses(withMaximum: 1)
            .max(by: { $0.value < $1.value }) else { return nil }
    let code = normalizeLanguage(top.key.rawValue)
    return code == "und" ? nil : (code, top.value)
}

/// Plausible decodings of a subtitle file's head.
///
/// UTF-8 is decisive: if the bytes decode as UTF-8 that is the answer, and it's
/// the only candidate returned. The legacy 8-bit encodings are *not* decisive
/// and can't be ordered into a ladder — CP1251 maps all 256 byte values, so it
/// "succeeds" on a CP1252 French file too and would win by being tried first,
/// turning `C'était déjà l'été` into Cyrillic mojibake. Both are returned and
/// the caller keeps whichever the recognizer is more confident about; mojibake
/// scores badly, which is exactly the signal needed to break the tie.
///
/// The file is mapped, not copied, and only the first 64 KB is decoded —
/// several hundred cues, far more than the recognizer needs, so a 5 MB ASS file
/// costs a couple of pages rather than a full read.
private func decodeCandidates(at url: URL) -> [String] {
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
    let head = data.prefix(64 * 1024)

    // Windows tools still save subtitles as UTF-16 with a BOM. Without this the
    // bytes fail UTF-8 and get read as CP1251 noise, and the track stays "und".
    if head.starts(with: [0xFF, 0xFE]) || head.starts(with: [0xFE, 0xFF]) {
        // UTF-16 decoding needs whole code units, and honors the BOM itself.
        let even = head.prefix(head.count - (head.count % 2))
        if let s = String(data: even, encoding: .utf16), !s.isEmpty { return [s] }
    }

    // A 64 KB cut can land mid-codepoint and fail the whole decode; back off up
    // to three bytes to find the boundary before giving up on UTF-8.
    for trim in 0...3 where head.count > trim {
        if let s = String(data: head.dropLast(trim), encoding: .utf8), !s.isEmpty {
            // Foundation leaves the BOM in the string; strip it by hand.
            return [s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s]
        }
    }
    return [String.Encoding.windowsCP1251, .windowsCP1252].compactMap {
        let decoded = String(data: head, encoding: $0)
        return decoded?.isEmpty == false ? decoded : nil
    }
}

/// WebVTT block headers: the keyword alone on its line, or followed by a space
/// ("NOTE reviewed by QA"). Prefix-matching alone would treat a cue opening with
/// "NOTES" as a block header and swallow the rest of the file.
private func isVTTBlockHeader(_ line: String) -> Bool {
    ["NOTE", "STYLE", "REGION"].contains { line == $0 || line.hasPrefix($0 + " ") }
}

/// Reduce a subtitle file to spoken text: drop cue indices, timecodes, WebVTT
/// header and metadata blocks, ASS/SSA script sections and their per-line style
/// fields, and inline markup. Timecodes and style names are ASCII, and enough of
/// them skews the recognizer toward English on a non-English track.
private func cueText(from text: String, format: String) -> String {
    let isASS = (format == "ass" || format == "ssa")
    // ASS field order is declared by the `[Events] Format:` header. Text is
    // normally last of ten, but the header is authoritative when it isn't.
    var textFieldIndex = 9
    var out: [String] = []
    // WebVTT NOTE / STYLE / REGION blocks run until the next blank line, so
    // blank lines have to survive the split to mark where they end.
    var skippingBlock = false

    // Split on `isNewline`, NOT on the "\n" Character: Swift treats CRLF as a
    // single grapheme cluster, so `split(separator: "\n")` finds no separator
    // at all in a CRLF file and hands back the whole thing as one line — and
    // essentially every SRT in circulation is CRLF. `isNewline` also covers
    // lone CR (classic Mac) and the Unicode line separators.
    // `omittingEmptySubsequences: false` keeps the blank lines that mark where
    // a WebVTT NOTE / STYLE / REGION block ends.
    for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty { skippingBlock = false; continue }
        if skippingBlock { continue }
        if isVTTBlockHeader(line) {
            skippingBlock = true
            continue
        }
        if line.hasPrefix("WEBVTT") { continue }
        if line.contains("-->") { continue }                          // cue timing
        if line.allSatisfy(\.isNumber) { continue }                   // SRT cue index

        var cue = line
        if isASS {
            if line.hasPrefix("[") { continue }                       // "[Script Info]"
            if line.lowercased().hasPrefix("format:") {
                let names = line.dropFirst("format:".count)
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                // The `[V4+ Styles]` header has no Text field, so it leaves the
                // default alone — only `[Events]` moves the index.
                if let i = names.firstIndex(of: "text") { textFieldIndex = i }
                continue
            }
            // "Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,text here"
            // — the text field may itself contain commas, hence maxSplits.
            // Case-insensitive to match the `format:` check above — some SSA
            // dumps write "dialogue:", and dropping every line leaves too
            // little text to judge.
            guard line.lowercased().hasPrefix("dialogue:") else { continue }
            let fields = line.split(separator: ",", maxSplits: textFieldIndex,
                                    omittingEmptySubsequences: false)
            guard fields.count > textFieldIndex else { continue }
            cue = String(fields[textFieldIndex])
        }

        cue = cue.replacingOccurrences(        // "<i>", "{\\an8}", "{\\pos(..)}"
            of: #"<[^>]*>|\{[^}]*\}"#, with: " ", options: .regularExpression
        )
        cue = cue.replacingOccurrences(        // ASS hard line breaks
            of: #"\\[Nn]"#, with: " ", options: .regularExpression
        )
        cue = cue.trimmingCharacters(in: .whitespaces)
        if !cue.isEmpty { out.append(cue) }
    }
    return out.joined(separator: " ")
}

/// Check if a subtitle codec is bitmap-based.
public func isBitmapSubtitle(_ codecName: String) -> Bool {
    CodecSets.bitmapSubtitles.contains(codecName)
}

/// Check if a subtitle codec is text-based.
public func isTextSubtitle(_ codecName: String) -> Bool {
    CodecSets.textSubtitles.contains(codecName)
}

// External subtitle detection and language normalization.

import Foundation

// MARK: - Language Map

private let subExtensions: Set<String> = ["srt", "ass", "ssa"]

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

/// Scan for external subtitle files matching a video file.
func scanExternalSubtitles(mediaInfo: inout MediaInfo) {
    let videoStem = mediaInfo.path.deletingPathExtension().lastPathComponent
    let directory = mediaInfo.path.deletingLastPathComponent()

    guard let contents = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    ) else { return }

    for fileURL in contents {
        let ext = fileURL.pathExtension.lowercased()
        guard subExtensions.contains(ext) else { continue }

        let filename = fileURL.deletingPathExtension().lastPathComponent
        guard filename.hasPrefix(videoStem), filename.count > videoStem.count else { continue }

        // Extract language from remainder: "movie.en.srt" → "en"
        let remainder = String(filename.dropFirst(videoStem.count))
        let langPart = remainder.trimmingCharacters(in: CharacterSet(charactersIn: "._ "))
        let language = normalizeLanguage(langPart.isEmpty ? nil : langPart)

        mediaInfo.externalSubtitles.append(
            ExternalSubtitle(path: fileURL, language: language, format: ext)
        )
    }
}

/// Check if a subtitle codec is bitmap-based.
public func isBitmapSubtitle(_ codecName: String) -> Bool {
    CodecSets.bitmapSubtitles.contains(codecName)
}

/// Check if a subtitle codec is text-based.
public func isTextSubtitle(_ codecName: String) -> Bool {
    CodecSets.textSubtitles.contains(codecName)
}

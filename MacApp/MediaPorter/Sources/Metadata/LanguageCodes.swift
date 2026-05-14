// ISO 639 helpers.
//
// TMDb returns `original_language` as ISO 639-1 (2-letter, e.g. "ja").
// MP4's lang atom and ffprobe's stream tag use ISO 639-2/T (3-letter,
// e.g. "jpn"). When we fall back to TMDb's language for an untagged
// audio stream we need to translate. Pass-through for codes that are
// already 3-letter or unknown.

import Foundation

public enum LanguageCodes {
    /// Common ISO 639-1 → 639-2/T (terminological). Covers the languages
    /// TMDb reports for the vast majority of titles users sync. Anything
    /// missing falls through as-is and ffmpeg will accept it; iOS may
    /// surface "Unknown" but that's no worse than before.
    private static let twoToThree: [String: String] = [
        "aa": "aar", "ab": "abk", "af": "afr", "ak": "aka", "am": "amh",
        "ar": "ara", "as": "asm", "az": "aze", "be": "bel", "bg": "bul",
        "bn": "ben", "bo": "bod", "bs": "bos", "ca": "cat", "cs": "ces",
        "cy": "cym", "da": "dan", "de": "deu", "el": "ell", "en": "eng",
        "eo": "epo", "es": "spa", "et": "est", "eu": "eus", "fa": "fas",
        "fi": "fin", "fr": "fra", "ga": "gle", "gl": "glg", "gu": "guj",
        "ha": "hau", "he": "heb", "hi": "hin", "hr": "hrv", "hu": "hun",
        "hy": "hye", "id": "ind", "is": "isl", "it": "ita", "ja": "jpn",
        "ka": "kat", "kk": "kaz", "km": "khm", "kn": "kan", "ko": "kor",
        "ky": "kir", "la": "lat", "lo": "lao", "lt": "lit", "lv": "lav",
        "mk": "mkd", "ml": "mal", "mn": "mon", "mr": "mar", "ms": "msa",
        "my": "mya", "nb": "nob", "ne": "nep", "nl": "nld", "nn": "nno",
        "no": "nor", "or": "ori", "pa": "pan", "pl": "pol", "ps": "pus",
        "pt": "por", "ro": "ron", "ru": "rus", "si": "sin", "sk": "slk",
        "sl": "slv", "sq": "sqi", "sr": "srp", "sv": "swe", "sw": "swa",
        "ta": "tam", "te": "tel", "th": "tha", "tl": "tgl", "tr": "tur",
        "uk": "ukr", "ur": "urd", "uz": "uzb", "vi": "vie", "yi": "yid",
        "zh": "zho", "zu": "zul",
    ]

    /// Normalize whatever the caller has into an ISO 639-2/T 3-letter code.
    /// - Returns `nil` if `input` is nil or empty.
    /// - Returns the input lowercased if it's already 3 letters (we trust
    ///   ffprobe / mux output).
    /// - Maps 2-letter ISO 639-1 to 3-letter via the table above.
    /// - Falls back to the input lowercased if no mapping exists.
    public static func toIso6392T(_ input: String?) -> String? {
        guard let raw = input?.lowercased(),
              !raw.isEmpty,
              raw != "und"
        else { return nil }
        if raw.count == 3 { return raw }
        if raw.count == 2 { return twoToThree[raw] ?? raw }
        return raw
    }
}

/// Manual-pick language menu offered when ffprobe found no language tag.
/// Same shortlist as the App-side Settings → OpenSubtitles language picker —
/// any of these maps to ISO 639-2/T for ffmpeg + iOS audio-switcher labelling.
public enum AudioLanguageOptions {
    public struct Option: Sendable {
        public let code: String   // ISO 639-2/T
        public let label: String
    }

    public static let common: [Option] = [
        Option(code: "eng", label: "English"),
        Option(code: "rus", label: "Russian"),
        Option(code: "jpn", label: "Japanese"),
        Option(code: "ukr", label: "Ukrainian"),
        Option(code: "spa", label: "Spanish"),
        Option(code: "fra", label: "French"),
        Option(code: "deu", label: "German"),
        Option(code: "ita", label: "Italian"),
        Option(code: "por", label: "Portuguese"),
        Option(code: "pol", label: "Polish"),
        Option(code: "zho", label: "Chinese"),
        Option(code: "kor", label: "Korean"),
        Option(code: "tur", label: "Turkish"),
        Option(code: "ara", label: "Arabic"),
    ]

    /// Return a user-friendly label for a stored ISO code if it's one we
    /// know, otherwise nil so the caller can fall back to the raw string.
    public static func label(for code: String) -> String? {
        let normalized = LanguageCodes.toIso6392T(code) ?? code.lowercased()
        return common.first { $0.code == normalized }?.label
    }
}

// Sidecar subtitle discovery.
//
// The bare "<stem>.srt" case is the one that regressed: the old guard demanded
// the subtitle name be strictly *longer* than the video stem, which is only
// true when a language tag follows, so plain sidecars were dropped on the floor
// and nothing downstream picked them up.

import XCTest
@testable import MediaPorterCore

final class SubtitleScannerTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("subscan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Write `text` to `name` inside the scratch dir.
    @discardableResult
    private func write(_ name: String, _ text: String = "") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func scan(video: String) throws -> [ExternalSubtitle] {
        try write(video)
        var info = MediaInfo(
            path: dir.appendingPathComponent(video),
            formatName: "matroska",
            duration: 60
        )
        scanExternalSubtitles(mediaInfo: &info)
        return info.externalSubtitles
    }

    // A few lines of ordinary Russian dialog — enough text for the recognizer.
    private let russianCues = """
    1
    00:00:01,000 --> 00:00:04,000
    Привет, как у тебя дела сегодня?

    2
    00:00:05,000 --> 00:00:08,000
    Я давно тебя не видел, где ты был всё это время?

    3
    00:00:09,000 --> 00:00:12,000
    Мы должны поговорить об этом прямо сейчас.
    """

    private let englishCues = """
    1
    00:00:01,000 --> 00:00:04,000
    I have not seen you around here in quite a while.

    2
    00:00:05,000 --> 00:00:08,000
    We really ought to talk about what happened yesterday.
    """

    // MARK: Name matching

    func testBareSidecarIsFound() throws {
        try write("Фонари 1.WEB-DLRip.srt", russianCues)
        let subs = try scan(video: "Фонари 1.WEB-DLRip.avi")
        XCTAssertEqual(subs.count, 1)
        XCTAssertEqual(subs.first?.format, "srt")
    }

    func testLanguageTaggedSidecarIsFound() throws {
        try write("Movie.en.srt", englishCues)
        try write("Movie.ru.srt", russianCues)
        let subs = try scan(video: "Movie.mkv")
        XCTAssertEqual(subs.map(\.language).sorted(), ["eng", "rus"])
    }

    /// `hasPrefix` alone would pair "Show 1.mkv" with "Show 10.srt" — the
    /// character after the stem has to be a separator.
    func testLongerSiblingNumberIsNotASidecar() throws {
        try write("Show 10.srt", englishCues)
        let subs = try scan(video: "Show 1.mkv")
        XCTAssertTrue(subs.isEmpty)
    }

    func testUnrelatedSubtitleIgnored() throws {
        try write("Other Movie.srt", englishCues)
        let subs = try scan(video: "Show 1.mkv")
        XCTAssertTrue(subs.isEmpty)
    }

    func testVttIsRecognized() throws {
        try write("Movie.vtt", "WEBVTT\n\n" + englishCues)
        let subs = try scan(video: "Movie.mkv")
        XCTAssertEqual(subs.first?.format, "vtt")
    }

    /// Directory order is unspecified; the scan sorts so track order is stable.
    func testResultsAreSortedByName() throws {
        try write("Movie.ru.srt", russianCues)
        try write("Movie.en.srt", englishCues)
        let subs = try scan(video: "Movie.mkv")
        XCTAssertEqual(subs.map(\.language), ["eng", "rus"])
    }

    /// A remainder that is only digits is a sibling's episode number, not a
    /// language tag — "Show.mkv" must not adopt "Show 2.srt".
    func testNumericRemainderIsNotASidecar() throws {
        try write("Show 2.srt", englishCues)
        let subs = try scan(video: "Show.mkv")
        XCTAssertTrue(subs.isEmpty)
    }

    /// Every test above writes LF, because Swift multi-line literals are LF —
    /// which is exactly why a CRLF bug survived them. Real SRT files are CRLF.
    /// Swift treats "\r\n" as ONE Character, so splitting on the "\n" Character
    /// finds no separator and yields the whole file as a single line, with the
    /// timecodes still glued to the dialogue.
    func testCrlfSubtitleIsSniffed() throws {
        let crlf = russianCues.replacingOccurrences(of: "\n", with: "\r\n")
        try write("Movie.srt", crlf)
        let subs = try scan(video: "Movie.mkv")
        XCTAssertEqual(subs.first?.language, "rus")
    }

    /// Classic-Mac line endings, same trap.
    func testCrOnlySubtitleIsSniffed() throws {
        let cr = russianCues.replacingOccurrences(of: "\n", with: "\r")
        try write("Movie.srt", cr)
        let subs = try scan(video: "Movie.mkv")
        XCTAssertEqual(subs.first?.language, "rus")
    }

    /// Blank-line block boundaries must still work once the split handles CRLF.
    func testCrlfVttNoteBlockIsStillSkipped() throws {
        let vtt = """
        WEBVTT

        NOTE
        This subtitle file was produced by the localization department and
        proofread twice before delivery. Please do not redistribute it
        outside of the approved regional partners listed in the contract.

        1
        00:00:01.000 --> 00:00:04.000
        Привет, как у тебя дела сегодня?

        2
        00:00:05.000 --> 00:00:08.000
        Я давно тебя не видел, где ты был всё это время?
        """.replacingOccurrences(of: "\n", with: "\r\n")
        try write("Movie.vtt", vtt)
        let subs = try scan(video: "Movie.mkv")
        XCTAssertEqual(subs.first?.language, "rus")
    }

    /// The exact file that exposed this: a UTF-8-BOM, CRLF, signs-only track.
    func testBomCrlfSignsTrack() throws {
        let signs = """
        1
        00:02:34,738 --> 00:02:39,785
        МОРСКАЯ ПЕХОТА США
        СТЮАРТ

        2
        00:04:16,089 --> 00:04:18,550
        БОКСЕРСКИЙ ЗАЛ КОУСТ-СИТИ

        3
        00:13:09,247 --> 00:13:13,960
        ПУНКТ ВЫДАЧИ АРЕНДОВАННЫХ АВТО «ГЕРТЦ»
        """.replacingOccurrences(of: "\n", with: "\r\n")
        let url = dir.appendingPathComponent("Фонари 1.WEB-DLRip.srt")
        var bytes = Data([0xEF, 0xBB, 0xBF])
        bytes.append(signs.data(using: .utf8)!)
        try bytes.write(to: url)
        let subs = try scan(video: "Фонари 1.WEB-DLRip.avi")
        XCTAssertEqual(subs.first?.language, "rus")
    }

    // MARK: Language sniffing

    func testBareSidecarLanguageSniffedFromText() throws {
        try write("Фонари 1.WEB-DLRip.srt", russianCues)
        let subs = try scan(video: "Фонари 1.WEB-DLRip.avi")
        XCTAssertEqual(subs.first?.language, "rus")
    }

    func testExplicitTagBeatsSniffing() throws {
        // English tag on a file full of Russian — the name is the author's
        // intent and wins.
        try write("Movie.en.srt", russianCues)
        let subs = try scan(video: "Movie.mkv")
        XCTAssertEqual(subs.first?.language, "eng")
    }

    func testTooLittleTextStaysUnd() throws {
        try write("Movie.srt", "1\n00:00:01,000 --> 00:00:02,000\nOk.\n")
        let subs = try scan(video: "Movie.mkv")
        XCTAssertEqual(subs.first?.language, "und")
    }

    /// Signs-only tracks are the realistic bare-sidecar case: short all-caps
    /// location cards, no dialog.
    func testSignsOnlyCyrillicTrackSniffsRussian() throws {
        let signs = """
        1
        00:02:34,738 --> 00:02:39,785
        МОРСКАЯ ПЕХОТА США
        СТЮАРТ

        2
        00:04:16,089 --> 00:04:18,550
        БОКСЕРСКИЙ ЗАЛ КОУСТ-СИТИ

        3
        00:13:09,247 --> 00:13:13,960
        ПУНКТ ВЫДАЧИ АРЕНДОВАННЫХ АВТО «ГЕРТЦ»
        """
        try write("Фонари 1.WEB-DLRip.srt", signs)
        let subs = try scan(video: "Фонари 1.WEB-DLRip.avi")
        XCTAssertEqual(subs.first?.language, "rus")
    }

    /// Timecodes and ASS style fields are ASCII; if they reached the
    /// recognizer they would drag a Russian track toward English.
    func testAssDialogTextIsSniffed() throws {
        let ass = """
        [Script Info]
        Title: Default file
        ScriptType: v4.00+

        [V4+ Styles]
        Format: Name, Fontname, Fontsize
        Style: Default,Arial,20

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.00,0:00:04.00,Default,,0,0,0,,{\\an8}Привет, как у тебя дела сегодня?
        Dialogue: 0,0:00:05.00,0:00:08.00,Default,,0,0,0,,Я давно тебя не видел, где ты был?
        Dialogue: 0,0:00:09.00,0:00:12.00,Default,,0,0,0,,Мы должны поговорить об этом сейчас.
        """
        try write("Movie.ass", ass)
        let subs = try scan(video: "Movie.mkv")
        XCTAssertEqual(subs.first?.language, "rus")
    }

    /// Compound tags are the norm on scene sidecars. Reading the remainder as
    /// one blob resolves nothing and demotes a correctly tagged track to "und".
    func testCompoundLanguageTag() throws {
        try write("Movie.en.forced.srt", "1\n00:00:01,000 --> 00:00:02,000\nOK.\n")
        let subs = try scan(video: "Movie.mkv")
        XCTAssertEqual(subs.first?.language, "eng")
    }

    func testCompoundTagLanguageNotFirstToken() throws {
        try write("Movie.forced.rus.srt", "1\n00:00:01,000 --> 00:00:02,000\nOK.\n")
        let subs = try scan(video: "Movie.mkv")
        XCTAssertEqual(subs.first?.language, "rus")
    }

    /// CP1251 maps all 256 byte values, so it decodes a CP1252 file too. Trying
    /// the two in sequence would hand French to the recognizer as Cyrillic
    /// mojibake; both decodings have to compete on confidence instead.
    func testCp1252SidecarIsNotMisreadAsCyrillic() throws {
        let french = """
        1
        00:00:01,000 --> 00:00:04,000
        C'était déjà l'été à Noël, et personne ne savait quoi faire.

        2
        00:00:05,000 --> 00:00:08,000
        Nous devons parler de ce qui s'est passé hier après-midi.
        """
        let url = dir.appendingPathComponent("Movie.srt")
        let data = french.data(using: .windowsCP1252, allowLossyConversion: false)
        try XCTUnwrap(data).write(to: url)
        let subs = try scan(video: "Movie.mkv")
        XCTAssertEqual(subs.first?.language, "fre")
    }

    /// The `[Events] Format:` header declares field order. Hard-coding text as
    /// field 10 reads the wrong field when the header says otherwise.
    func testAssHonorsDeclaredFieldOrder() throws {
        let ass = """
        [Script Info]
        ScriptType: v4.00+

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Text, Effect
        Dialogue: 0,0:00:01.00,0:00:04.00,Default,,0,0,0,Привет, как у тебя дела сегодня?,
        Dialogue: 0,0:00:05.00,0:00:08.00,Default,,0,0,0,Я давно тебя не видел где ты был?,
        Dialogue: 0,0:00:09.00,0:00:12.00,Default,,0,0,0,Мы должны поговорить об этом сейчас.,
        """
        try write("Movie.ass", ass)
        let subs = try scan(video: "Movie.mkv")
        XCTAssertEqual(subs.first?.language, "rus")
    }

    /// A WebVTT NOTE runs until the next blank line. Skipping only the NOTE
    /// line feeds an English production comment into a Russian track's verdict.
    func testVttNoteBlockIsSkipped() throws {
        let vtt = """
        WEBVTT

        NOTE
        This subtitle file was produced by the localization department and
        proofread twice before delivery. Please do not redistribute it
        outside of the approved regional partners listed in the contract.

        1
        00:00:01.000 --> 00:00:04.000
        Привет, как у тебя дела сегодня?

        2
        00:00:05.000 --> 00:00:08.000
        Я давно тебя не видел, где ты был всё это время?
        """
        try write("Movie.vtt", vtt)
        let subs = try scan(video: "Movie.mkv")
        XCTAssertEqual(subs.first?.language, "rus")
    }

    /// ".hi" is Hindi in ISO 639-1 and "hearing impaired" on a large share of
    /// English releases. The tag alone can't settle it, so the text decides.
    func testHearingImpairedTagIsResolvedByText() throws {
        try write("Movie.hi.srt", englishCues)
        let subs = try scan(video: "Movie.mkv")
        XCTAssertEqual(subs.first?.language, "eng")
    }

    /// …but a genuinely Hindi file keeps the literal reading.
    func testAmbiguousTagFallsBackWhenTextIsUnreadable() throws {
        try write("Movie.hi.srt", "1\n00:00:01,000 --> 00:00:02,000\nOK.\n")
        let subs = try scan(video: "Movie.mkv")
        XCTAssertEqual(subs.first?.language, "hin")
    }

    /// Windows tools still save subtitles as UTF-16 with a BOM.
    func testUtf16SidecarIsDecoded() throws {
        let url = dir.appendingPathComponent("Movie.srt")
        let data = russianCues.data(using: .utf16LittleEndian)
        var withBOM = Data([0xFF, 0xFE])
        withBOM.append(try XCTUnwrap(data))
        try withBOM.write(to: url)
        let subs = try scan(video: "Movie.mkv")
        XCTAssertEqual(subs.first?.language, "rus")
    }

    /// Some SSA dumps write "dialogue:" lowercase; dropping every line leaves
    /// too little text to judge.
    func testLowercaseDialogueKeyword() throws {
        let ass = """
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        dialogue: 0,0:00:01.00,0:00:04.00,Default,,0,0,0,,Привет, как у тебя дела сегодня?
        dialogue: 0,0:00:05.00,0:00:08.00,Default,,0,0,0,,Я давно тебя не видел где ты был?
        dialogue: 0,0:00:09.00,0:00:12.00,Default,,0,0,0,,Мы должны поговорить об этом сейчас.
        """
        try write("Movie.ass", ass)
        let subs = try scan(video: "Movie.mkv")
        XCTAssertEqual(subs.first?.language, "rus")
    }

    /// "NOTES" opens a cue, not a WebVTT block — prefix-matching would swallow
    /// the rest of the file.
    func testVttCueStartingWithNotesIsKept() throws {
        let vtt = """
        WEBVTT

        1
        00:00:01.000 --> 00:00:04.000
        NOTES Привет, как у тебя дела сегодня?

        2
        00:00:05.000 --> 00:00:08.000
        Я давно тебя не видел, где ты был всё это время?
        """
        try write("Movie.vtt", vtt)
        let subs = try scan(video: "Movie.mkv")
        XCTAssertEqual(subs.first?.language, "rus")
    }

    /// Russian trackers still ship CP1251. UTF-8 decoding fails on those bytes,
    /// so the fallback has to catch them.
    func testCp1251SidecarIsDecodedAndSniffed() throws {
        let url = dir.appendingPathComponent("Movie.srt")
        let data = russianCues.data(
            using: .windowsCP1251, allowLossyConversion: false
        )
        try XCTUnwrap(data).write(to: url)
        let subs = try scan(video: "Movie.mkv")
        XCTAssertEqual(subs.first?.language, "rus")
    }
}

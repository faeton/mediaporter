// The TMDb original-language fallback must name at most one untagged audio
// track. An AVI with a Russian dub + English original carries no tags; both
// used to be stamped "eng" and showed up as two "English" rows in TV.app.

import XCTest
@testable import MediaPorterCore

private func audio(_ index: Int, lang: String? = nil) -> StreamInfo {
    StreamInfo(index: index, codecType: "audio", codecName: "ac3", channels: 2, language: lang)
}

/// Language written for each output audio track, in output order.
private func audioLanguages(
    _ streams: [StreamInfo],
    fallback: String? = "en",
    overrides: [Int: String] = [:]
) throws -> [String] {
    try XCTSkipIf(FFmpegLocator.ffmpeg == nil, "buildCommand needs ffmpeg on PATH")
    let info = MediaInfo(
        path: URL(fileURLWithPath: "/tmp/test.avi"),
        formatName: "avi",
        duration: 100,
        videoStreams: [StreamInfo(index: 0, codecType: "video", codecName: "mpeg4", width: 720, height: 400)],
        audioStreams: streams
    )
    let cmd = Transcoder.buildCommand(
        mediaInfo: info,
        decision: evaluateCompatibility(mediaInfo: info),
        audioActions: classifyAllAudio(streams),
        outputPath: URL(fileURLWithPath: "/tmp/out.m4v"),
        hwAccel: false,
        originalLanguageFallback: fallback,
        audioLanguageOverrides: overrides
    )
    return cmd.indices.compactMap { i in
        guard cmd[i].hasPrefix("-metadata:s:a:"), i + 1 < cmd.count,
              cmd[i + 1].hasPrefix("language=") else { return nil }
        return String(cmd[i + 1].dropFirst("language=".count))
    }
}

final class AudioLanguageFallbackTests: XCTestCase {
    func testSingleUntaggedTrackGetsFallback() throws {
        XCTAssertEqual(try audioLanguages([audio(1)]), ["eng"])
    }

    func testTwoUntaggedTracksStayUnd() throws {
        XCTAssertEqual(try audioLanguages([audio(1), audio(2)]), ["und", "und"])
    }

    func testFallbackFillsTheOnlyUntaggedTrack() throws {
        XCTAssertEqual(try audioLanguages([audio(1, lang: "rus"), audio(2)]), ["rus", "eng"])
    }

    func testOverrideLeavesOneUntaggedTrackForFallback() throws {
        XCTAssertEqual(try audioLanguages([audio(1), audio(2)], overrides: [0: "ru"]), ["rus", "eng"])
    }
}
